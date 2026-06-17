import SwiftUI

/// Renders assistant message text as lightweight *block-level* markdown.
///
/// `MessageBubble` previously rendered the whole reply through a single `Text`
/// with `.inlineOnlyPreservingWhitespace`, which only styles inline syntax
/// (bold / italic / links / inline code). Block constructs — fenced code blocks
/// (```` ``` ````), headings, and lists — came through as raw `#`, `-`, and
/// triple-backtick characters, so anything the model returned as a code block was
/// unreadable. A single `Text` can't lay out those block constructs reliably, so
/// we split the reply into blocks and give each its own view. Fenced code blocks
/// render in a monospaced, selectable, horizontally-scrollable card; prose,
/// headings, and list items keep SwiftUI's inline markdown for their text runs.
///
/// Streaming-safe: an unterminated opening fence (the model is mid-emitting a code
/// block) is treated as a code block running to the end of the text, so partial
/// output still reads as code rather than flashing raw backticks.
struct MarkdownMessageView: View {
    let text: String
    @State private var parsedBlocks: [MarkdownBlock] = []

    var body: some View {
        VStack(alignment: .leading, spacing: WP.Space.sm) {
            ForEach(Array(parsedBlocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: text, initial: true) { _, newText in
            parsedBlocks = MarkdownBlock.parse(newText)
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .code(let code):
            CodeBlockView(code: code)
        case .heading(let level, let inline):
            Text(Self.inlineAttributed(inline))
                .font(.system(size: Self.headingSize(level), weight: .semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .tint(.accentColor)
        case .listItem(let marker, let inline):
            HStack(alignment: .top, spacing: WP.Space.sm) {
                Text(marker)
                    .font(WP.TextStyle.body)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(Self.inlineAttributed(inline))
                    .font(WP.TextStyle.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tint(.accentColor)
            }
        case .paragraph(let inline):
            Text(Self.inlineAttributed(inline))
                .font(WP.TextStyle.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .tint(.accentColor)
        }
    }

    private static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 16
        case 2: return 14
        default: return 13
        }
    }

    /// Inline-only markdown so `**bold**`, `*italic*`, `[links]()`, and `` `code` ``
    /// render as styled runs while we keep block layout to the surrounding views.
    static func inlineAttributed(_ raw: String) -> AttributedString {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return AttributedString(" ") }
        let parsed = try? AttributedString(
            markdown: trimmed,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        return parsed ?? AttributedString(trimmed)
    }
}

/// A fenced code block rendered as a monospaced, selectable card. Scrolls
/// horizontally so long lines don't force the overlay wider or wrap mid-token.
private struct CodeBlockView: View {
    let code: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.primary)
                .padding(WP.Space.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            RoundedRectangle(cornerRadius: WP.Radius.md, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: WP.Radius.md, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        )
    }
}

/// One block of parsed markdown. Inline runs (`paragraph` / `heading` / `listItem`)
/// still carry their raw markdown so the view layer can apply inline styling; only
/// the block-level marker (`#`, `-`, fence) is consumed here.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case listItem(marker: String, text: String)
    case paragraph(String)
    case code(String)

    /// Splits raw markdown into block-level pieces. Deliberately lightweight — it
    /// recognizes fenced code blocks, ATX headings, and unordered/ordered list
    /// items, and groups everything else into paragraphs separated by blank lines.
    /// It does not attempt nested lists, tables, or blockquotes; those degrade to
    /// paragraphs, which is acceptable for short chat replies.
    static func parse(_ raw: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        // Split on newlines, preserving empty lines so paragraph breaks survive.
        let lines = raw.components(separatedBy: "\n")
        var paragraphBuffer: [String] = []
        var codeBuffer: [String] = []
        var inCode = false

        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else { return }
            let joined = paragraphBuffer.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraphBuffer.removeAll()
        }

        func flushCode() {
            // Keep code exactly as written (only trim a trailing newline run) so
            // indentation and blank lines inside the block are preserved verbatim.
            let joined = codeBuffer.joined(separator: "\n")
            blocks.append(.code(trimTrailingNewlines(joined)))
            codeBuffer.removeAll()
        }

        for line in lines {
            let trimmedLeading = line.drop { $0 == " " }
            if trimmedLeading.hasPrefix("```") {
                if inCode {
                    flushCode()
                    inCode = false
                } else {
                    flushParagraph()
                    inCode = true
                }
                continue
            }
            if inCode {
                codeBuffer.append(line)
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            if let heading = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                continue
            }
            if let item = parseListItem(trimmed) {
                flushParagraph()
                blocks.append(item)
                continue
            }
            paragraphBuffer.append(line)
        }

        // End of input: flush whatever is still buffered. An unterminated fence
        // (streaming mid-block) still renders as a code block.
        if inCode {
            flushCode()
        } else {
            flushParagraph()
        }
        return blocks
    }

    /// ATX heading: 1–6 leading `#` followed by a space. Returns the level and the
    /// remaining inline text, or nil when the line isn't a heading.
    private static func parseHeading(_ line: String) -> MarkdownBlock? {
        var level = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == "#", level < 6 {
            level += 1
            idx = line.index(after: idx)
        }
        guard level > 0, idx < line.endIndex, line[idx] == " " else { return nil }
        let text = String(line[idx...]).trimmingCharacters(in: .whitespaces)
        return .heading(level: level, text: text)
    }

    /// Unordered (`- ` / `* ` / `+ `) or ordered (`1. `) list item. Returns the
    /// display marker plus the remaining inline text, or nil when not a list line.
    private static func parseListItem(_ line: String) -> MarkdownBlock? {
        // Unordered
        for bullet in ["- ", "* ", "+ "] where line.hasPrefix(bullet) {
            let text = String(line.dropFirst(bullet.count)).trimmingCharacters(in: .whitespaces)
            return .listItem(marker: "•", text: text)
        }
        // Ordered: digits then ". "
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty {
            let afterDigits = line[line.index(line.startIndex, offsetBy: digits.count)...]
            if afterDigits.hasPrefix(". ") {
                let text = String(afterDigits.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                return .listItem(marker: "\(digits).", text: text)
            }
        }
        return nil
    }

    private static func trimTrailingNewlines(_ s: String) -> String {
        var result = s
        while result.hasSuffix("\n") { result.removeLast() }
        return result
    }
}
