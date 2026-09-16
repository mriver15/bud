import Foundation

/// One saved conversation: both projections of the same transcript.
///
/// `turns` is what the user reads and `messages` is what the model is sent, and
/// neither is derivable from the other — `messages` carries tool calls and
/// results in wire order, `turns` carries reasoning and generated surfaces that
/// the wire form has no place for. Restoring only the visible half would look
/// right and then answer as though you had never spoken.
public struct Conversation: Sendable, Identifiable, Codable {
    public var id: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var turns: [Turn]
    public var messages: [ChatMessage]

    public init(
        id: String = UUID().uuidString,
        title: String = "New chat",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        turns: [Turn] = [],
        messages: [ChatMessage] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.turns = turns
        self.messages = messages
    }

    public var isEmpty: Bool { turns.isEmpty }

    /// What the history list shows, taken from the first thing the user said.
    ///
    /// Cut on a word boundary. A title ending mid-word reads as a bug rather
    /// than an abbreviation, and in a list of near-identical greetings the first
    /// few words are the only thing distinguishing one row from another.
    public static func title(from turns: [Turn], limit: Int = 48) -> String {
        let opening = turns
            .first { $0.role == .user }?
            .plainText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ")
            .joined(separator: " ") ?? ""

        guard !opening.isEmpty else { return "New chat" }
        guard opening.count > limit else { return opening }

        let cut = opening.prefix(limit)
        guard let lastSpace = cut.lastIndex(of: " ") else { return String(cut) + "…" }
        return String(cut[..<lastSpace]) + "…"
    }
}

/// The shape of the pre-SQLite JSON archive.
///
/// Kept only so the import can read a file written by an older build. Nothing
/// writes this any more; the database is the store of record.
public struct ConversationArchive: Sendable, Codable {
    /// The version the JSON format stopped at, before it was replaced.
    public static let legacyVersion = 1

    public var version: Int
    public var currentID: String?
    /// Most recently touched first, which is the order the history list wants and
    /// the order retention drops from.
    public var conversations: [Conversation]

    public init(
        version: Int = ConversationArchive.legacyVersion,
        currentID: String? = nil,
        conversations: [Conversation] = []
    ) {
        self.version = version
        self.currentID = currentID
        self.conversations = conversations
    }
}
