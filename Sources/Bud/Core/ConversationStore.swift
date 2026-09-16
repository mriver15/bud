import Foundation

/// Reads and writes the conversation archive.
///
/// Failure is never fatal and never throws. A history that cannot be read is a
/// lost history; a history that takes the app down with it is a lost app, and
/// the file is written by the same process that would be crashing.
public enum ConversationStore {
    public static let currentVersion = 1

    /// How many conversations are kept. Old ones are dropped by recency, which
    /// is the only ordering a person can predict.
    public static let retentionLimit = 50

    /// Tool output is the one thing that grows without bound — a single
    /// `run_shell` can return megabytes, and transcripts are mostly tool output
    /// by volume. Truncated on the way to disk only; the live transcript and the
    /// model-facing history keep the full text, so a resumed conversation still
    /// answers from complete data.
    public static let resultTextLimit = 16_000

    /// - Parameter url: overridable so the round trip can be tested without
    ///   writing over the archive the user is actually using.
    public static func load(from url: URL = BudConfigLoader.conversationsURL) -> ConversationArchive {
        guard let data = try? Data(contentsOf: url),
              let archive = try? decoder.decode(ConversationArchive.self, from: data),
              archive.version <= currentVersion
        else {
            return ConversationArchive()
        }
        return ConversationArchive(
            version: currentVersion,
            currentID: archive.currentID,
            conversations: archive.conversations.map(sanitize)
        )
    }

    public static func save(_ archive: ConversationArchive, to url: URL = BudConfigLoader.conversationsURL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let kept = ConversationArchive(
            version: currentVersion,
            currentID: archive.currentID,
            conversations: Array(
                archive.conversations
                    .sorted { $0.updatedAt > $1.updatedAt }
                    .prefix(retentionLimit)
                    .map(sanitize)
            )
        )
        guard let data = try? encoder.encode(kept) else { return }
        try? data.write(to: url, options: [.atomic])
        // The transcript is the most revealing thing this app writes down.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    // MARK: - Plumbing

    /// Clears anything that described a moment in time rather than a
    /// conversation.
    ///
    /// A turn saved mid-stream would otherwise come back with a spinner that
    /// never stops, because nothing is streaming it — the state is real at the
    /// moment of writing and a lie by the time it is read.
    private static func sanitize(_ conversation: Conversation) -> Conversation {
        var conversation = conversation
        conversation.turns = conversation.turns.map { turn in
            var turn = turn
            turn.isStreaming = false
            turn.segments = turn.segments.map { segment in
                guard case .tool(let id, let call, let provider, let state, let result, let ui) = segment
                else { return segment }
                // A tool that was running when the app quit never finished.
                let settled: ToolRunState = state == .running || state == .queued ? .failed : state
                return .tool(
                    id: id,
                    call: call,
                    providerName: provider,
                    state: settled,
                    resultText: result.map(clamp),
                    ui: ui
                )
            }
            return turn
        }
        return conversation
    }

    private static func clamp(_ text: String) -> String {
        guard text.count > resultTextLimit else { return text }
        let cutoff = text.index(text.startIndex, offsetBy: resultTextLimit)
        return String(text[..<cutoff]) + "\n\n…[\(text.count - resultTextLimit) characters not saved]"
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        // Readable on purpose: this file is the one a person may need to inspect
        // by hand, and the size it costs is paid once per turn.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
