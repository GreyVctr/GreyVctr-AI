import Foundation

/// Parses the formatted transcript stored in history for conversation-style entries.
enum HistoryConversationTranscriptParser {

    static func messages(from transcript: String) -> [ChatMessage] {
        let lines = transcript.components(separatedBy: .newlines)
        var messages: [ChatMessage] = []
        var currentRole: MessageRole?
        var currentLines: [String] = []

        func flushMessage() {
            guard let currentRole else { return }
            let content = currentLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return }
            messages.append(ChatMessage(role: currentRole, content: content))
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if let role = role(from: trimmed) {
                flushMessage()
                currentRole = role
                currentLines = []
                continue
            }

            if trimmed == "---" {
                flushMessage()
                currentRole = nil
                currentLines = []
                continue
            }

            if currentRole != nil {
                currentLines.append(line)
            }
        }

        flushMessage()
        return messages
    }

    private static func role(from line: String) -> MessageRole? {
        switch line {
        case "**User**":
            return .user
        case "**Assistant**":
            return .model
        case "**System**":
            return .system
        default:
            return nil
        }
    }
}
