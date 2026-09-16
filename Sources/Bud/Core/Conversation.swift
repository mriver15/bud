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
    /// What this conversation has cost, kept with it so the figure survives being
    /// closed and reopened.
    public var promptTokens: Int
    public var completionTokens: Int
    /// Kept at the top of the archive regardless of when it was last touched.
    public var isPinned: Bool

    public var totalTokens: Int { promptTokens + completionTokens }

    public init(
        id: String = UUID().uuidString,
        title: String = "New chat",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        turns: [Turn] = [],
        messages: [ChatMessage] = [],
        promptTokens: Int = 0,
        completionTokens: Int = 0,
        isPinned: Bool = false
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.turns = turns
        self.messages = messages
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.isPinned = isPinned
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

// MARK: - Export

extension Conversation {
    /// The conversation as a Markdown document.
    ///
    /// Built from the turns rather than the model-facing history. The turns are
    /// what was on screen; the history is a wire format, and exporting it would
    /// put tool-call scaffolding in a document meant to be read.
    ///
    /// Tool output is included but clipped. One tool call can be larger than the
    /// whole conversation around it, and an export is for keeping, not for
    /// reconstituting a session.
    public func markdown(now: Date = Date()) -> String {
        var out = "# \(title)\n\n"
        let stamp = now.formatted(date: .abbreviated, time: .shortened)
        let turns_ = turns.count == 1 ? "1 turn" : "\(turns.count) turns"
        if totalTokens > 0 {
            out += "_\(turns_) · \(totalTokens) tokens · exported \(stamp)_\n\n"
        } else {
            out += "_\(turns_) · exported \(stamp)_\n\n"
        }

        for turn in turns {
            out += turn.role == .user ? "### You\n\n" : "### Bud\n\n"
            for segment in turn.segments {
                switch segment {
                case .text(_, let text):
                    out += text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"

                case .reasoning(_, let text):
                    // Quoted: in the app this is folded away by default, and a
                    // wall of it would bury the answer it was working toward.
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { break }
                    out += trimmed.split(separator: "\n", omittingEmptySubsequences: false)
                        .map { "> \($0)" }
                        .joined(separator: "\n") + "\n\n"

                case .tool(_, let call, let providerName, let state, let resultText, _):
                    out += "> `\(call.name)` · \(providerName) · \(state.rawValue)\n\n"
                    if let resultText, !resultText.isEmpty {
                        out += "```\n\(Self.clipped(resultText))\n```\n\n"
                    }

                case .notice(_, let text, _):
                    out += "> \(text)\n\n"
                }
            }
            if let error = turn.error, !error.isEmpty {
                out += "> ✗ \(error)\n\n"
            }
        }
        return out
    }

    private static func clipped(_ text: String, limit: Int = 4_000) -> String {
        guard text.count > limit else { return text }
        let dropped = text.count - limit
        return String(text.prefix(limit)) + "\n…[clipped \(dropped) characters]"
    }
}
