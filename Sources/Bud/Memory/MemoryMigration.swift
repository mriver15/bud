import Foundation
import SQLite3

/// The cognitive schema and its one-time fold of the existing `lessons` table
/// into it (§4 of the roadmap).
///
/// Run from `BudDatabase.migrate()` when the schema version bumps, and
/// idempotent on purpose: a lesson already imported — recognised by its
/// `lesson:<id>` source — is not imported again, so the step can be re-run
/// against a database where it has already happened.
///
/// Promotion is deliberately conservative. Only `user`/`project` notes that
/// read as an unambiguous one-line assertion (`subject: value`, subject a
/// single word) become facts; everything else becomes an episode. No graph is
/// inferred during migration — relations are recorded later, by what actually
/// happens, not guessed from prose.
public enum MemoryMigration {
    @discardableResult
    public static func migrate(_ handle: OpaquePointer) -> (episodes: Int, facts: Int) {
        exec(handle, """
        CREATE TABLE IF NOT EXISTS facts (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            subject     TEXT NOT NULL,
            key         TEXT NOT NULL,
            value_json  TEXT NOT NULL,
            scope       TEXT NOT NULL DEFAULT 'general',
            version     INTEGER NOT NULL DEFAULT 1,
            status      TEXT NOT NULL DEFAULT 'active',
            source_id   TEXT,
            created_at  REAL NOT NULL,
            updated_at  REAL NOT NULL
        );

        -- One active version per assertion. Superseding a fact marks the old
        -- row inactive rather than deleting it, so history keeps what was
        -- believed and when.
        CREATE UNIQUE INDEX IF NOT EXISTS facts_one_active_per_key
            ON facts(subject, key, scope) WHERE status = 'active';
        CREATE INDEX IF NOT EXISTS facts_by_subject ON facts(subject);

        -- What happened or was decided; searchable and compactable.
        CREATE TABLE IF NOT EXISTS episodes (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            summary     TEXT NOT NULL,
            body_handle TEXT,
            scope       TEXT NOT NULL DEFAULT 'general',
            salience    REAL NOT NULL DEFAULT 0.5,
            source_id   TEXT,
            created_at  REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS episodes_by_recency ON episodes(created_at DESC);

        -- Stable nodes for projects, tools, servers, files, people.
        CREATE TABLE IF NOT EXISTS entities (
            id             INTEGER PRIMARY KEY AUTOINCREMENT,
            type           TEXT NOT NULL,
            canonical_name TEXT NOT NULL,
            metadata_json  TEXT,
            UNIQUE(type, canonical_name)
        );
        CREATE TABLE IF NOT EXISTS entity_aliases (
            entity_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
            alias     TEXT NOT NULL,
            PRIMARY KEY (entity_id, alias)
        );

        -- Directed edges between entities, e.g. PROJECT_USES_MCP.
        CREATE TABLE IF NOT EXISTS relations (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            from_id       INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
            relation_type TEXT NOT NULL,
            to_id         INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
            confidence    REAL NOT NULL DEFAULT 1.0,
            source_id     TEXT,
            UNIQUE(from_id, relation_type, to_id)
        );
        CREATE INDEX IF NOT EXISTS relations_by_from ON relations(from_id);
        CREATE INDEX IF NOT EXISTS relations_by_to ON relations(to_id);

        -- Durable instructions. Written only through explicit API calls, never
        -- inferred from web or tool text.
        CREATE TABLE IF NOT EXISTS directives (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            text        TEXT NOT NULL,
            scope       TEXT NOT NULL DEFAULT 'general',
            authority   TEXT NOT NULL DEFAULT 'user',
            status      TEXT NOT NULL DEFAULT 'active',
            source_id   TEXT,
            created_at  REAL NOT NULL,
            UNIQUE(text)
        );

        -- Lexical retrieval over facts, episodes and directives.
        CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(
            kind, ref_id UNINDEXED, searchable_text
        );

        -- What each request considered, for the planner-regret and recall evals.
        CREATE TABLE IF NOT EXISTS context_events (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            request_id  TEXT,
            source_type TEXT NOT NULL,
            source_id   TEXT,
            action      TEXT NOT NULL,
            score       REAL,
            reason      TEXT,
            created_at  REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS context_events_by_recency
            ON context_events(created_at DESC);
        """)

        // Everything remembered stays reachable: every lesson becomes an
        // episode, and the unambiguous one-line assertions also become facts.
        sqlite3_exec(
            handle, """
            INSERT INTO episodes (summary, scope, salience, source_id, created_at)
            SELECT l.text, l.scope, 0.5, 'lesson:' || l.id, l.created_at
            FROM lessons l
            WHERE NOT EXISTS (
                SELECT 1 FROM episodes e WHERE e.source_id = 'lesson:' || l.id
            );
            """, nil, nil, nil
        )
        let episodes = sqlite3_changes(handle)

        sqlite3_exec(
            handle, """
            INSERT INTO facts (subject, key, value_json, scope, version, status,
                               source_id, created_at, updated_at)
            SELECT
                trim(substr(l.text, 1, instr(l.text, ':') - 1)),
                'value',
                json_object('value', trim(substr(l.text, instr(l.text, ':') + 1))),
                l.scope,
                1,
                'active',
                'lesson:' || l.id,
                l.created_at,
                l.created_at
            FROM lessons l
            WHERE l.scope IN ('user', 'project')
              AND instr(l.text, ':') > 1
              AND instr(substr(l.text, 1, instr(l.text, ':') - 1), ' ') = 0
              AND length(substr(l.text, 1, instr(l.text, ':') - 1)) <= 60
              AND length(trim(substr(l.text, instr(l.text, ':') + 1))) > 0
              AND length(trim(substr(l.text, instr(l.text, ':') + 1))) <= 200
              AND NOT EXISTS (
                  SELECT 1 FROM facts f WHERE f.source_id = 'lesson:' || l.id
              );
            """, nil, nil, nil
        )
        let facts = sqlite3_changes(handle)

        // The migrated text enters the FTS index too, so retrieval covers
        // what existed before the rework exactly as it covers what came after.
        sqlite3_exec(
            handle, """
            INSERT INTO memory_fts (kind, ref_id, searchable_text)
            SELECT 'episode', e.id, e.summary
            FROM episodes e
            WHERE e.source_id LIKE 'lesson:%'
              AND NOT EXISTS (
                  SELECT 1 FROM memory_fts f
                  WHERE f.kind = 'episode' AND f.ref_id = e.id
              );
            """, nil, nil, nil
        )
        sqlite3_exec(
            handle, """
            INSERT INTO memory_fts (kind, ref_id, searchable_text)
            SELECT 'fact', f.id, f.subject || ' ' || f.value_json
            FROM facts f
            WHERE f.source_id LIKE 'lesson:%'
              AND NOT EXISTS (
                  SELECT 1 FROM memory_fts m
                  WHERE m.kind = 'fact' AND m.ref_id = f.id
              );
            """, nil, nil, nil
        )

        return (episodes: Int(episodes), facts: Int(facts))
    }

    private static func exec(_ handle: OpaquePointer, _ sql: String) -> Bool {
        sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK
    }
}
