import Foundation
import SQLite3

// MARK: - Value types

/// A canonical, versioned assertion. Superseding a fact marks the previous
/// version inactive rather than silently overwriting it, so history keeps what
/// was believed and when.
public struct Fact: Sendable, Identifiable, Equatable {
    public let id: Int
    public let subject: String
    public let key: String
    public let value: String
    public let scope: String
    public let version: Int
    public let status: String
    public let source: String?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: Int, subject: String, key: String, value: String, scope: String,
        version: Int, status: String, source: String?, createdAt: Date, updatedAt: Date
    ) {
        self.id = id
        self.subject = subject
        self.key = key
        self.value = value
        self.scope = scope
        self.version = version
        self.status = status
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// What happened or was decided; searchable and compactable.
public struct Episode: Sendable, Identifiable, Equatable {
    public let id: Int
    public let summary: String
    public let bodyHandle: String?
    public let scope: String
    public let salience: Double
    public let source: String?
    public let createdAt: Date

    public init(
        id: Int, summary: String, bodyHandle: String?, scope: String,
        salience: Double, source: String?, createdAt: Date
    ) {
        self.id = id
        self.summary = summary
        self.bodyHandle = bodyHandle
        self.scope = scope
        self.salience = salience
        self.source = source
        self.createdAt = createdAt
    }
}

/// A stable node for a project, tool, server, file, person or product.
public struct MemoryEntity: Sendable, Identifiable, Equatable {
    public let id: Int
    public let type: String
    public let canonicalName: String
    public let aliases: [String]
    public let metadata: String?

    public init(id: Int, type: String, canonicalName: String, aliases: [String], metadata: String?) {
        self.id = id
        self.type = type
        self.canonicalName = canonicalName
        self.aliases = aliases
        self.metadata = metadata
    }
}

/// A directed edge such as PROJECT_USES_MCP or SKILL_ALLOWS_TOOL.
public struct MemoryRelation: Sendable, Identifiable, Equatable {
    public let id: Int
    public let fromID: Int
    public let relationType: String
    public let toID: Int
    public let confidence: Double
    public let source: String?

    public init(id: Int, fromID: Int, relationType: String, toID: Int, confidence: Double, source: String?) {
        self.id = id
        self.fromID = fromID
        self.relationType = relationType
        self.toID = toID
        self.confidence = confidence
        self.source = source
    }
}

/// A durable instruction. Written only through this explicit API — never
/// inferred from untrusted web or tool text.
public struct Directive: Sendable, Identifiable, Equatable {
    public let id: Int
    public let text: String
    public let scope: String
    public let authority: String
    public let status: String
    public let source: String?
    public let createdAt: Date

    public init(
        id: Int, text: String, scope: String, authority: String,
        status: String, source: String?, createdAt: Date
    ) {
        self.id = id
        self.text = text
        self.scope = scope
        self.authority = authority
        self.status = status
        self.source = source
        self.createdAt = createdAt
    }
}

/// One row the FTS index returned, with its rank-derived score.
public struct MemoryHit: Sendable, Equatable {
    public let kind: String
    public let refID: Int
    public let text: String
    public let score: Double

    public init(kind: String, refID: Int, text: String, score: Double) {
        self.kind = kind
        self.refID = refID
        self.text = text
        self.score = score
    }
}

// MARK: - Store

/// The cognitive memory layer (§4 of the roadmap): facts with supersession,
/// episodes, entities and bounded graph relations, directives, and an FTS
/// index over the searchable text.
///
/// Additive to the existing `lessons` store, which keeps serving the current
/// prompt path untouched: this layer feeds the shadow ContextMap and the
/// later adaptive-planning phases, and never changes what a request carries.
/// Thread-safe by construction — every call goes through the database's own
/// lock, and nothing throws; a failed write is a lost note, not a lost turn.
public enum CognitiveStore {
    private static var db: BudDatabase { BudDatabase.shared }

    // MARK: - Facts

    /// Records an assertion, superseding the previous active version of the
    /// same `(subject, key, scope)` rather than overwriting it. The FTS index
    /// follows the supersession: the old version's row leaves it, the new
    /// version's enters.
    @discardableResult
    public static func recordFact(
        subject: String,
        key: String = "value",
        value: String,
        scope: String = "general",
        source: String? = nil
    ) -> Fact? {
        let subject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty, !value.isEmpty else { return nil }

        return db.transaction { handle -> Fact? in
            let now = Date()

            var supersededIDs: [Int] = []
            if let prior = Statement(handle, """
                SELECT id FROM facts
                WHERE subject = ? COLLATE NOCASE AND key = ? AND scope = ? AND status = 'active';
                """) {
                prior.bind(1, subject).bind(2, key).bind(3, scope)
                while prior.next() { supersededIDs.append(prior.int(0)) }
            }

            var version = 1
            if let latest = Statement(handle, """
                SELECT COALESCE(MAX(version), 0) FROM facts
                WHERE subject = ? COLLATE NOCASE AND key = ? AND scope = ?;
                """) {
                latest.bind(1, subject).bind(2, key).bind(3, scope)
                if latest.next() { version = latest.int(0) + 1 }
            }

            guard let supersede = Statement(handle, """
                UPDATE facts SET status = 'superseded', updated_at = ?
                WHERE subject = ? COLLATE NOCASE AND key = ? AND scope = ? AND status = 'active';
                """),
                  let insert = Statement(handle, """
                INSERT INTO facts (subject, key, value_json, scope, version, status,
                                   source_id, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, 'active', ?, ?, ?);
                """)
            else { return nil }

            supersede.bind(1, now).bind(2, subject).bind(3, key).bind(4, scope).run()
            insert.bind(1, subject)
                .bind(2, key)
                .bind(3, JSONValue.string(value).encodedString())
                .bind(4, scope)
                .bind(5, version)
                .bind(6, source)
                .bind(7, now)
                .bind(8, now)
                .run()
            guard insert.changes > 0 else { return nil }
            let id = Int(sqlite3_last_insert_rowid(handle))

            for old in supersededIDs {
                Statement(handle, "DELETE FROM memory_fts WHERE kind = 'fact' AND ref_id = ?;")?
                    .bind(1, old).run()
            }
            Statement(handle, """
                INSERT INTO memory_fts (kind, ref_id, searchable_text) VALUES ('fact', ?, ?);
                """)?.bind(1, id).bind(2, "\(subject) \(value)").run()

            return Fact(
                id: id, subject: subject, key: key, value: value, scope: scope,
                version: version, status: "active", source: source,
                createdAt: now, updatedAt: now
            )
        } ?? nil
    }

    /// The standing assertions, newest version only.
    public static func activeFacts(
        subject: String? = nil,
        scope: String? = nil,
        limit: Int = 100
    ) -> [Fact] {
        var sql = "SELECT id, subject, key, value_json, scope, version, status, "
            + "source_id, created_at, updated_at FROM facts WHERE status = 'active'"
        // Case-insensitive: retrieval looks subjects up by lowercased query
        // tokens, and notes remember subjects however they were written.
        if subject != nil { sql += " AND subject = ? COLLATE NOCASE" }
        if scope != nil { sql += " AND scope = ?" }
        sql += " ORDER BY updated_at DESC LIMIT ?;"
        return db.read { handle -> [Fact] in
            guard let statement = Statement(handle, sql) else { return [] }
            var index: Int32 = 1
            if subject != nil { statement.bind(index, subject); index += 1 }
            if scope != nil { statement.bind(index, scope); index += 1 }
            statement.bind(index, limit)

            var rows: [Fact] = []
            while statement.next() { rows.append(fact(from: statement)) }
            return rows
        } ?? []
    }

    /// Every version of an assertion, superseded ones included — the audit
    /// trail of what was believed and when it changed.
    public static func factHistory(subject: String, key: String, scope: String = "general") -> [Fact] {
        db.read { handle -> [Fact] in
            guard let statement = Statement(handle, """
                SELECT id, subject, key, value_json, scope, version, status,
                       source_id, created_at, updated_at
                FROM facts WHERE subject = ? AND key = ? AND scope = ?
                ORDER BY version ASC;
                """) else { return [] }
            statement.bind(1, subject).bind(2, key).bind(3, scope)

            var rows: [Fact] = []
            while statement.next() { rows.append(fact(from: statement)) }
            return rows
        } ?? []
    }

    private static func fact(from statement: Statement) -> Fact {
        Fact(
            id: statement.int(0),
            subject: statement.string(1) ?? "",
            key: statement.string(2) ?? "",
            value: factValue(fromJSON: statement.string(3) ?? ""),
            scope: statement.string(4) ?? "",
            version: statement.int(5),
            status: statement.string(6) ?? "",
            source: statement.string(7),
            createdAt: statement.date(8) ?? Date(),
            updatedAt: statement.date(9) ?? Date()
        )
    }

    /// `value_json` holds `{"value": …}`; a row written some other way still
    /// reads back its raw text rather than failing.
    static func factValue(fromJSON raw: String) -> String {
        guard let parsed = JSONValue(parsing: raw) else { return raw }
        if let object = parsed.objectValue, let inner = object["value"]?.stringValue { return inner }
        return parsed.stringValue ?? raw
    }

    // MARK: - Episodes

    @discardableResult
    public static func recordEpisode(
        summary: String,
        scope: String = "general",
        salience: Double = 0.5,
        bodyHandle: String? = nil,
        source: String? = nil
    ) -> Episode? {
        let summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return nil }
        return db.transaction { handle -> Episode? in
            let now = Date()
            guard let insert = Statement(handle, """
                INSERT INTO episodes (summary, body_handle, scope, salience, source_id, created_at)
                VALUES (?, ?, ?, ?, ?, ?);
                """) else { return nil }
            insert.bind(1, summary)
                .bind(2, bodyHandle)
                .bind(3, scope)
                .bind(4, max(0, min(1, salience)))
                .bind(5, source)
                .bind(6, now)
                .run()
            guard insert.changes > 0 else { return nil }
            let id = Int(sqlite3_last_insert_rowid(handle))
            Statement(handle, """
                INSERT INTO memory_fts (kind, ref_id, searchable_text) VALUES ('episode', ?, ?);
                """)?.bind(1, id).bind(2, summary).run()
            return Episode(
                id: id, summary: summary, bodyHandle: bodyHandle, scope: scope,
                salience: max(0, min(1, salience)), source: source, createdAt: now
            )
        } ?? nil
    }

    public static func episodes(limit: Int = 100) -> [Episode] {
        db.read { handle -> [Episode] in
            guard let statement = Statement(handle, """
                SELECT id, summary, body_handle, scope, salience, source_id, created_at
                FROM episodes ORDER BY created_at DESC LIMIT ?;
                """) else { return [] }
            statement.bind(1, limit)

            var rows: [Episode] = []
            while statement.next() {
                rows.append(Episode(
                    id: statement.int(0),
                    summary: statement.string(1) ?? "",
                    bodyHandle: statement.string(2),
                    scope: statement.string(3) ?? "",
                    salience: statement.double(4),
                    source: statement.string(5),
                    createdAt: statement.date(6) ?? Date()
                ))
            }
            return rows
        } ?? []
    }

    static func episodeSalience(id: Int) -> Double? {
        db.read { handle -> Double? in
            guard let statement = Statement(handle, "SELECT salience FROM episodes WHERE id = ?;")
            else { return nil }
            statement.bind(1, id)
            return statement.next() ? statement.double(0) : nil
        } ?? nil
    }

    /// Removes every row one source produced — the episodes and facts a lesson
    /// became — plus their FTS entries, so a forgotten note is forgotten
    /// everywhere rather than living on in retrieval.
    @discardableResult
    public static func deleteBySource(_ source: String) -> Bool {
        db.transaction { handle -> Bool in
            var removed = false
            for kind in ["episode", "fact"] {
                let table = kind == "episode" ? "episodes" : "facts"
                guard let statement = Statement(handle, """
                    SELECT id FROM \(table) WHERE source_id = ?;
                    """) else { continue }
                statement.bind(1, source)
                var ids: [Int] = []
                while statement.next() { ids.append(statement.int(0)) }
                for id in ids {
                    Statement(handle, "DELETE FROM memory_fts WHERE kind = ? AND ref_id = ?;")?
                        .bind(1, kind).bind(2, id).run()
                    Statement(handle, "DELETE FROM \(table) WHERE id = ?;")?.bind(1, id).run()
                    removed = true
                }
            }
            return removed
        } ?? false
    }

    /// Removes episodes carrying this text that nothing else owns.
    ///
    /// A note's episode is linked by source (`lesson:<id>`), and that link is
    /// what ``deleteBySource(_:)`` follows. An episode written on another path —
    /// a harness, a tool that recorded the sentence directly — carries the same
    /// text with no link, so forgetting the note left it in the table and in
    /// retrieval for ever, with nothing in the interface able to reach it. The
    /// text is the note's own, and `lessons.text` is unique, so a matching
    /// unlinked episode is that note's copy.
    ///
    /// Only unlinked rows are touched: an episode another lesson owns is that
    /// lesson's, and deleting it here would be deleting something the person did
    /// not ask to forget.
    @discardableResult
    public static func deleteUnownedEpisodes(matching text: String) -> Bool {
        let summary = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return false }
        return db.transaction { handle -> Bool in
            guard let statement = Statement(handle, """
                SELECT id FROM episodes
                WHERE summary = ? AND (source_id IS NULL OR source_id NOT LIKE 'lesson:%');
                """) else { return false }
            statement.bind(1, summary)
            var ids: [Int] = []
            while statement.next() { ids.append(statement.int(0)) }
            for id in ids {
                Statement(handle, "DELETE FROM memory_fts WHERE kind = 'episode' AND ref_id = ?;")?
                    .bind(1, id).run()
                Statement(handle, "DELETE FROM episodes WHERE id = ?;")?.bind(1, id).run()
            }
            return !ids.isEmpty
        } ?? false
    }

    /// Records what a connected MCP server is, into the graph the retriever
    /// walks: a server node, a tool node per tool (capped — a 200-tool server
    /// does not become 200 nodes), and the PROJECT_USES_MCP relation from the
    /// standing project node. Idempotent by construction — get-or-create
    /// everywhere — so reconnects and roster rebuilds land on the same nodes.
    public static func recordServerConnection(name: String, tools: [String]) {
        let serverName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !serverName.isEmpty,
              let project = entity(type: "project", name: "bud"),
              let server = entity(type: "server", name: serverName)
        else { return }
        _ = relate(from: project.id, type: "PROJECT_USES_MCP", to: server.id, source: "mcp-connect")
        for tool in tools.prefix(12) {
            let trimmed = tool.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let node = entity(type: "tool", name: trimmed) else { continue }
            _ = relate(from: server.id, type: "SERVER_PROVIDES_TOOL", to: node.id, source: "mcp-connect")
        }
    }

    /// Records an installed skill as a node, so a later query that names it can
    /// walk to what it connects to. Stable on purpose: removal leaves the node.
    @discardableResult
    public static func recordSkill(name: String) -> MemoryEntity? {
        entity(type: "skill", name: name.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Removes a directive: the row and its FTS entry leave, so retrieval never
    /// admits an instruction the person took back.
    public static func deleteDirective(id: Int) {
        db.transaction { handle in
            Statement(handle, "DELETE FROM memory_fts WHERE kind = 'directive' AND ref_id = ?;")?
                .bind(1, id).run()
            Statement(handle, "DELETE FROM directives WHERE id = ?;")?.bind(1, id).run()
        }
    }

    // MARK: - Entities and relations

    /// Get-or-create: the same `(type, canonical_name)` always returns the same
    /// node, so callers can relate freely without tracking ids.
    @discardableResult
    public static func entity(type: String, name: String, metadata: JSONValue? = nil) -> MemoryEntity? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return db.transaction { handle -> MemoryEntity? in
            guard let insert = Statement(handle, """
                INSERT INTO entities (type, canonical_name, metadata_json) VALUES (?, ?, ?)
                ON CONFLICT(type, canonical_name) DO NOTHING;
                """) else { return nil }
            insert.bind(1, type).bind(2, name).bind(3, metadata?.encodedString()).run()
            return readEntity(handle, type: type, name: name)
        } ?? nil
    }

    /// Resolves a canonical name or an alias to its node.
    public static func entity(named name: String) -> MemoryEntity? {
        db.read { handle -> MemoryEntity? in
            if let direct = Statement(handle, """
                SELECT type, canonical_name FROM entities WHERE canonical_name = ?;
                """) {
                direct.bind(1, name)
                if direct.next() {
                    return readEntity(handle, type: direct.string(0) ?? "", name: direct.string(1) ?? "")
                }
            }
            guard let viaAlias = Statement(handle, """
                SELECT e.type, e.canonical_name FROM entity_aliases a
                JOIN entities e ON e.id = a.entity_id WHERE a.alias = ?;
                """) else { return nil }
            viaAlias.bind(1, name)
            guard viaAlias.next() else { return nil }
            return readEntity(handle, type: viaAlias.string(0) ?? "", name: viaAlias.string(1) ?? "")
        } ?? nil
    }

    public static func addAlias(_ alias: String, toEntity entityID: Int) {
        db.transaction { handle in
            Statement(handle, """
                INSERT OR IGNORE INTO entity_aliases (entity_id, alias) VALUES (?, ?);
                """)?.bind(1, entityID).bind(2, alias).run()
        }
    }

    /// A directed edge between two nodes. Duplicates are refused rather than
    /// stacked, so repeated discovery does not pile up the same relation.
    @discardableResult
    public static func relate(
        from: Int, type: String, to: Int,
        confidence: Double = 1.0, source: String? = nil
    ) -> Bool {
        db.transaction { handle -> Bool in
            guard let insert = Statement(handle, """
                INSERT OR IGNORE INTO relations (from_id, relation_type, to_id, confidence, source_id)
                VALUES (?, ?, ?, ?, ?);
                """) else { return false }
            insert.bind(1, from)
                .bind(2, type)
                .bind(3, to)
                .bind(4, max(0, min(1, confidence)))
                .bind(5, source)
                .run()
            return insert.changes > 0
        } ?? false
    }

    /// Bounded breadth-first traversal from one node, depth and node-count
    /// capped so a dense graph cannot turn a lookup into a walk.
    public static func neighbors(of entityID: Int, depth: Int = 2, maxNodes: Int = 16) -> [MemoryEntity] {
        let depth = max(0, depth)
        return db.read { handle -> [MemoryEntity] in
            var visited: Set<Int> = [entityID]
            var frontier: [Int] = [entityID]
            var collected: [Int] = []
            var level = 0
            while level <= depth, !frontier.isEmpty, visited.count < maxNodes {
                var next: [Int] = []
                for node in frontier {
                    guard let statement = Statement(handle, """
                        SELECT to_id FROM relations WHERE from_id = ?;
                        """) else { continue }
                    statement.bind(1, node)
                    while statement.next() {
                        let to = statement.int(0)
                        if visited.insert(to).inserted, visited.count <= maxNodes {
                            next.append(to)
                            collected.append(to)
                        }
                    }
                }
                frontier = next
                level += 1
            }
            return collected.compactMap { entityByID(handle, $0) }
        } ?? []
    }

    private static func entityByID(_ handle: OpaquePointer, _ id: Int) -> MemoryEntity? {
        guard let statement = Statement(handle, """
            SELECT type, canonical_name, metadata_json FROM entities WHERE id = ?;
            """) else { return nil }
        statement.bind(1, id)
        guard statement.next() else { return nil }
        return readEntity(handle, type: statement.string(0) ?? "", name: statement.string(1) ?? "")
    }

    private static func readEntity(_ handle: OpaquePointer, type: String, name: String) -> MemoryEntity? {
        guard let statement = Statement(handle, """
            SELECT id, type, canonical_name, metadata_json FROM entities
            WHERE type = ? AND canonical_name = ?;
            """) else { return nil }
        statement.bind(1, type).bind(2, name)
        guard statement.next() else { return nil }
        let id = statement.int(0)
        var aliases: [String] = []
        if let aliasStatement = Statement(handle, "SELECT alias FROM entity_aliases WHERE entity_id = ?;") {
            aliasStatement.bind(1, id)
            while aliasStatement.next() {
                if let alias = aliasStatement.string(0) { aliases.append(alias) }
            }
        }
        return MemoryEntity(
            id: id, type: statement.string(1) ?? "", canonicalName: statement.string(2) ?? "",
            aliases: aliases, metadata: statement.string(3)
        )
    }

    // MARK: - Directives

    /// Files a durable instruction. Duplicates are refused, matching the
    /// `remember` contract: a repeat is not a new instruction.
    @discardableResult
    public static func recordDirective(
        text: String,
        scope: String = "general",
        authority: String = "user",
        source: String? = nil
    ) -> Directive? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return db.transaction { handle -> Directive? in
            let now = Date()
            guard let insert = Statement(handle, """
                INSERT OR IGNORE INTO directives (text, scope, authority, status, source_id, created_at)
                VALUES (?, ?, ?, 'active', ?, ?);
                """) else { return nil }
            insert.bind(1, text).bind(2, scope).bind(3, authority).bind(4, source).bind(5, now).run()
            guard insert.changes > 0 else { return nil }
            let id = Int(sqlite3_last_insert_rowid(handle))
            Statement(handle, """
                INSERT INTO memory_fts (kind, ref_id, searchable_text) VALUES ('directive', ?, ?);
                """)?.bind(1, id).bind(2, text).run()
            return Directive(
                id: id, text: text, scope: scope, authority: authority,
                status: "active", source: source, createdAt: now
            )
        } ?? nil
    }

    public static func directives(limit: Int = 50) -> [Directive] {
        db.read { handle -> [Directive] in
            guard let statement = Statement(handle, """
                SELECT id, text, scope, authority, status, source_id, created_at
                FROM directives WHERE status = 'active' ORDER BY created_at DESC LIMIT ?;
                """) else { return [] }
            statement.bind(1, limit)

            var rows: [Directive] = []
            while statement.next() {
                rows.append(Directive(
                    id: statement.int(0),
                    text: statement.string(1) ?? "",
                    scope: statement.string(2) ?? "",
                    authority: statement.string(3) ?? "",
                    status: statement.string(4) ?? "",
                    source: statement.string(5),
                    createdAt: statement.date(6) ?? Date()
                ))
            }
            return rows
        } ?? []
    }

    // MARK: - FTS

    /// Lexical retrieval over facts, episodes and directives. Rank-derived:
    /// the best match scores 1.0 and it falls from there.
    public static func search(_ query: String, limit: Int = 12) -> [MemoryHit] {
        let tokens = TextRanking.tokens(in: query).prefix(8)
        guard !tokens.isEmpty else { return [] }
        let match = tokens
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " OR ")
        return db.read { handle -> [MemoryHit] in
            guard let statement = Statement(handle, """
                SELECT kind, ref_id, searchable_text, rank
                FROM memory_fts WHERE memory_fts MATCH ?
                ORDER BY rank LIMIT ?;
                """) else { return [] }
            statement.bind(1, match).bind(2, limit)

            var hits: [MemoryHit] = []
            while statement.next() {
                hits.append(MemoryHit(
                    kind: statement.string(0) ?? "",
                    refID: statement.int(1),
                    text: statement.string(2) ?? "",
                    score: 1.0 / (1.0 + statement.double(3))
                ))
            }
            return hits
        } ?? []
    }

    // MARK: - Context events

    /// One decision the harness made about context, kept for the planner-regret
    /// and recall evals. Pruned to the most recent rows, because an evidence
    /// table that grows for ever is a disk bug that shows up a year later.
    public static func recordContextEvent(
        requestID: String?,
        sourceType: String,
        sourceID: String?,
        action: String,
        score: Double?,
        reason: String?
    ) {
        db.transaction { handle in
            guard let statement = Statement(handle, """
                INSERT INTO context_events (request_id, source_type, source_id, action, score, reason, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?);
                """) else { return }
            statement.bind(1, requestID)
                .bind(2, sourceType)
                .bind(3, sourceID)
                .bind(4, action)
            if let score {
                statement.bind(5, score)
            } else {
                statement.bind(5, nil as String?)
            }
            statement.bind(6, reason)
                .bind(7, Date())
                .run()
            Statement(handle, """
                DELETE FROM context_events WHERE id NOT IN (
                    SELECT id FROM context_events ORDER BY created_at DESC LIMIT 500
                );
                """)?.run()
        }
    }

    public static func contextEventCount() -> Int {
        db.int("SELECT COUNT(*) FROM context_events;")
    }

    /// The reasons of events with `action`, newest first — the raw material
    /// the planner-regret report aggregates over.
    public static func contextEvents(action: String, limit: Int = 200) -> [String] {
        db.read { handle -> [String] in
            guard let statement = Statement(handle, """
                SELECT reason FROM context_events WHERE action = ?
                ORDER BY created_at DESC LIMIT ?;
                """) else { return [] }
            statement.bind(1, action).bind(2, limit)

            var rows: [String] = []
            while statement.next() {
                if let reason = statement.string(0) { rows.append(reason) }
            }
            return rows
        } ?? []
    }
}
