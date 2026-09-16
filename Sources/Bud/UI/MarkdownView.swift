import AppKit
import Foundation
import SwiftUI

/// Natively-rendered assistant markdown.
///
/// The block structure is parsed here rather than handed to
/// `AttributedString(markdown:)`, because that initialiser collapses fenced code
/// blocks, lists and rules into running prose — precisely the constructs a
/// coding assistant emits constantly. Only inline runs are delegated to
/// Foundation, which is where it is actually good.
public struct MarkdownView: View {
    private let blocks: [MarkdownBlock]
    private let showsCaret: Bool
    /// The live find query, marked wherever it occurs. Nil when nothing is being
    /// searched for, which is the case the vast majority of the time.
    private let highlight: String?

    /// Plain rendering, no caret.
    public init(_ text: String, highlight: String? = nil) {
        self.init(blocks: MarkdownParser.parse(text), showsCaret: false, highlight: highlight)
    }

    /// Streaming rendering. The caret blinks on the final block so a message
    /// that is still arriving reads as live text instead of a frozen fragment.
    public init(_ text: String, showsCaret: Bool, highlight: String? = nil) {
        self.init(blocks: MarkdownParser.parse(text), showsCaret: showsCaret, highlight: highlight)
    }

    private init(blocks: [MarkdownBlock], showsCaret: Bool, highlight: String?) {
        self.blocks = blocks
        self.showsCaret = showsCaret
        self.highlight = highlight
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Bud.Space.sm) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                if showsCaret, index == blocks.count - 1 {
                    // Only the tail block re-renders on the blink interval, so
                    // the rest of a long message is not re-laid out twice a second.
                    TimelineView(.periodic(from: .now, by: 0.5)) { context in
                        blockView(block, caret: Self.caretIsVisible(at: context.date))
                    }
                } else {
                    blockView(block, caret: false)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .tint(Bud.Palette.accent)
        .environment(\.openURL, OpenURLAction { url in
            _ = NSWorkspace.shared.open(url)
            return .handled
        })
    }

    // MARK: - Blocks

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock, caret: Bool) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(MarkdownInline.attributed(text, font: Self.headingFont(level), weight: .semibold, caret: caret, highlight: highlight))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, level <= 2 ? Bud.Space.xs : 0)

        case .paragraph(let text):
            Text(MarkdownInline.attributed(text, font: Bud.Font.body, caret: caret, highlight: highlight))
                .fixedSize(horizontal: false, vertical: true)

        case .code(let language, let body):
            MarkdownCodeBlock(language: language, code: caret ? body + MarkdownInline.caretGlyph : body)

        case .bullets(let items):
            MarkdownListView(items: items, ordered: false, start: 1, caret: caret, highlight: highlight)

        case .numbered(let start, let items):
            MarkdownListView(items: items, ordered: true, start: start, caret: caret, highlight: highlight)

        case .quote(let lines):
            VStack(alignment: .leading, spacing: Bud.Space.xs) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    let isLast = caret && index == lines.count - 1
                    Text(MarkdownInline.attributed(line, font: Bud.Font.body, caret: isLast, highlight: highlight))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // Drawn as a background rather than as an HStack sibling: a bare
            // Rectangle is vertically greedy and would stretch to the whole
            // proposed height, not the height of the quote.
            .padding(.leading, Bud.Space.md)
            .background(alignment: .leading) {
                Rectangle()
                    .fill(Bud.Palette.accent.opacity(0.55))
                    .frame(width: 2.5)
            }

        case .rule:
            Rectangle()
                .fill(Color.white.opacity(0.16))
                .frame(height: 1)
                .padding(.vertical, Bud.Space.xs)
        }
    }

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return Bud.Font.hero
        case 2: return Bud.Font.title
        default: return Bud.Font.body
        }
    }

    private static func caretIsVisible(at date: Date) -> Bool {
        Int(date.timeIntervalSinceReferenceDate * 2) % 2 == 0
    }
}

// MARK: - Lists

private struct MarkdownListView: View {
    let items: [MarkdownItem]
    let ordered: Bool
    let start: Int
    let caret: Bool
    let highlight: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Bud.Space.xs) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                let isLast = caret && index == items.count - 1
                HStack(alignment: .firstTextBaseline, spacing: Bud.Space.sm) {
                    Text(marker(at: index))
                        .font(Bud.Font.caption)
                        .foregroundStyle(Bud.Palette.accent.opacity(0.85))
                        .frame(minWidth: 14, alignment: .trailing)
                    Text(MarkdownInline.attributed(item.text, font: Bud.Font.body, caret: isLast, highlight: highlight))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, CGFloat(item.depth) * 14)
            }
        }
    }

    private func marker(at index: Int) -> String {
        ordered ? "\(start + index)." : "•"
    }
}

// MARK: - Code block

private struct MarkdownCodeBlock: View {
    let language: String?
    let code: String

    @BudState private var isHovering = false
    @BudState private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Bud.Space.sm) {
                Text(languageLabel)
                    .font(Bud.Font.micro.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                if isHovering || didCopy {
                    GlassIconButton(
                        systemImage: didCopy ? "checkmark" : "doc.on.doc",
                        help: "Copy code"
                    ) {
                        copy()
                    }
                }
            }
            .padding(.horizontal, Bud.Space.md)
            .frame(height: 28)

            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(Bud.Font.mono)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, Bud.Space.md)
                    .padding(.bottom, Bud.Space.md)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                .fill(Color.black.opacity(0.22))
                .overlay {
                    RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.6)
                }
        }
        .onHover { isHovering = $0 }
    }

    private var languageLabel: String {
        if let language, !language.isEmpty { return language.uppercased() }
        return "CODE"
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            didCopy = false
        }
    }
}

// MARK: - Inline runs

private enum MarkdownInline {
    /// A caret block is drawn as text rather than as an overlay so it sits at
    /// the end of the final wrapped line instead of at the trailing margin.
    static let caretGlyph = "\u{258C}"

    /// The base type comes from the scale as a `Font`; the size the emphasis
    /// runs below need is re-derived by `Font.weight(_:)`/`italic()` rather than
    /// from a raw point size.
    static func attributed(
        _ text: String,
        font: Font,
        weight: Font.Weight = .regular,
        caret: Bool = false,
        highlight: String? = nil
    ) -> AttributedString {
        let source = neutralizeDanglingMarkers(text)
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        var attributed = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)

        // Traits are applied explicitly instead of leaning on
        // `inlinePresentationIntent`, which a `font` set on the enclosing `Text`
        // would otherwise flatten.
        attributed.font = font.weight(weight)
        let runs = attributed.runs.map { (range: $0.range, intent: $0.inlinePresentationIntent) }
        for run in runs {
            guard let intent = run.intent else { continue }
            if intent.contains(.code) {
                attributed[run.range].font = Bud.Font.mono
                attributed[run.range].backgroundColor = Color.white.opacity(0.10)
            } else if intent.contains(.stronglyEmphasized), intent.contains(.emphasized) {
                attributed[run.range].font = font.weight(.semibold).italic()
            } else if intent.contains(.stronglyEmphasized) {
                attributed[run.range].font = font.weight(.semibold)
            } else if intent.contains(.emphasized) {
                attributed[run.range].font = font.italic()
            }
        }

        // Marked after parsing, not before: the source still carries markdown
        // markers, so an offset found there would land in the wrong place once
        // they are consumed.
        if let highlight, !highlight.isEmpty {
            var searchStart = attributed.startIndex
            while searchStart < attributed.endIndex,
                  let found = attributed[searchStart...].range(of: highlight, options: [.caseInsensitive, .diacriticInsensitive]) {
                attributed[found].backgroundColor = Bud.Palette.accent.opacity(0.38)
                searchStart = found.upperBound
            }
        }

        if caret {
            var marker = AttributedString(caretGlyph)
            marker.font = font
            marker.foregroundColor = Bud.Palette.accent
            attributed.append(marker)
        }
        return attributed
    }

    /// Drops a trailing, unpaired emphasis or code marker. While a message
    /// streams, `**bold` or `` `code `` are expected states; rendering their raw
    /// asterisks or backticks as content reads as corruption.
    private static func neutralizeDanglingMarkers(_ text: String) -> String {
        var out = text
        for marker in ["**", "__", "`", "~~", "*", "_"] {
            if occurrences(of: marker, in: out) % 2 == 1, let range = lastOpeningRange(of: marker, in: out) {
                out.removeSubrange(range)
            }
        }
        return out
    }

    private static func occurrences(of marker: String, in text: String) -> Int {
        var count = 0
        var search = text.startIndex..<text.endIndex
        while let range = text.range(of: marker, range: search) {
            count += 1
            search = range.upperBound..<text.endIndex
        }
        return count
    }

    /// The final occurrence of `marker`, but only when it actually opens a span:
    /// that keeps `snake_case` and `2*3` from being mangled.
    private static func lastOpeningRange(of marker: String, in text: String) -> Range<String.Index>? {
        var search = text.startIndex..<text.endIndex
        var last: Range<String.Index>?
        while let range = text.range(of: marker, range: search) {
            last = range
            search = range.upperBound..<text.endIndex
        }
        guard let range = last else { return nil }
        let opensSpan = range.lowerBound == text.startIndex
            || text[text.index(before: range.lowerBound)].isWhitespace
        let hasFollowingContent = range.upperBound == text.endIndex
            || !text[range.upperBound].isWhitespace
        return opensSpan && hasFollowingContent ? range : nil
    }
}

// MARK: - Block model

private enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String?, body: String)
    case bullets([MarkdownItem])
    case numbered(start: Int, items: [MarkdownItem])
    case quote([String])
    case rule
}

private struct MarkdownItem {
    var text: String
    var depth: Int
}

// MARK: - Parser

private enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.components(separatedBy: "\n")
        var index = 0

        while index < lines.count {
            let raw = lines[index]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if let fence = openFence(trimmed) {
                var body: [String] = []
                index += 1
                while index < lines.count {
                    if isClosingFence(lines[index], character: fence.character) {
                        index += 1
                        break
                    }
                    body.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: fence.language, body: body.joined(separator: "\n")))
                continue
            }

            if isRule(trimmed) {
                blocks.append(.rule)
                index += 1
                continue
            }

            if let heading = heading(trimmed) {
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                var quoted: [String] = []
                while index < lines.count {
                    let line = lines[index].trimmingCharacters(in: .whitespaces)
                    guard line.hasPrefix(">") else { break }
                    quoted.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quoted))
                continue
            }

            if let first = bulletItem(raw) {
                var items = [first]
                index += 1
                index = collectItems(lines: lines, from: index, into: &items, match: bulletItem)
                blocks.append(.bullets(items))
                continue
            }

            if let first = orderedItem(raw) {
                var items = [first.item]
                index += 1
                index = collectItems(lines: lines, from: index, into: &items) { orderedItem($0)?.item }
                blocks.append(.numbered(start: first.start, items: items))
                continue
            }

            var paragraph: [String] = []
            while index < lines.count {
                let line = lines[index]
                if line.trimmingCharacters(in: .whitespaces).isEmpty || startsBlock(line) { break }
                paragraph.append(line.trimmingCharacters(in: .whitespaces))
                index += 1
            }
            guard !paragraph.isEmpty else { index += 1; continue }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
        }

        return blocks
    }

    /// Consumes consecutive list items plus their indented continuation lines.
    private static func collectItems(
        lines: [String],
        from startIndex: Int,
        into items: inout [MarkdownItem],
        match: (String) -> MarkdownItem?
    ) -> Int {
        var index = startIndex
        while index < lines.count {
            let raw = lines[index]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if let item = match(raw) {
                items.append(item)
                index += 1
                continue
            }
            if trimmed.isEmpty { break }
            if leadingIndent(raw) >= 2, !startsBlock(raw), let last = items.last {
                items[items.count - 1] = MarkdownItem(text: last.text + " " + trimmed, depth: last.depth)
                index += 1
                continue
            }
            break
        }
        return index
    }

    private static func heading(_ trimmed: String) -> (level: Int, text: String)? {
        var rest = Substring(trimmed)
        var level = 0
        while rest.first == "#" {
            level += 1
            rest = rest.dropFirst()
        }
        guard (1...6).contains(level), rest.isEmpty || rest.first == " " else { return nil }
        let text = String(rest).trimmingCharacters(in: .whitespaces)
        let closing = CharacterSet(charactersIn: "#")
        return (level, text.trimmingCharacters(in: closing).trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3 else { return false }
        let characters = Set(compact)
        return characters.count == 1
            && (characters.contains("-") || characters.contains("*") || characters.contains("_"))
    }

    private static func openFence(_ trimmed: String) -> (character: Character, language: String?)? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let run = trimmed.prefix { $0 == first }
        guard run.count >= 3 else { return nil }
        let info = String(trimmed.dropFirst(run.count)).trimmingCharacters(in: .whitespaces)
        return (first, info.split(separator: " ").first.map(String.init))
    }

    private static func isClosingFence(_ line: String, character: Character) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first == character else { return false }
        let run = trimmed.prefix { $0 == character }
        return run.count >= 3 && run.count == trimmed.count
    }

    private static func bulletItem(_ raw: String) -> MarkdownItem? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "+ ", "• "] where trimmed.hasPrefix(marker) {
            return MarkdownItem(
                text: String(trimmed.dropFirst(marker.count)),
                depth: min(leadingIndent(raw) / 2, 3)
            )
        }
        return nil
    }

    private static func orderedItem(_ raw: String) -> (start: Int, item: MarkdownItem)? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        var digits = ""
        var rest = Substring(trimmed)
        while let character = rest.first, character.isNumber {
            digits.append(character)
            rest = rest.dropFirst()
        }
        guard !digits.isEmpty, digits.count <= 3, let start = Int(digits) else { return nil }
        guard let separator = rest.first, separator == "." || separator == ")" else { return nil }
        let afterSeparator = rest.dropFirst()
        guard afterSeparator.isEmpty || afterSeparator.first?.isWhitespace == true else { return nil }
        let text = String(afterSeparator).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (start, MarkdownItem(text: text, depth: min(leadingIndent(raw) / 2, 3)))
    }

    private static func startsBlock(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        if openFence(trimmed) != nil { return true }
        if isRule(trimmed) { return true }
        if heading(trimmed) != nil { return true }
        if trimmed.hasPrefix(">") { return true }
        if bulletItem(raw) != nil { return true }
        if orderedItem(raw) != nil { return true }
        return false
    }

    private static func leadingIndent(_ raw: String) -> Int {
        var width = 0
        for character in raw {
            if character == " " {
                width += 1
            } else if character == "\t" {
                width += 2
            } else {
                break
            }
        }
        return width
    }
}
