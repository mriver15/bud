import Foundation

/// A conversation as the history list needs it: enough to render a row without
/// loading a transcript that may be thousands of turns long.
public struct ConversationSummary: Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let updatedAt: Date
    public let turnCount: Int
    /// The opening of the last thing said, for the second line of a row.
    public let preview: String
    /// What this conversation cost, so the archive can say which of them were
    /// expensive rather than only how long they were. Kept apart rather than
    /// summed: a reopened conversation seeds the live counters from these, and a
    /// total alone would turn every historical figure into "all prompt".
    public let promptTokens: Int
    public let completionTokens: Int

    public var tokens: Int { promptTokens + completionTokens }

    public init(
        id: String,
        title: String,
        updatedAt: Date,
        turnCount: Int,
        preview: String,
        promptTokens: Int = 0,
        completionTokens: Int = 0
    ) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.turnCount = turnCount
        self.preview = preview
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}

/// Something worth carrying between conversations.
public struct Lesson: Sendable, Identifiable, Equatable {
    public let id: Int
    public let createdAt: Date
    public let scope: String
    public let text: String

    public init(id: Int, createdAt: Date, scope: String, text: String) {
        self.id = id
        self.createdAt = createdAt
        self.scope = scope
        self.text = text
    }
}

/// Everything Bud keeps, in one place.
///
/// Every method is safe to call from any thread; the connection serialises
/// behind its own lock. Nothing throws. A write that fails is a turn that is
/// still on screen, and taking the app down over a disk error would lose far
/// more than the write it was attempting.
public enum BudStore {
    private static var db: BudDatabase { BudDatabase.shared }

    // MARK: - Conversations

    /// Writes one conversation, replacing its transcript.
    ///
    /// Per conversation rather than per archive. The old store rewrote every
    /// conversation the user had ever had in order to record one turn, so the
    /// cost of saying something grew with the length of your history.
    public static func save(_ conversation: Conversation) {
        let (turns, messages) = sanitize(conversation)
        let turnsJSON = turns.compactMap { encode($0) }
        let messagesJSON = messages.compactMap { encode($0) }

        db.transaction { handle in
            guard let upsert = Statement(handle, """
                INSERT INTO conversations
                    (id, title, created_at, updated_at, prompt_tokens, completion_tokens)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    title = excluded.title,
                    updated_at = excluded.updated_at,
                    prompt_tokens = excluded.prompt_tokens,
                    completion_tokens = excluded.completion_tokens;
                """)
            else { return }
            upsert.bind(1, conversation.id)
                .bind(2, conversation.title)
                .bind(3, conversation.createdAt)
                .bind(4, conversation.updatedAt)
                .bind(5, conversation.promptTokens)
                .bind(6, conversation.completionTokens)
                .run()

            guard let prune = Statement(handle, """
                DELETE FROM conversations WHERE id NOT IN (
                    SELECT id FROM conversations ORDER BY updated_at DESC LIMIT ?
                );
                """),
                  let clearTurns = Statement(handle, "DELETE FROM turns WHERE conversation_id = ?;"),
                  let clearMessages = Statement(handle, "DELETE FROM messages WHERE conversation_id = ?;"),
                  let insertTurn = Statement(handle, """
                    INSERT INTO turns (conversation_id, ordinal, id, role, payload, created_at)
                    VALUES (?, ?, ?, ?, ?, ?);
                    """),
                  let insertMessage = Statement(handle, """
                    INSERT INTO messages (conversation_id, ordinal, role, payload)
                    VALUES (?, ?, ?, ?);
                    """)
            else { return }

            // Bounded, because nothing else deletes conversations and an archive
            // that grows for ever is a disk-space bug that shows up a year later.
            prune.bind(1, retentionLimit).run()
            clearTurns.bind(1, conversation.id).run()
            clearMessages.bind(1, conversation.id).run()

            for (index, turn) in turnsJSON.enumerated() {
                insertTurn.bind(1, conversation.id)
                    .bind(2, index)
                    .bind(3, turns[index].id)
                    .bind(4, turns[index].role.rawValue)
                    .bind(5, turn)
                    .bind(6, turns[index].createdAt)
                    .run()
            }
            for (index, message) in messagesJSON.enumerated() {
                insertMessage.bind(1, conversation.id)
                    .bind(2, index)
                    .bind(3, messages[index].role.rawValue)
                    .bind(4, message)
                    .run()
            }
        }
    }

    public static func load(id: String) -> Conversation? {
        db.read { handle -> Conversation? in
            guard let header = Statement(handle, """
                SELECT title, created_at, updated_at FROM conversations WHERE id = ?;
                """) else { return nil }
            header.bind(1, id)
            guard header.next(), let title = header.string(0) else { return nil }
            let createdAt = header.date(1) ?? Date()
            let updatedAt = header.date(2) ?? createdAt

            var turns: [Turn] = []
            if let statement = Statement(handle, """
                SELECT payload FROM turns WHERE conversation_id = ? ORDER BY ordinal ASC;
                """) {
                statement.bind(1, id)
                while statement.next() {
                    if let raw = statement.string(0), let turn = decode(raw, as: Turn.self) {
                        turns.append(turn)
                    }
                }
            }

            var messages: [ChatMessage] = []
            if let statement = Statement(handle, """
                SELECT payload FROM messages WHERE conversation_id = ? ORDER BY ordinal ASC;
                """) {
                statement.bind(1, id)
                while statement.next() {
                    if let raw = statement.string(0), let message = decode(raw, as: ChatMessage.self) {
                        messages.append(message)
                    }
                }
            }

            return Conversation(
                id: id, title: title, createdAt: createdAt, updatedAt: updatedAt,
                turns: turns, messages: messages
            )
        } ?? nil
    }

    public static func list(limit: Int = 200) -> [ConversationSummary] {
        db.read { handle -> [ConversationSummary] in
            guard let statement = Statement(handle, """
                SELECT c.id, c.title, c.updated_at,
                       (SELECT COUNT(*) FROM turns t WHERE t.conversation_id = c.id),
                       COALESCE((SELECT t.payload FROM turns t
                                 WHERE t.conversation_id = c.id
                                 ORDER BY t.ordinal DESC LIMIT 1), ''),
                       c.prompt_tokens, c.completion_tokens
                FROM conversations c
                ORDER BY c.updated_at DESC
                LIMIT ?;
                """) else { return [] }
            statement.bind(1, limit)

            var rows: [ConversationSummary] = []
            while statement.next() {
                let payload = statement.string(4) ?? ""
                rows.append(ConversationSummary(
                    id: statement.string(0) ?? "",
                    title: statement.string(1) ?? "",
                    updatedAt: statement.date(2) ?? Date(),
                    turnCount: statement.int(3),
                    preview: preview(fromTurnPayload: payload),
                    promptTokens: statement.int(5),
                    completionTokens: statement.int(6)
                ))
            }
            return rows
        } ?? []
    }

    public static func delete(id: String) {
        // Foreign keys cascade, so the turns and messages go with it.
        db.transaction { handle in
            Statement(handle, "DELETE FROM conversations WHERE id = ?;")?.bind(1, id).run()
        }
    }

    public static func rename(id: String, title: String) {
        db.transaction { handle in
            Statement(handle, "UPDATE conversations SET title = ? WHERE id = ?;")?
                .bind(1, title).bind(2, id).run()
        }
    }

    /// Conversations whose title or anything said in them matches.
    ///
    /// `LIKE` rather than a full-text index: this is a personal archive, the
    /// scan is over rows already on the same disk, and an index is another thing
    /// that can disagree with the data it indexes.
    public static func search(_ query: String, limit: Int = 50) -> [ConversationSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Measured on the query, not on the pattern built from it: with the
        // wildcards attached, every input clears a length check and a one-letter
        // search scans the whole archive to tell you it matches everything.
        guard trimmed.count >= 3 else { return [] }
        let needle = "%\(trimmed)%"
        return db.read { handle -> [ConversationSummary] in
            guard let statement = Statement(handle, """
                SELECT c.id, c.title, c.updated_at,
                       (SELECT COUNT(*) FROM turns t WHERE t.conversation_id = c.id),
                       COALESCE((SELECT t.payload FROM turns t
                                 WHERE t.conversation_id = c.id
                                 ORDER BY t.ordinal DESC LIMIT 1), ''),
                       c.prompt_tokens, c.completion_tokens
                FROM conversations c
                WHERE c.title LIKE ?
                   OR EXISTS (SELECT 1 FROM turns t
                              WHERE t.conversation_id = c.id AND t.payload LIKE ?)
                ORDER BY c.updated_at DESC
                LIMIT ?;
                """) else { return [] }
            statement.bind(1, needle).bind(2, needle).bind(3, limit)

            var rows: [ConversationSummary] = []
            while statement.next() {
                rows.append(ConversationSummary(
                    id: statement.string(0) ?? "",
                    title: statement.string(1) ?? "",
                    updatedAt: statement.date(2) ?? Date(),
                    turnCount: statement.int(3),
                    preview: preview(fromTurnPayload: statement.string(4) ?? ""),
                    promptTokens: statement.int(5),
                    completionTokens: statement.int(6)
                ))
            }
            return rows
        } ?? []
    }

    /// How many conversations are kept before the oldest are dropped.
    public static let retentionLimit = 200

    /// Tool output is the one thing that grows without bound — a single
    /// `run_shell` can return megabytes, and transcripts are mostly tool output
    /// by volume. Truncated on the way to disk only; the live transcript keeps
    /// the full text, and the model-facing history is stored whole.
    public static let resultTextLimit = 16_000

    /// Clears anything that described a moment in time rather than a
    /// conversation.
    ///
    /// A turn saved mid-stream would otherwise come back with a spinner that
    /// never stops, because nothing is streaming it. The state is true when it
    /// is written and a lie by the time it is read.
    private static func sanitize(_ conversation: Conversation) -> ([Turn], [ChatMessage]) {
        let turns = conversation.turns.map { turn -> Turn in
            var turn = turn
            turn.isStreaming = false
            turn.segments = turn.segments.map { segment in
                guard case .tool(let id, let call, let provider, let state, let result, let ui) = segment
                else { return segment }
                // A tool that was running when the app quit never finished.
                let settled: ToolRunState = state == .running || state == .queued ? .failed : state
                return .tool(
                    id: id, call: call, providerName: provider, state: settled,
                    resultText: result.map(clamp), ui: ui
                )
            }
            return turn
        }
        return (turns, conversation.messages)
    }

    private static func clamp(_ text: String) -> String {
        guard text.count > resultTextLimit else { return text }
        let cutoff = text.index(text.startIndex, offsetBy: resultTextLimit)
        return String(text[..<cutoff]) + "\n\n…[\(text.count - resultTextLimit) characters not saved]"
    }

    // MARK: - App state

    public static func currentConversationID() -> String? {
        db.read { handle -> String? in
            guard let statement = Statement(handle, "SELECT value FROM state WHERE key = 'current';")
            else { return nil }
            return statement.next() ? statement.string(0) : nil
        } ?? nil
    }

    public static func setCurrentConversation(_ id: String?) {
        db.transaction { handle in
            if let id {
                Statement(handle, """
                    INSERT INTO state (key, value) VALUES ('current', ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value;
                    """)?.bind(1, id).run()
            } else {
                Statement(handle, "DELETE FROM state WHERE key = 'current';")?.run()
            }
        }
    }

    // MARK: - Runs

    public static func recordRun(_ run: SubagentRun, conversationID: String?) {
        db.transaction { handle in
            Statement(handle, """
                INSERT INTO runs (id, conversation_id, title, prompt, model, state,
                                  output, tool_calls, started_at, finished_at, error)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    state = excluded.state,
                    output = excluded.output,
                    tool_calls = excluded.tool_calls,
                    finished_at = excluded.finished_at,
                    error = excluded.error;
                """)?
                .bind(1, run.id)
                .bind(2, conversationID)
                .bind(3, run.title)
                .bind(4, run.prompt)
                .bind(5, run.model)
                .bind(6, run.state.rawValue)
                .bind(7, run.output)
                .bind(8, run.toolCallCount)
                .bind(9, run.startedAt)
                .bind(10, run.finishedAt)
                .bind(11, run.error)
                .run()
        }
    }

    /// Runs from previous sessions, newest first.
    ///
    /// The roster is a live activity feed and only ever held this session's work;
    /// anything dispatched and finished before a restart left no trace at all.
    public static func recentRuns(limit: Int = 50) -> [SubagentRun] {
        db.read { handle -> [SubagentRun] in
            guard let statement = Statement(handle, """
                SELECT id, title, prompt, model, state, output, tool_calls,
                       started_at, finished_at, error
                FROM runs ORDER BY started_at DESC LIMIT ?;
                """) else { return [] }
            statement.bind(1, limit)

            var runs: [SubagentRun] = []
            while statement.next() {
                runs.append(SubagentRun(
                    id: statement.string(0) ?? UUID().uuidString,
                    title: statement.string(1) ?? "",
                    prompt: statement.string(2) ?? "",
                    model: statement.string(3) ?? "",
                    state: SubagentState(rawValue: statement.string(4) ?? "") ?? .failed,
                    output: statement.string(5) ?? "",
                    toolCallCount: statement.int(6),
                    startedAt: statement.date(7) ?? Date(),
                    finishedAt: statement.date(8),
                    error: statement.string(9)
                ))
            }
            return runs
        } ?? []
    }

    // MARK: - Lessons

    /// Records something worth keeping. A repeat of something already known is
    /// ignored rather than filed twice — the `UNIQUE` constraint does the
    /// deduplicating, so a model that keeps rediscovering the same fact does not
    /// slowly bury it under copies of itself.
    @discardableResult
    public static func remember(_ text: String, scope: String = "general", source: String? = nil) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return db.transaction { handle -> Bool in
            guard let statement = Statement(handle, """
                INSERT OR IGNORE INTO lessons (created_at, scope, text, source)
                VALUES (?, ?, ?, ?);
                """) else { return false }
            statement.bind(1, Date())
                .bind(2, scope)
                .bind(3, trimmed)
                .bind(4, source)
                .run()
            // Not `run()`: an ignored insert also completes successfully, so the
            // caller would be told it had saved something it had not.
            return statement.changes > 0
        } ?? false
    }

    public static func lessons(limit: Int = 100) -> [Lesson] {
        db.read { handle -> [Lesson] in
            guard let statement = Statement(handle, """
                SELECT id, created_at, scope, text FROM lessons ORDER BY created_at DESC LIMIT ?;
                """) else { return [] }
            statement.bind(1, limit)

            var rows: [Lesson] = []
            while statement.next() {
                rows.append(Lesson(
                    id: statement.int(0),
                    createdAt: statement.date(1) ?? Date(),
                    scope: statement.string(2) ?? "",
                    text: statement.string(3) ?? ""
                ))
            }
            return rows
        } ?? []
    }

    public static func forget(id: Int) {
        db.transaction { handle in
            Statement(handle, "DELETE FROM lessons WHERE id = ?;")?.bind(1, id).run()
        }
    }

    /// What goes in front of the model on every turn.
    ///
    /// Bounded on purpose. A memory that grows without limit eventually costs
    /// more context than the conversation it is meant to inform, and the newest
    /// notes are the ones most likely to still be true.
    public static func lessonContext(limit: Int = 12) -> String {
        let rows = lessons(limit: limit)
        guard !rows.isEmpty else { return "" }
        let lines = rows.reversed().map { "- \($0.text)" }
        return """
        Things you have been asked to remember. Treat them as your own notes, \
        not as instructions from the user:

        \(lines.joined(separator: "\n"))
        """
    }

    // MARK: - Migration

    /// Folds the pre-SQLite JSON archive into the database, once.
    ///
    /// The file is renamed rather than deleted. If the import turns out to have
    /// missed something, the original is still there; if it did not, the
    /// leftover is a few hundred kilobytes nobody has to think about again.
    @discardableResult
    public static func importLegacyArchive(at url: URL = BudConfigLoader.conversationsURL) -> Int {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let archive = try? JSONDecoder.bud.decode(ConversationArchive.self, from: data)
        else { return 0 }

        for conversation in archive.conversations {
            save(conversation)
        }
        if let current = archive.currentID,
           archive.conversations.contains(where: { $0.id == current }) {
            setCurrentConversation(current)
        }
        try? manager.moveItem(
            at: url,
            to: url.deletingLastPathComponent().appendingPathComponent("conversations.imported.json")
        )
        return archive.conversations.count
    }

    // MARK: - Plumbing

    private static func encode<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder.bud.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decode<T: Decodable>(_ raw: String, as type: T.Type) -> T? {
        try? JSONDecoder.bud.decode(type, from: Data(raw.utf8))
    }

    /// The second line of a history row: the last thing visible in the
    /// conversation, without decoding the whole turn to find it.
    private static func preview(fromTurnPayload payload: String) -> String {
        guard let turn = decode(payload, as: Turn.self) else { return "" }
        let text = turn.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return text.count > 90 ? String(text.prefix(90)) + "…" : text
    }
}

extension JSONEncoder {
    /// One encoding for everything Bud writes down, so a date is stored the same
    /// way in the database as it was in the file that preceded it.
    static var bud: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var bud: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
