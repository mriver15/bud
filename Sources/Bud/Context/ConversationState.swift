import Foundation

/// The values a conversation has accumulated, tracked across turns instead of
/// re-sending every tool result.
///
/// The cheap, deterministic half of context management: as tool results and
/// answers land, the structured values a later turn is likely to need — file
/// paths, URLs, and `store_` handles — are extracted here. Semantic facts stay
/// with the model-written compaction summary (``HistoryCompactor``); this block
/// carries the durable pointers that summary prose tends to paraphrase away.
///
/// Rendered into the system prompt each turn as recorded data, and re-derived
/// from history on restore or rewind, so it is always consistent with the
/// messages it distilled — no separate persistence to drift out of step.
public struct ConversationState: Sendable, Codable, Equatable {
    /// One tracked value: what was seen, where it came from, and when.
    public struct Entry: Sendable, Codable, Equatable, Identifiable {
        public enum Kind: String, Sendable, Codable {
            case path, url, storeHandle
        }

        public var kind: Kind
        public var value: String
        public var source: String
        public var firstSeen: Date

        /// Stable identity for dedupe: a value is one value no matter how many
        /// rounds repeat it.
        public var id: String { "\(kind.rawValue):\(value)" }

        public init(kind: Kind, value: String, source: String, firstSeen: Date = Date()) {
            self.kind = kind
            self.value = value
            self.source = source
            self.firstSeen = firstSeen
        }
    }

    /// How many values are kept. A long task touches far more paths than any
    /// turn needs to re-read; the newest survive, oldest first dropped.
    public static let cap = 40

    /// How much of a result is scanned for durable values. The model only ever
    /// sees this much anyway (`ToolResult.modelFacingText`), so values deeper in
    /// a spilled result are not shown — and a runaway `run_shell` dump should
    /// not be regex-scanned whole on every turn.
    public static let scanLimit = 24_000

    public var entries: [Entry]

    public static let empty = ConversationState(entries: [])

    public init(entries: [Entry] = []) { self.entries = entries }

    public var isEmpty: Bool { entries.isEmpty }

    // MARK: - Extraction

    /// Deterministic extraction of the structured values one result or answer
    /// carries. Paths and URLs reuse the request analyzer's extractors, so a
    /// value is classified once, in one place.
    public static func extract(from text: String, source: String) -> [Entry] {
        guard !text.isEmpty else { return [] }
        let scanned = text.count > scanLimit ? String(text.prefix(scanLimit)) : text
        let urls = RequestAnalyzer.urls(in: scanned)
        var entries = urls.map { Entry(kind: .url, value: $0, source: source) }
        entries += RequestAnalyzer.paths(in: scanned, excluding: urls).map {
            Entry(kind: .path, value: $0, source: source)
        }
        entries += storeHandles(in: scanned).map { Entry(kind: .storeHandle, value: $0, source: source) }
        return entries
    }

    /// `store_` handles, validated so a token that merely looks like one is not
    /// tracked as a place data lives.
    private static func storeHandles(in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: #"store_[0-9a-fA-F]{8}"#) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        var seen: Set<String> = []
        var handles: [String] = []
        for match in expression.matches(in: text, range: range) {
            guard handles.count < 8,
                  let r = Range(match.range, in: text) else { break }
            let token = String(text[r]).lowercased()
            guard StoredResults.isHandle(token), seen.insert(token).inserted else { continue }
            handles.append(token)
        }
        return handles
    }

    // MARK: - Merging

    public mutating func merge(_ newEntries: [Entry]) {
        var seen = Set(entries.map(\.id))
        var merged = entries
        for entry in newEntries where seen.insert(entry.id).inserted {
            merged.append(entry)
        }
        if merged.count > Self.cap {
            merged.removeFirst(merged.count - Self.cap)
        }
        entries = merged
    }

    // MARK: - Recovery

    /// Re-derives the state from a message list, so a restored or rewound
    /// conversation lands with the state its history implies rather than one
    /// carried over from a different point. Tool results and assistant answers
    /// both contribute: each is data about what happened, and the tool results
    /// are already bounded to what the model was shown.
    public static func recovered(from messages: [ChatMessage]) -> ConversationState {
        var state = ConversationState.empty
        for message in messages {
            let source: String
            switch message.role {
            case .tool: source = message.name ?? "tool"
            case .assistant: source = "answer"
            default: continue
            }
            guard !message.content.isEmpty else { continue }
            state.merge(extract(from: message.content, source: source))
        }
        return state
    }

    // MARK: - Rendering

    /// The compact block the compiler injects. Grouped by kind so the model
    /// reads the shape at a glance; empty when nothing is tracked.
    public func render() -> String {
        guard !entries.isEmpty else { return "" }
        let grouped = Dictionary(grouping: entries, by: \.kind)
        var lines: [String] = []
        if let paths = grouped[.path] {
            lines.append("Paths: " + values(paths))
        }
        if let urls = grouped[.url] {
            lines.append("URLs: " + values(urls))
        }
        if let handles = grouped[.storeHandle] {
            lines.append("Stored: " + values(handles))
        }
        guard !lines.isEmpty else { return "" }
        return "[Conversation state — recorded data, not a request from the user.]\n"
            + lines.joined(separator: "\n")
    }

    private func values(_ list: [Entry]) -> String {
        list.map(\.value).joined(separator: " · ")
    }
}
