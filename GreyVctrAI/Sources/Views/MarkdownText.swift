import SwiftUI
import MarkdownUI
import LaTeXSwiftUI
import Foundation

private enum MarkdownRenderingLimits {
    static let formattedCharacterLimit = 12_000
    static let streamingFormattedCharacterLimit = 8_000
}

private final class MarkdownRenderCache {
    static let shared = MarkdownRenderCache()

    private final class MarkdownBlockBox: NSObject {
        let blocks: [MarkdownRenderBlock]
        init(blocks: [MarkdownRenderBlock]) {
            self.blocks = blocks
        }
    }

    private final class StreamingBlockBox: NSObject {
        let blocks: [StreamingMarkdownBlock]
        init(blocks: [StreamingMarkdownBlock]) {
            self.blocks = blocks
        }
    }

    private let markdownCache = NSCache<NSString, MarkdownBlockBox>()
    private let streamingCache = NSCache<NSString, StreamingBlockBox>()

    func markdownBlocks(for content: String, builder: () -> [MarkdownRenderBlock]) -> [MarkdownRenderBlock] {
        let key = content as NSString
        if let cached = markdownCache.object(forKey: key) {
            return cached.blocks
        }

        let blocks = builder()
        markdownCache.setObject(MarkdownBlockBox(blocks: blocks), forKey: key)
        return blocks
    }

    func streamingBlocks(for content: String, builder: () -> [StreamingMarkdownBlock]) -> [StreamingMarkdownBlock] {
        let key = content as NSString
        if let cached = streamingCache.object(forKey: key) {
            return cached.blocks
        }

        let blocks = builder()
        streamingCache.setObject(StreamingBlockBox(blocks: blocks), forKey: key)
        return blocks
    }
}

/// Renders a string as full GitHub-flavored Markdown with LaTeX math support.
///
/// Supports headers, bold, italic, code blocks, lists, tables,
/// blockquotes, and links using the MarkdownUI library.
/// LaTeX math equations ($...$, $$...$$) are rendered using LaTeXSwiftUI.
///
/// Strategy: pure markdown is rendered as one MarkdownUI document. When math
/// delimiters are present, only the blocks containing math are routed through
/// LaTeXSwiftUI so surrounding markdown keeps full MarkdownUI support.
struct MarkdownText: View {
    let content: String

    private var shouldUsePlainText: Bool {
        content.count > MarkdownRenderingLimits.formattedCharacterLimit ||
        !MarkdownSyntaxDetector.containsMarkdownFormatting(in: content)
    }

    private var sanitizedContent: String {
        MarkdownMathDetector.stripMarkdownFromMath(content)
    }

    private var blocks: [MarkdownRenderBlock] {
        MarkdownRenderCache.shared.markdownBlocks(for: "markdown-math:\(sanitizedContent)") {
            MarkdownMathDetector.renderBlocks(in: sanitizedContent)
        }
    }

    var body: some View {
        if shouldUsePlainText {
            Text(content)
                .textSelection(.enabled)
        } else if blocks.count == 1, blocks[0].kind == .markdown {
            Markdown(blocks[0].content)
                .textSelection(.enabled)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(blocks) { block in
                    switch block.kind {
                    case .markdown:
                        Markdown(block.content)
                            .textSelection(.enabled)
                    case .latex:
                        LaTeX(block.content)
                            .parsingMode(.onlyEquations)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}

struct MarkdownRenderBlock: Identifiable {
    enum Kind: Equatable {
        case markdown
        case latex
    }

    let id: Int
    let content: String
    let kind: Kind
}

/// Streaming-friendly renderer that formats stable completed blocks while
/// keeping the currently active trailing block as plain text.
struct StreamingMarkdownText: View {
    let content: String

    private var shouldUsePlainText: Bool {
        content.count > MarkdownRenderingLimits.streamingFormattedCharacterLimit ||
        !MarkdownSyntaxDetector.containsMarkdownFormatting(in: content)
    }

    private var blocks: [StreamingMarkdownBlock] {
        MarkdownRenderCache.shared.streamingBlocks(for: content) {
            StreamingMarkdownParser.blocks(in: content)
        }
    }

    var body: some View {
        if shouldUsePlainText {
            Text(content)
                .font(.body)
                .textSelection(.enabled)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(blocks) { block in
                    switch block.kind {
                    case .formatted:
                        MarkdownText(content: block.content)
                            .font(.body)
                    case .plain:
                        Text(block.content)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}

enum MarkdownSyntaxDetector {
    static func containsMarkdownFormatting(in content: String) -> Bool {
        guard !content.isEmpty else { return false }

        if content.contains("```") || content.contains("~~~") || content.contains("[$") {
            return true
        }

        if content.contains("**") || content.contains("__") || content.contains("~~") || content.contains("`") {
            return true
        }

        if content.contains("](") || content.contains("![") {
            return true
        }

        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") || trimmed.hasPrefix("> ") || trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                return true
            }
            if trimmed.contains("|") && trimmed.contains("---") {
                return true
            }
        }

        return MarkdownMathDetector.containsMathDelimiter(in: content)
    }
}

struct StreamingMarkdownBlock: Identifiable {
    enum Kind: Equatable {
        case formatted
        case plain
    }

    let id: Int
    let content: String
    let kind: Kind
}

enum StreamingMarkdownParser {
    static func blocks(in content: String) -> [StreamingMarkdownBlock] {
        let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return []
        }

        let rawBlocks = splitParagraphsPreservingFences(normalized)
        let lastIndex = rawBlocks.indices.last

        return rawBlocks.indices.compactMap { index in
            let block = rawBlocks[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !block.isEmpty else { return nil }

            let isLast = index == lastIndex
            let kind: StreamingMarkdownBlock.Kind = shouldFormat(block, isLast: isLast) ? .formatted : .plain
            return StreamingMarkdownBlock(id: index, content: block, kind: kind)
        }
    }

    private static func shouldFormat(_ block: String, isLast: Bool) -> Bool {
        guard hasBalancedCodeFences(in: block),
              hasBalancedMathDelimiters(in: block) else {
            return false
        }

        // Completed paragraphs are stable enough to parse. Keep the active
        // trailing paragraph plain unless it is clearly complete.
        return !isLast || block.hasSuffix(".") || block.hasSuffix("!") || block.hasSuffix("?") || block.hasSuffix("```")
    }

    private static func splitParagraphsPreservingFences(_ content: String) -> [String] {
        var blocks: [String] = []
        var current: [String] = []
        var inCodeFence = false

        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inCodeFence.toggle()
            }

            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !inCodeFence {
                if !current.isEmpty {
                    blocks.append(current.joined(separator: "\n"))
                    current.removeAll()
                }
            } else {
                current.append(line)
            }
        }

        if !current.isEmpty {
            blocks.append(current.joined(separator: "\n"))
        }

        return blocks
    }

    private static func hasBalancedCodeFences(in block: String) -> Bool {
        let fenceCount = block
            .components(separatedBy: .newlines)
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .count

        return fenceCount.isMultiple(of: 2)
    }

    private static func hasBalancedMathDelimiters(in block: String) -> Bool {
        hasBalancedDelimiter("$", in: block) &&
            hasBalancedDelimiter("$$", in: block) &&
            hasBalancedDelimiter("\\(", closing: "\\)", in: block) &&
            hasBalancedDelimiter("\\[", closing: "\\]", in: block)
    }

    private static func hasBalancedDelimiter(_ delimiter: String, in block: String) -> Bool {
        hasBalancedDelimiter(delimiter, closing: delimiter, in: block)
    }

    private static func hasBalancedDelimiter(_ opening: String, closing: String, in block: String) -> Bool {
        var searchRange = block.startIndex..<block.endIndex
        var count = 0

        while let range = block.range(of: opening, range: searchRange) {
            if !isEscaped(block, at: range.lowerBound) {
                count += 1
            }
            searchRange = range.upperBound..<block.endIndex
        }

        if opening != closing {
            searchRange = block.startIndex..<block.endIndex
            while let range = block.range(of: closing, range: searchRange) {
                if !isEscaped(block, at: range.lowerBound) {
                    count -= 1
                }
                searchRange = range.upperBound..<block.endIndex
            }
        }

        return count == 0 || count.isMultiple(of: 2)
    }

    private static func isEscaped(_ text: String, at index: String.Index) -> Bool {
        var slashCount = 0
        var current = index

        while current > text.startIndex {
            current = text.index(before: current)
            guard text[current] == "\\" else { break }
            slashCount += 1
        }

        return slashCount % 2 == 1
    }
}

enum MarkdownMathDetector {
    /// Strips Markdown bold/italic markers that the model wraps around math delimiters.
    /// e.g. "**$\text{C}_8$**" -> "$\text{C}_8$"
    static func stripMarkdownFromMath(_ text: String) -> String {
        var result = text
        // Remove bold markers wrapping math: **$...$** -> $...$
        result = result.replacingOccurrences(of: "**$", with: "$")
        result = result.replacingOccurrences(of: "$**", with: "$")
        // Remove italic markers wrapping math: *$...$* -> $...$
        result = result.replacingOccurrences(of: "*$", with: "$")
        result = result.replacingOccurrences(of: "$*", with: "$")
        // Remove underscore bold/italic: __$...$__ -> $...$
        result = result.replacingOccurrences(of: "__$", with: "$")
        result = result.replacingOccurrences(of: "$__", with: "$")
        result = result.replacingOccurrences(of: "_$", with: "$")
        result = result.replacingOccurrences(of: "$_", with: "$")
        return result
    }

    static func renderBlocks(in content: String) -> [MarkdownRenderBlock] {
        renderInlineMathBlocks(in: stripMarkdownFromMath(content))
    }

    static func renderInlineMathBlocks(in content: String) -> [MarkdownRenderBlock] {
        guard containsMathDelimiter(in: content) else {
            return [MarkdownRenderBlock(id: 0, content: content, kind: .markdown)]
        }

        let characters = Array(content)
        var blocks: [MarkdownRenderBlock] = []
        var index = characters.startIndex
        var textStart = characters.startIndex

        func appendText(upTo endIndex: Int) {
            guard textStart < endIndex else { return }
            blocks.append(
                MarkdownRenderBlock(
                    id: blocks.count,
                    content: String(characters[textStart..<endIndex]),
                    kind: .markdown
                )
            )
        }

        func appendMath(from startIndex: Int, to endIndex: Int) {
            blocks.append(
                MarkdownRenderBlock(
                    id: blocks.count,
                    content: String(characters[startIndex..<endIndex]),
                    kind: .latex
                )
            )
        }

        while index < characters.endIndex {
            guard !isEscaped(characters, at: index) else {
                index += 1
                continue
            }

            if characters[index] == "\\" {
                let next = index + 1
                if next < characters.endIndex,
                   characters[next] == "(",
                   let closingIndex = closingBackslashDelimiterIndex(in: characters, after: next, closing: ")") {
                    appendText(upTo: index)
                    let endIndex = closingIndex + 2
                    appendMath(from: index, to: endIndex)
                    index = endIndex
                    textStart = index
                    continue
                }

                if next < characters.endIndex,
                   characters[next] == "[",
                   let closingIndex = closingBackslashDelimiterIndex(in: characters, after: next, closing: "]") {
                    appendText(upTo: index)
                    let endIndex = closingIndex + 2
                    appendMath(from: index, to: endIndex)
                    index = endIndex
                    textStart = index
                    continue
                }
            }

            if characters[index] == "$", isValidDollarOpening(characters, at: index) {
                let isBlock = nextCharacter(in: characters, after: index) == "$"
                if let closingIndex = closingDollarIndex(in: characters, after: index, isBlock: isBlock) {
                    appendText(upTo: index)
                    let endIndex = closingIndex + (isBlock ? 2 : 1)
                    appendMath(from: index, to: endIndex)
                    index = endIndex
                    textStart = index
                    continue
                }
            }

            index += 1
        }

        appendText(upTo: characters.endIndex)
        return blocks.isEmpty ? [MarkdownRenderBlock(id: 0, content: content, kind: .markdown)] : blocks
    }

    static func containsMathDelimiter(in content: String) -> Bool {
        let characters = Array(content)

        for index in characters.indices {
            guard !isEscaped(characters, at: index) else { continue }

            if characters[index] == "\\" {
                let next = characters.index(after: index)
                if next < characters.endIndex,
                   characters[next] == "(",
                   hasClosingBackslashDelimiter(in: characters, after: next, closing: ")") {
                    return true
                }
                if next < characters.endIndex,
                   characters[next] == "[",
                   hasClosingBackslashDelimiter(in: characters, after: next, closing: "]") {
                    return true
                }
            }

            if characters[index] == "$", isValidDollarOpening(characters, at: index) {
                let isBlock = nextCharacter(in: characters, after: index) == "$"
                if closingDollarIndex(in: characters, after: index, isBlock: isBlock) != nil {
                    return true
                }
            }
        }

        return false
    }

    private static func closingDollarIndex(
        in characters: [Character],
        after openingIndex: Int,
        isBlock: Bool
    ) -> Int? {
        var index = openingIndex + (isBlock ? 2 : 1)

        while index < characters.endIndex {
            guard characters[index] == "$", !isEscaped(characters, at: index) else {
                index += 1
                continue
            }

            if isBlock {
                let next = nextCharacter(in: characters, after: index)
                if next == "$" {
                    return index
                }
            } else if isValidSingleDollarClosing(characters, at: index) {
                return index
            }

            index += 1
        }

        return nil
    }

    private static func hasClosingBackslashDelimiter(
        in characters: [Character],
        after openingIndex: Int,
        closing: Character
    ) -> Bool {
        closingBackslashDelimiterIndex(in: characters, after: openingIndex, closing: closing) != nil
    }

    private static func closingBackslashDelimiterIndex(
        in characters: [Character],
        after openingIndex: Int,
        closing: Character
    ) -> Int? {
        var index = openingIndex + 1

        while index < characters.endIndex {
            if characters[index] == "\\",
               !isEscaped(characters, at: index),
               nextCharacter(in: characters, after: index) == closing {
                return index
            }

            index += 1
        }

        return nil
    }

    private static func isValidDollarOpening(_ characters: [Character], at index: Int) -> Bool {
        if nextCharacter(in: characters, after: index) == "$" {
            return true
        }

        guard let next = nextCharacter(in: characters, after: index) else {
            return false
        }

        return !next.isWhitespace && !next.isNumber
    }

    private static func isValidSingleDollarClosing(_ characters: [Character], at index: Int) -> Bool {
        guard previousCharacter(in: characters, before: index) != "$",
              nextCharacter(in: characters, after: index) != "$",
              let previous = previousCharacter(in: characters, before: index) else {
            return false
        }

        return !previous.isWhitespace
    }

    private static func isEscaped(_ characters: [Character], at index: Int) -> Bool {
        var slashCount = 0
        var current = index - 1

        while current >= characters.startIndex, characters[current] == "\\" {
            slashCount += 1
            current -= 1
        }

        return slashCount % 2 == 1
    }

    private static func nextCharacter(in characters: [Character], after index: Int) -> Character? {
        let next = index + 1
        return next < characters.endIndex ? characters[next] : nil
    }

    private static func previousCharacter(in characters: [Character], before index: Int) -> Character? {
        let previous = index - 1
        return previous >= characters.startIndex ? characters[previous] : nil
    }
}

#if DEBUG
#Preview {
    ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            MarkdownText(content: "**Bold** and *italic*")
            MarkdownText(content: "# Header\n\nParagraph with `inline code`.")
            MarkdownText(content: "- Item 1\n- Item 2\n- Item 3")
            MarkdownText(content: "The formula is $E = mc^2$ and water is $H_2O$.")
            MarkdownText(content: "Carbon dioxide: $\\text{CO}_2$")
            MarkdownText(content: "Budget is $25.\n\nFormula: $E = mc^2$")
        }
        .padding()
    }
}
#endif
