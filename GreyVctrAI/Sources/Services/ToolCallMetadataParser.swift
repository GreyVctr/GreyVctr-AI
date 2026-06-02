import Foundation

/// Strips tool-call metadata from model responses produced when a skill is matched.
///
/// The model outputs responses in this format:
/// ```
/// [Using skill: <name>]
/// ```json
/// { ... }
/// ```
/// <clean answer text>
/// ```
///
/// This utility removes the header line and the fenced JSON block,
/// returning the human-readable answer and the extracted metadata.
struct ToolCallMetadataParser {

    /// Result of stripping metadata from a model response.
    struct StrippedResult {
        /// The clean answer text with metadata removed.
        let cleanContent: String
        /// The extracted JSON data string (nil if none found).
        let jsonData: String?
    }

    /// Strips the `[Using skill: ...]` header and any fenced JSON code block
    /// from the start of a model response.
    ///
    /// Returns the clean answer text and the extracted JSON block (if any).
    /// If the response doesn't match the expected pattern, returns it unchanged.
    static func stripMetadata(from response: String) -> StrippedResult {
        var text = response
        var extractedJSON: String?

        // Remove leading whitespace/newlines
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove "[Using skill: <name>]" line if present
        if text.hasPrefix("[Using skill:") || text.hasPrefix("[Using Skill:") {
            if let endOfLine = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: endOfLine)...])
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                return StrippedResult(cleanContent: "", jsonData: nil)
            }
        }

        // Remove fenced code block (```json ... ``` or ``` ... ```)
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                let afterOpenFence = text.index(after: firstNewline)
                let remainder = String(text[afterOpenFence...])

                // Find closing ```
                if let closingRange = remainder.range(of: "```") {
                    // Extract the JSON content between the fences
                    extractedJSON = String(remainder[remainder.startIndex..<closingRange.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    text = String(remainder[closingRange.upperBound...])
                }
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if extractedJSON == nil, text.hasPrefix("{"), let jsonEnd = findMatchingBrace(in: text) {
            extractedJSON = String(text[text.startIndex...jsonEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let afterJSON = text.index(after: jsonEnd)
            text = String(text[afterJSON...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if extractedJSON == nil,
           let toolCall = extractGemmaToolCall(from: text) {
            extractedJSON = toolCall.jsonData
            text = toolCall.remainingText
        } else if extractedJSON == nil,
                  let remainingText = stripMalformedGemmaToolCall(from: text) {
            text = remainingText
        }

        return StrippedResult(cleanContent: text, jsonData: extractedJSON)
    }

    private static func extractGemmaToolCall(from text: String) -> (jsonData: String, remainingText: String)? {
        guard let startRange = text.range(of: "<|tool_call>") else {
            return nil
        }

        let afterStart = text[startRange.upperBound...]
        let endMarkers = ["<|/tool_call>", "</tool_call>", "<tool_call>"]
        let endRange = endMarkers
            .compactMap { afterStart.range(of: $0) }
            .min { $0.lowerBound < $1.lowerBound }

        let callText: String
        let remainingText: String
        if let endRange {
            callText = String(afterStart[..<endRange.lowerBound])
            remainingText = String(afterStart[endRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            callText = String(afterStart)
            remainingText = ""
        }

        guard let jsonData = normalizeGemmaToolCall(callText) else {
            return nil
        }

        return (jsonData, remainingText)
    }

    private static func stripMalformedGemmaToolCall(from text: String) -> String? {
        guard let startRange = text.range(of: "<|tool_call>") else {
            return nil
        }

        let prefix = String(text[..<startRange.lowerBound])
        let afterStart = text[startRange.upperBound...]
        let endMarkers = ["<|/tool_call>", "<tool_call|>", "</tool_call>", "<tool_call>"]
        let endRange = endMarkers
            .compactMap { afterStart.range(of: $0) }
            .min { $0.lowerBound < $1.lowerBound }

        let suffix: String
        if let endRange {
            suffix = String(afterStart[endRange.upperBound...])
        } else {
            suffix = ""
        }

        return (prefix + suffix).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeGemmaToolCall(_ callText: String) -> String? {
        let trimmed = callText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("call:") else {
            return nil
        }

        let afterCall = String(trimmed.dropFirst("call:".count))
        let toolName: String
        let payload: String
        if let payloadStart = afterCall.firstIndex(of: "{") {
            toolName = String(afterCall[..<payloadStart])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            payload = String(afterCall[payloadStart...])
        } else {
            toolName = afterCall.trimmingCharacters(in: .whitespacesAndNewlines)
            payload = "{}"
        }

        guard let dataPayload = extractDataPayload(from: payload),
              let dataJSON = normalizeLooseObject(dataPayload),
              let data = dataJSON.data(using: .utf8),
              let toolArgs = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        let object: [String: Any] = [
            "tool_name": toolName,
            "tool_args": toolArgs
        ]

        guard JSONSerialization.isValidJSONObject(object),
              let jsonData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]),
              let json = String(data: jsonData, encoding: .utf8) else {
            return nil
        }

        return json
    }

    private static func extractDataPayload(from payload: String) -> String? {
        guard let dataRange = payload.range(of: "data:") else {
            return payload
        }

        let afterData = payload[dataRange.upperBound...]
        guard let objectStart = afterData.firstIndex(of: "{") else {
            return nil
        }

        let objectText = String(afterData[objectStart...])
        guard let objectEnd = findMatchingBrace(in: objectText) else {
            return nil
        }

        return String(objectText[objectText.startIndex...objectEnd])
    }

    private static func normalizeLooseObject(_ objectText: String) -> String? {
        var normalized = objectText
            .replacingOccurrences(of: "<|\">", with: "\"")
            .replacingOccurrences(of: "<|'>", with: "\"")
            .replacingOccurrences(of: "'", with: "\"")

        let keyPattern = #"([{\s,])([A-Za-z_][A-Za-z0-9_-]*)\s*:"#
        guard let regex = try? NSRegularExpression(pattern: keyPattern) else {
            return nil
        }

        let range = NSRange(normalized.startIndex..., in: normalized)
        normalized = regex.stringByReplacingMatches(
            in: normalized,
            options: [],
            range: range,
            withTemplate: "$1\"$2\":"
        )

        return normalized
    }

    private static func findMatchingBrace(in string: String) -> String.Index? {
        var depth = 0
        var isInString = false
        var isEscaped = false

        for index in string.indices {
            let character = string[index]

            if isInString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInString = false
                }
                continue
            }

            if character == "\"" {
                isInString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }
        }

        return nil
    }
}
