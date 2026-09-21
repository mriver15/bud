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
    public let isPinned: Bool

    public var tokens: Int { promptTokens + completionTokens }

    public init(
        id: String,
        title: String,
        updatedAt: Date,
        turnCount: Int,
        preview: String,
        promptTokens: Int = 0,
        completionTokens: Int = 0,
        isPinned: Bool = false
    ) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.turnCount = turnCount
        self.preview = preview
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.isPinned = isPinned
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
                    (id, title, created_at, updated_at,
                     prompt_tokens, completion_tokens, pinned)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    title = excluded.title,
                    updated_at = excluded.updated_at,
                    prompt_tokens = excluded.prompt_tokens,
                    completion_tokens = excluded.completion_tokens,
                    pinned = excluded.pinned;
                """)
            else { return }
            upsert.bind(1, conversation.id)
                .bind(2, conversation.title)
                .bind(3, conversation.createdAt)
                .bind(4, conversation.updatedAt)
                .bind(5, conversation.promptTokens)
                .bind(6, conversation.completionTokens)
                .bind(7, conversation.isPinned ? 1 : 0)
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

    /// Keeps a conversation at the top of the archive, or lets it fall back into
    /// date order.
    public static func setPinned(_ pinned: Bool, id: String) {
        db.transaction { handle in
            Statement(handle, "UPDATE conversations SET pinned = ? WHERE id = ?;")?
                .bind(1, pinned ? 1 : 0)
                .bind(2, id)
                .run()
        }
    }

    /// Renames a conversation. The title is written as given, and from then on
    /// `save` leaves it alone.
    public static func setTitle(_ title: String, id: String) {
        db.transaction { handle in
            Statement(handle, "UPDATE conversations SET title = ? WHERE id = ?;")?
                .bind(1, title)
                .bind(2, id)
                .run()
        }
    }

    /// The fields a save must preserve — the stored title and creation date —
    /// without decoding the archive's turns and messages. A save that only
    /// needed the title used to load the whole conversation to get it, which
    /// made saving a long chat cost as much as reading it back.
    public static func header(id: String) -> (title: String, createdAt: Date)? {
        db.read { handle -> (title: String, createdAt: Date)? in
            guard let statement = Statement(handle, """
                SELECT title, created_at FROM conversations WHERE id = ?;
                """) else { return nil }
            statement.bind(1, id)
            guard statement.next(), let title = statement.string(0) else { return nil }
            return (title, statement.date(1) ?? Date())
        } ?? nil
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
                       c.prompt_tokens, c.completion_tokens, c.pinned
                FROM conversations c
                ORDER BY c.pinned DESC, c.updated_at DESC
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
                    completionTokens: statement.int(6),
                    isPinned: statement.int(7) != 0
                ))
            }
            return rows
        } ?? []
    }

    public static func delete(id: String) {
        // Foreign keys cascade, so the turns and messages go with it. Runs carry
        // their conversation as a plain column rather than a reference, so they
        // have to be swept here — otherwise a deleted conversation's activity
        // stays in the panel's table with nothing left to explain it.
        deleteRuns(conversationID: id)
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
                       c.prompt_tokens, c.completion_tokens, c.pinned
                FROM conversations c
                WHERE c.title LIKE ?
                   OR EXISTS (SELECT 1 FROM turns t
                              WHERE t.conversation_id = c.id AND t.payload LIKE ?)
                ORDER BY c.pinned DESC, c.updated_at DESC
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
                    completionTokens: statement.int(6),
                    isPinned: statement.int(7) != 0
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
                guard case .tool(let id, let call, let provider, let state, let result, let ui, let app) = segment
                else { return segment }
                // A tool that was running when the app quit never finished.
                let settled: ToolRunState = state == .running || state == .queued ? .failed : state
                return .tool(
                    id: id, call: call, providerName: provider, state: settled,
                    resultText: result.map(clamp), ui: ui, app: app
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

    /// What a run's own text is stored as.
    ///
    /// Runs are the largest thing Bud writes: each keeps its whole final message
    /// and every tool call it made, and a session leaves dozens behind. They are
    /// read at most once — when the panel opens on the conversation they belong
    /// to — so history is stored deflated and inflated on the way back.
    ///
    /// Marked rather than flagged, because rows written before this existed have
    /// to keep reading: anything without the prefix is the text itself. And kept
    /// only when it actually pays: base64 costs a third back, so a short string
    /// is stored as it is.
    enum StoredText {
        static let marker = "zlib:"

        static func pack(_ text: String) -> String {
            guard !text.isEmpty, let data = text.data(using: .utf8) else { return text }
            guard let deflated = try? (data as NSData).compressed(using: .zlib) as Data,
                  deflated.isEmpty == false
            else { return text }
            let encoded = deflated.base64EncodedString()
            guard marker.count + encoded.count < data.count else { return text }
            return marker + encoded
        }

        static func unpack(_ stored: String) -> String {
            guard stored.hasPrefix(marker) else { return stored }
            let encoded = String(stored.dropFirst(marker.count))
            guard let data = Data(base64Encoded: encoded),
                  let inflated = try? (data as NSData).decompressed(using: .zlib) as Data,
                  let text = String(data: inflated, encoding: .utf8)
            else {
                // Unreadable is not the same as empty: handing back what was
                // stored keeps the row visible and the failure obvious, where
                // returning nothing would quietly erase a run from the panel.
                return stored
            }
            return text
        }
    }

    /// How many runs one conversation keeps.
    ///
    /// History is worth having — that is what the panel is for — but not without
    /// bound in a table that is never otherwise emptied. Fifty is more than a
    /// session's work and small enough that the deflated text of a long one stays
    /// a rounding error next to the conversations themselves.
    public static let runHistoryLimit = 50

    public static func recordRun(_ run: SubagentRun, conversationID: String?) {
        let callsJSON = (try? JSONEncoder().encode(run.toolCalls))
            .flatMap { String(data: $0, encoding: .utf8) }
        db.transaction { handle in
            Statement(handle, """
                INSERT INTO runs (id, conversation_id, title, prompt, model, state,
                                  output, tool_calls, tool_calls_json, started_at, finished_at, error)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    state = excluded.state,
                    output = excluded.output,
                    tool_calls = excluded.tool_calls,
                    tool_calls_json = excluded.tool_calls_json,
                    finished_at = excluded.finished_at,
                    error = excluded.error;
                """)?
                .bind(1, run.id)
                .bind(2, conversationID)
                .bind(3, run.title)
                .bind(4, run.prompt)
                .bind(5, run.model)
                .bind(6, run.state.rawValue)
                .bind(7, StoredText.pack(run.output))
                .bind(8, run.toolCallCount)
                .bind(9, callsJSON.map(StoredText.pack))
                .bind(10, run.startedAt)
                .bind(11, run.finishedAt)
                .bind(12, run.error)
                .run()
            pruneRuns(handle, conversationID: conversationID)
        }
    }

    /// Keeps one conversation's history inside its bound, newest kept.
    ///
    /// `IS` rather than `=`, so a run filed before there was a conversation open
    /// is pruned as its own bucket instead of escaping every sweep that compares
    /// against a conversation id.
    private static func pruneRuns(_ handle: OpaquePointer, conversationID: String?) {
        Statement(handle, """
            DELETE FROM runs WHERE conversation_id IS ? AND id NOT IN (
                SELECT id FROM runs WHERE conversation_id IS ? ORDER BY started_at DESC LIMIT ?
            );
            """)?
            .bind(1, conversationID)
            .bind(2, conversationID)
            .bind(3, runHistoryLimit)
            .run()
    }

    /// Runs filed against one conversation, newest first.
    ///
    /// `conversationID` is the panel's whole reason for existing: activity is
    /// about the work in front of you, and a roster that carried every earlier
    /// conversation's runs would be a log rather than a panel. Passing `nil`
    /// asks for all of them, which is what the store's own callers want.
    public static func recentRuns(limit: Int = 50, conversationID: String? = nil) -> [SubagentRun] {
        db.read { handle -> [SubagentRun] in
            let sql = conversationID == nil
                ? """
                    SELECT id, title, prompt, model, state, output, tool_calls,
                           tool_calls_json, started_at, finished_at, error
                    FROM runs ORDER BY started_at DESC LIMIT ?;
                    """
                : """
                    SELECT id, title, prompt, model, state, output, tool_calls,
                           tool_calls_json, started_at, finished_at, error
                    FROM runs WHERE conversation_id IS ? ORDER BY started_at DESC LIMIT ?;
                    """
            guard let statement = Statement(handle, sql) else { return [] }
            if let conversationID { statement.bind(1, conversationID).bind(2, limit) }
            else { statement.bind(1, limit) }

            var runs: [SubagentRun] = []
            while statement.next() {
                let calls: [SubagentToolCall] = statement.string(7)
                    .flatMap(StoredText.unpack)
                    .flatMap { $0.data(using: .utf8) }
                    .flatMap { try? JSONDecoder().decode([SubagentToolCall].self, from: $0) } ?? []
                runs.append(SubagentRun(
                    id: statement.string(0) ?? UUID().uuidString,
                    title: statement.string(1) ?? "",
                    prompt: statement.string(2) ?? "",
                    model: statement.string(3) ?? "",
                    state: SubagentState(rawValue: statement.string(4) ?? "") ?? .failed,
                    output: StoredText.unpack(statement.string(5) ?? ""),
                    toolCallCount: statement.int(6),
                    toolCalls: calls,
                    startedAt: statement.date(8) ?? Date(),
                    finishedAt: statement.date(9),
                    error: statement.string(10)
                ))
            }
            return runs
        } ?? []
    }

    /// Removes runs by id. What "Clear finished" means when it says it, and what
    /// a deleted conversation does to the runs it owned.
    @discardableResult
    public static func deleteRuns(ids: [String]) -> Int {
        guard !ids.isEmpty else { return 0 }
        return db.transaction { handle -> Int in
            var removed = 0
            for id in ids {
                guard let statement = Statement(handle, "DELETE FROM runs WHERE id = ?;") else {
                    continue
                }
                statement.bind(1, id).run()
                removed += statement.changes
            }
            return removed
        } ?? 0
    }

    @discardableResult
    public static func deleteRuns(conversationID: String) -> Int {
        db.transaction { handle -> Int in
            guard let statement = Statement(handle, "DELETE FROM runs WHERE conversation_id = ?;")
            else { return 0 }
            statement.bind(1, conversationID).run()
            return statement.changes
        } ?? 0
    }

    // MARK: - Learned delegation

    /// Files a capability wording against the agent the decision engine placed
    /// it with, replacing whatever that wording meant before.
    ///
    /// Written for a confident answer only — the caller applies the activation
    /// band — because a mapping is permanent: a weak answer filed here becomes
    /// a wrong agent silently run every time the same phrase turns up. The
    /// wording is stored as given, already normalised by the resolver, so two
    /// spellings of one phrase are one row.
    @discardableResult
    public static func rememberDelegateAlias(_ capability: String, agent: String) -> Bool {
        let wording = capability.trimmingCharacters(in: .whitespacesAndNewlines)
        let named = agent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wording.isEmpty, !named.isEmpty else { return false }
        return db.transaction { handle -> Bool in
            guard let statement = Statement(handle, """
                INSERT INTO delegate_aliases (capability, agent, learned_at)
                VALUES (?, ?, ?)
                ON CONFLICT(capability) DO UPDATE SET agent = excluded.agent,
                                                      learned_at = excluded.learned_at;
                """) else { return false }
            statement.bind(1, wording).bind(2, named).bind(3, Date()).run()
            return statement.changes > 0
        } ?? false
    }

    /// Every wording that has been learned, keyed by the wording itself.
    ///
    /// Returned whole rather than filtered by roster: an installed agent can
    /// come back, and a row naming one that is not there is inert — the
    /// resolver only ever looks a mapping up to check it against the roster it
    /// was given.
    public static func delegateAliases() -> [String: String] {
        db.read { handle -> [String: String] in
            guard let statement = Statement(handle, "SELECT capability, agent FROM delegate_aliases;")
            else { return [:] }
            var aliases: [String: String] = [:]
            while statement.next() {
                guard let capability = statement.string(0), let agent = statement.string(1) else {
                    continue
                }
                aliases[capability] = agent
            }
            return aliases
        } ?? [:]
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
        // Read before the row goes: the cleanup below matches on the note's own
        // text, which is the only handle an unlinked copy of it has.
        let text = lessons().first { $0.id == id }?.text
        db.transaction { handle in
            Statement(handle, "DELETE FROM lessons WHERE id = ?;")?.bind(1, id).run()
        }
        // The cognitive layer keeps its own copy of the same note; forgetting
        // the lesson forgets both, or retrieval would keep surfacing a note
        // the person deleted.
        CognitiveStore.deleteBySource("lesson:\(id)")
        if let text { CognitiveStore.deleteUnownedEpisodes(matching: text) }
    }

    /// Rewrites a note in place, keeping its id.
    ///
    /// The id is the point: a note's cognitive copies are filed under
    /// `lesson:<id>`, and an edited note that became a new row would leave those
    /// copies describing something that no longer exists. Returns false when no
    /// row matched — including when another note already holds the new text,
    /// which `lessons.text` is unique against.
    @discardableResult
    public static func rewrite(id: Int, text: String, scope: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return db.transaction { handle -> Bool in
            guard let statement = Statement(handle, "UPDATE lessons SET text = ?, scope = ? WHERE id = ?;")
            else { return false }
            statement.bind(1, trimmed).bind(2, scope).bind(3, id).run()
            return statement.changes > 0
        } ?? false
    }

    /// How many notes the block in front of the model may carry.
    ///
    /// A memory block is re-sent on every request, in every conversation, for as
    /// long as the app runs — unlike the conversation, which grows because
    /// someone is talking. Twelve is what the block cost before it ranked
    /// anything, and it stays the ceiling; what fills it is now decided by the
    /// conversation rather than by age alone.
    public static let lessonContextLimit = 12

    /// How many notes are read in order to rank them.
    ///
    /// Ranking needs a pool, and the pool needs its own bound, because the table
    /// is written by a model and nothing stops it writing on every turn. Two
    /// hundred, from the measurement rather than from symmetry: ranking costs
    /// roughly 0.009 ms a note in a release build — 4.2 ms over five hundred and
    /// 1.8 ms over two hundred — and it is paid on every request. Two hundred is
    /// more than anyone accumulates before the oldest of them is months old, which
    /// is as far back as relevance reaches anyway.
    static let lessonRankPool = 200

    /// How many of the ranked notes get their whole text.
    ///
    /// Four, for the same reason `SkillRanking.promote` is three: enough for a
    /// turn that genuinely spans a couple of subjects, not so many that the tail
    /// of incidental overlap is spelled out in full.
    static let lessonPromote = 4

    /// How close to the best match a note has to be to get its whole text, as a
    /// fraction of the top score. Half, as in `SkillRanking`.
    static let lessonRelevanceFloor = 0.5

    /// The most of a note that a shortened line keeps. Such a line is there to
    /// say the note exists and roughly what it is about, which is what the model
    /// needs in order to reach for `recall`; past about a sentence it costs what
    /// the whole text costs and saves nothing.
    static let lessonCompactChars = 140

    /// How many characters the memory block may carry.
    ///
    /// The block rides on every request, in every conversation, for as long as
    /// the app runs, and a memory that grows forever must not grow with it. A
    /// note count bounds the block only while the notes are short — twelve
    /// five-hundred-character notes are the whole conversation's worth of context
    /// charged as twelve lines — so the characters are the bound that actually
    /// caps the cost. Three thousand is about a page of prompt: room for the
    /// person's standing notes and the few the conversation is about in full,
    /// plus a long tail of one-line reminders, and it keeps the block smaller
    /// than the turn it is there to inform. Whatever it leaves out stays
    /// reachable through `recall`, which reads the whole table.
    static let memoryContextBudget = 3_000

    /// What goes in front of the model on every turn.
    ///
    /// Bounded on purpose, and now bounded by relevance rather than only by age.
    /// The newest twelve notes are not the twelve most useful ones: a note about
    /// how someone wants commits written is worth more during a commit than
    /// whatever was recorded most recently, and a plain recency cut buried it
    /// under trivia. Two bounds apply: at most `lessonContextLimit` notes, and at
    /// most `memoryContextBudget` characters — the count because it is re-sent on
    /// every request for as long as the app runs, and the characters because a
    /// memory that grows with the table ends up costing more than the
    /// conversation it is there to inform. A note left out is counted in the
    /// block, not silently dropped.
    ///
    /// Ranked, never filtered — the argument `SkillRanking` makes at length, and
    /// this is the same shape of problem. Term matching scores nothing for a note
    /// reading "Prefers answers without preamble" against a message asking for a
    /// shorter reply: the words differ, the subject does not, and only the model
    /// knows that. So a note that scores nothing is not dropped; it is listed on
    /// one shortened line, and `recall` reads any of them whole.
    ///
    /// - Parameter conversation: the recent turns, which is where the subject of
    ///   a conversation lives. Pass nothing and the ranking has nothing to go on,
    ///   which is what the callers that are measuring rather than talking want.
    public static func lessonContext(
        _ conversation: String = "",
        limit: Int = lessonContextLimit
    ) -> String {
        guard limit > 0 else { return "" }
        let rows = lessons(limit: lessonRankPool)
        guard !rows.isEmpty else { return "" }

        // Who they are comes first and in full. Scope has already decided that
        // these are the notes that matter everywhere rather than here, and a
        // colleague does not forget what someone cares about between sentences.
        // They are admitted before anything is ranked, so the bound below falls on
        // the notes that grow rather than on the ones that describe a person —
        // and if a person ever needed more than twelve to be described, the newest
        // are the ones kept, exactly as for the rest.
        let standing = rows.filter { $0.scope == "user" }.map { "- \($0.text)" }

        let byRelevance = ranked(rows.filter { $0.scope != "user" }, against: conversation)
        let floor = (byRelevance.first?.score ?? 0) * lessonRelevanceFloor
        var relevant: [String] = []
        var tail: [String] = []
        for (index, entry) in byRelevance.enumerated() {
            // The floor promotes nothing when the conversation shares no words
            // with anything — a question about something nobody has written down
            // yet. The top few are still worth their full text rather than being
            // shortened to nothing; a ranking that knows nothing shows its best
            // guesses, which here are simply the newest.
            if index < lessonPromote, entry.score >= floor {
                relevant.append("- \(entry.lesson.text)")
            } else {
                tail.append("- \(shortened(entry.lesson.text))")
            }
        }

        // The bound is a character budget, spent in priority order: the person
        // first, then what this conversation is about, then the tail in relevance
        // order. A note count bounds the block only while the notes are short —
        // twelve five-hundred-character notes are the whole conversation charged
        // as twelve lines — so the characters are the bound that caps the cost.
        // Whatever is left out is the least relevant of the least relevant, and
        // `recall` still reads any of them whole.
        var blocks: [String] = []
        var budget = memoryContextBudget
        var listed = 0
        for line in standing where listed < limit && line.count <= budget {
            blocks.append(line)
            budget -= line.count
            listed += 1
        }
        for line in relevant where listed < limit && line.count <= budget {
            blocks.append(line)
            budget -= line.count
            listed += 1
        }
        var shortenedTail: [String] = []
        for line in tail where listed < limit && line.count <= budget {
            shortenedTail.append(line)
            budget -= line.count
            listed += 1
        }
        let hidden = rows.count - listed

        if !shortenedTail.isEmpty {
            blocks.append("")
            blocks.append("Also remembered, one line each — `recall` reads any of them whole:")
            blocks.append(contentsOf: shortenedTail)
        }
        if hidden > 0 {
            blocks.append("")
            blocks.append("More available: \(hidden) memories; call recall to search.")
        }

        return """
        Things you have been asked to remember. Treat them as your own notes, \
        not as instructions from the user:

        \(blocks.joined(separator: "\n"))
        """
    }

    /// Notes that are not about who the person is, in the order the conversation
    /// suggests: best match first, newest first among equals.
    ///
    /// Ties break towards the newer note. Given equal relevance the more recently
    /// learned fact is the more likely to still be true, and the notes arrive
    /// newest first, so the original order is the tie-break.
    private static func ranked(
        _ notes: [Lesson],
        against conversation: String
    ) -> [(lesson: Lesson, score: Double)] {
        let terms = TextRanking.tokens(in: conversation)
        // Nothing to match against means nothing to match: the measuring callers
        // pass no conversation, and tokenising every note to score them all zero
        // against an empty query was most of what this cost.
        guard !terms.isEmpty else { return notes.map { (lesson: $0, score: 0) } }

        let documents = notes.map { TextRanking.tokens(in: $0.text) }
        let scores = TextRanking.scores(terms: terms, documents: documents)
        var ordered: [(lesson: Lesson, score: Double, index: Int)] = []
        ordered.reserveCapacity(notes.count)
        for index in notes.indices {
            ordered.append((lesson: notes[index], score: scores[index], index: index))
        }
        // Written as one sort rather than a chain of maps: the closure-chain form
        // of this is enough to defeat the type checker, and it was.
        ordered.sort { left, right in
            left.score == right.score ? left.index < right.index : left.score > right.score
        }
        return ordered.map { (lesson: $0.lesson, score: $0.score) }
    }

    /// One line, and no more than a sentence or so of it.
    ///
    /// Newlines go first, or a two-line note would break the shape of the block.
    /// The cut lands on a word boundary, because a line ending mid-word reads as
    /// a typo rather than as a truncation.
    private static func shortened(_ text: String) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
        guard flat.count > lessonCompactChars else { return flat }
        let cut = flat.index(flat.startIndex, offsetBy: lessonCompactChars)
        let head = flat[..<cut]
        guard let space = head.lastIndex(of: " ") else { return head + "…" }
        return head[..<space] + "…"
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
