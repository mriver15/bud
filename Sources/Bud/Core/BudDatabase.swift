import Foundation
import SQLite3

/// The SQLite connection Bud keeps its history in.
///
/// Replaces a single JSON file that was rewritten whole on every save. The
/// archive had stopped being a document: a conversation is appended to, not
/// reissued, and the cost of writing one turn was growing with the total number
/// of turns the user had ever taken. It also had nowhere to put things that are
/// not conversations — a subagent run, or a note worth keeping between sessions —
/// short of inventing more top-level keys.
///
/// One connection, serialised behind a lock. SQLite in WAL mode would tolerate
/// concurrent writers, but the callers here are a main-actor model and a
/// background pool, and a single writer removes an entire class of question
/// about which of them saw what.
public final class BudDatabase: @unchecked Sendable {
    /// The connection the app uses.
    ///
    /// Settable so a test can point the store at a database of its own rather
    /// than at the history the person running it actually has. Without it, any
    /// test that touched the store would quietly write into the real archive —
    /// and would then be asserting against whatever it had left there last run.
    ///
    /// `nonisolated(unsafe)` because it is genuinely shared mutable state and the
    /// compiler is right to object. It is written exactly once, by the suite,
    /// before any of it runs, and read by everything after.
    nonisolated(unsafe) public static var shared = BudDatabase()

    private let lock = NSLock()
    private var handle: OpaquePointer?

    /// Bumped when the schema changes. `user_version` is SQLite's own slot for
    /// this, which is better than a table of our own: it cannot be dropped by a
    /// stray query and it is read without preparing a statement.
    public static let schemaVersion = 5

    public static var defaultURL: URL {
        BudConfigLoader.budDirectory.appendingPathComponent("bud.sqlite")
    }

    public init(url: URL = BudDatabase.defaultURL) {
        BudConfigLoader.createOwnerOnlyDirectory(url.deletingLastPathComponent())
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            sqlite3_close_v2(handle)
            return
        }
        self.handle = handle
        BudConfigLoader.restrictToOwner(url)
        // Wait rather than fail. A reader holding the file for a moment is not a
        // reason to lose a turn.
        sqlite3_busy_timeout(handle, 5_000)
        exec("PRAGMA journal_mode = WAL;")
        exec("PRAGMA foreign_keys = ON;")
        exec("PRAGMA synchronous = NORMAL;")
        migrate()
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    /// True when the file could be opened and the schema is in place.
    ///
    /// Callers check this rather than assuming: running without persistence is a
    /// degraded app, not a broken one, and it should not take the transcript down
    /// with it.
    public var isOpen: Bool { lock.withLock { handle != nil } }

    // MARK: - Schema

    /// Copies the database aside before the schema changes.
    ///
    /// `VACUUM INTO` rather than a file copy. A database in WAL mode is its main
    /// file *plus* the write-ahead log, and copying only the first loses every
    /// transaction that has not been checkpointed — which is all of the recent
    /// ones. This is the one operation that rewrites data nobody can regenerate,
    /// so it is the one place worth paying for a snapshot.
    private func backUpBeforeMigrating(from version: Int) {
        let destination = BudConfigLoader.budDirectory
            .appendingPathComponent("bud.sqlite.backup-v\(version)")
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        _ = exec("VACUUM INTO '\(destination.path)';")
        // Same permissions as the database it copies. A backup of a private
        // conversation is not less private for being a backup.
        BudConfigLoader.restrictToOwner(destination)
    }

    /// Adds a column when the table does not already have it.
    private func addColumnIfMissing(_ name: String, in table: String, definition: String) {
        let existing = read { handle -> Set<String> in
            guard let statement = Statement(handle, "PRAGMA table_info(\(table));") else { return [] }
            var names: Set<String> = []
            while statement.next() { names.insert(statement.string(1) ?? "") }
            return names
        } ?? []
        guard !existing.contains(name) else { return }
        exec("ALTER TABLE \(table) ADD COLUMN \(name) \(definition);")
    }

    private func migrate() {
        let current = int("PRAGMA user_version;")
        guard current < Self.schemaVersion else { return }
        // Before anything is rewritten. A database that has a version is one
        // somebody has been using.
        if current > 0 { backUpBeforeMigrating(from: current) }
        exec("""
        CREATE TABLE IF NOT EXISTS conversations (
            id          TEXT PRIMARY KEY,
            title       TEXT NOT NULL,
            created_at  REAL NOT NULL,
            updated_at  REAL NOT NULL,
            provider    TEXT,
            model       TEXT,
            -- v2. What this conversation has cost so far, so reopening it shows
            -- the same figure it showed when it was closed.
            prompt_tokens     INTEGER NOT NULL DEFAULT 0,
            completion_tokens INTEGER NOT NULL DEFAULT 0,
            -- v3. Pinned conversations sort above the rest, which is the only
            -- thing that makes an archive of a hundred usable.
            pinned      INTEGER NOT NULL DEFAULT 0
        );

        -- One row per visible turn. The turn is stored as its own JSON rather
        -- than shredded into a segment table: segments are a rendering detail
        -- whose shape changes with the UI, and normalising them would mean a
        -- migration every time the transcript learns to show something new.
        CREATE TABLE IF NOT EXISTS turns (
            conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            ordinal         INTEGER NOT NULL,
            id              TEXT NOT NULL,
            role            TEXT NOT NULL,
            payload         TEXT NOT NULL,
            created_at      REAL NOT NULL,
            PRIMARY KEY (conversation_id, ordinal)
        );

        -- The model-facing half. Stored separately because it is not derivable
        -- from the turns: it carries tool calls and results in wire order.
        CREATE TABLE IF NOT EXISTS messages (
            conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            ordinal         INTEGER NOT NULL,
            role            TEXT NOT NULL,
            payload         TEXT NOT NULL,
            PRIMARY KEY (conversation_id, ordinal)
        );

        CREATE INDEX IF NOT EXISTS conversations_by_recency
            ON conversations(updated_at DESC);

        -- Subagent runs, which lived only in memory and vanished on quit.
        CREATE TABLE IF NOT EXISTS runs (
            id              TEXT PRIMARY KEY,
            conversation_id TEXT,
            title           TEXT NOT NULL,
            prompt          TEXT NOT NULL,
            model           TEXT NOT NULL,
            state           TEXT NOT NULL,
            output          TEXT NOT NULL DEFAULT '',
            tool_calls      INTEGER NOT NULL DEFAULT 0,
            started_at      REAL NOT NULL,
            finished_at     REAL,
            error           TEXT
        );

        CREATE INDEX IF NOT EXISTS runs_by_recency ON runs(started_at DESC);

        -- Things worth carrying between conversations.
        CREATE TABLE IF NOT EXISTS lessons (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at  REAL NOT NULL,
            scope       TEXT NOT NULL,
            text        TEXT NOT NULL,
            source      TEXT,
            UNIQUE(text)
        );

        CREATE INDEX IF NOT EXISTS lessons_by_recency ON lessons(created_at DESC);

        -- Small scalars that belong to the app rather than to a conversation,
        -- such as which conversation was open.
        CREATE TABLE IF NOT EXISTS state (
            key   TEXT PRIMARY KEY,
            value TEXT
        );
        """)
        // Both paths reach here: a database created just now has these columns
        // from the statement above, an older one does not. Checking the table
        // rather than the version means running this twice is harmless.
        addColumnIfMissing("prompt_tokens", in: "conversations", definition: "INTEGER NOT NULL DEFAULT 0")
        addColumnIfMissing("completion_tokens", in: "conversations", definition: "INTEGER NOT NULL DEFAULT 0")
        addColumnIfMissing("pinned", in: "conversations", definition: "INTEGER NOT NULL DEFAULT 0")
        // v5: the per-call tool record, a JSON array beside the count. NULL
        // reads as no calls, so rows from before the column exist unchanged.
        addColumnIfMissing("tool_calls_json", in: "runs", definition: "TEXT")

        // v4: the cognitive memory schema, plus the one-time fold of the
        // existing `lessons` table into it. One lock around the whole step so a
        // concurrent read never sees the tables half-created.
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return }
        _ = MemoryMigration.migrate(handle)
        sqlite3_exec(handle, "PRAGMA user_version = \(Self.schemaVersion);", nil, nil, nil)
    }

    // MARK: - Statements

    /// Runs a statement with no results. Returns false on error.
    @discardableResult
    func exec(_ sql: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return false }
        return sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK
    }

    func int(_ sql: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return 0 }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// Serialises a unit of work. Everything a caller does inside one closure sees
    /// a consistent database, and nothing else runs concurrently with it.
    @discardableResult
    func transaction<T>(_ body: (OpaquePointer) throws -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return nil }
        sqlite3_exec(handle, "BEGIN IMMEDIATE;", nil, nil, nil)
        do {
            let result = try body(handle)
            sqlite3_exec(handle, "COMMIT;", nil, nil, nil)
            return result
        } catch {
            sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
            return nil
        }
    }

    /// Reads. Separate from `transaction` only in intent — SQLite has no need to
    /// know the difference, but a reader that opened a write transaction would
    /// serialise the entire app behind it.
    func read<T>(_ body: (OpaquePointer) throws -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return nil }
        return try? body(handle)
    }
}

/// A prepared statement, finalised when it goes out of scope.
///
/// Exists so no call site has to remember `sqlite3_finalize`, which leaks a
/// prepared statement and, after enough turns, the whole connection's memory.
final class Statement {
    private let handle: OpaquePointer
    /// Kept so `changes` can be read. `sqlite3_changes` reports on the
    /// connection, not the statement, and calling back into `BudDatabase` for it
    /// would deadlock on a lock the caller already holds.
    private let database: OpaquePointer

    /// The destructor that tells SQLite to copy the bound bytes rather than hold
    /// the pointer. Swift strings do not outlive the call that produced them, so
    /// the alternative is a use-after-free that only shows up under load.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init?(_ db: OpaquePointer, _ sql: String) {
        var handle: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &handle, nil) == SQLITE_OK, let handle else {
            return nil
        }
        self.handle = handle
        self.database = db
    }

    deinit { sqlite3_finalize(handle) }

    @discardableResult
    func bind(_ index: Int32, _ value: String?) -> Statement {
        if let value {
            sqlite3_bind_text(handle, index, value, -1, Self.transient)
        } else {
            sqlite3_bind_null(handle, index)
        }
        return self
    }

    @discardableResult
    func bind(_ index: Int32, _ value: Int) -> Statement {
        sqlite3_bind_int64(handle, index, Int64(value))
        return self
    }

    @discardableResult
    func bind(_ index: Int32, _ value: Double) -> Statement {
        sqlite3_bind_double(handle, index, value)
        return self
    }

    @discardableResult
    func bind(_ index: Int32, _ value: Date?) -> Statement {
        // Bound by hand rather than by mapping to a Double and forwarding: that
        // produces a `Double?`, which matches none of the overloads and sends
        // the type checker somewhere unhelpful.
        if let value {
            sqlite3_bind_double(handle, index, value.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(handle, index)
        }
        return self
    }

    /// Rows the last `run()` changed. Read before the reset that follows it,
    /// because that is the only moment the count is about this statement.
    private(set) var lastChangeCount = 0

    /// Runs to completion. True when it executed without error.
    ///
    /// Reset and cleared afterwards, not before. A prepared statement that has
    /// already stepped to `SQLITE_DONE` will not run again until it is reset, and
    /// without this every execution after the first silently did nothing — which
    /// is how only the first turn of a conversation was ever stored, and why it
    /// went unnoticed: every conversation saved until then had exactly one turn.
    @discardableResult
    func run() -> Bool {
        let ok = sqlite3_step(handle) == SQLITE_DONE
        lastChangeCount = Int(sqlite3_changes(database))
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
        return ok
    }

    /// Steps once and reads a row, or nil when there are no more.
    func next() -> Bool {
        sqlite3_step(handle) == SQLITE_ROW
    }

    func string(_ column: Int32) -> String? {
        guard let raw = sqlite3_column_text(handle, column) else { return nil }
        return String(cString: raw)
    }

    /// Rows the last statement actually changed.
    ///
    /// The only way to tell an insert from a skipped one: `INSERT OR IGNORE`
    /// steps to `SQLITE_DONE` whether it wrote a row or declined to, so the
    /// step result says nothing about whether anything happened.
    var changes: Int { lastChangeCount }

    func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(handle, column)) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(handle, column) }
    func date(_ column: Int32) -> Date? {
        guard sqlite3_column_type(handle, column) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(handle, column))
    }
}
