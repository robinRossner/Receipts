import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum DatabaseError: Error, CustomStringConvertible {
    case openFailed(String)
    case prepareFailed(String, String)
    case stepFailed(String, String)

    var description: String {
        switch self {
        case .openFailed(let msg): return "Could not open database: \(msg)"
        case .prepareFailed(let msg, let sql): return "Could not prepare '\(sql)': \(msg)"
        case .stepFailed(let msg, let sql): return "Could not execute '\(sql)': \(msg)"
        }
    }
}

/// One value bound into or read out of a SQLite column.
enum SQLiteValue {
    case integer(Int64)
    case real(Double)
    case text(String)
    case null

    static func from(_ v: Int) -> SQLiteValue { .integer(Int64(v)) }
    static func from(_ v: Int?) -> SQLiteValue { v.map { .integer(Int64($0)) } ?? .null }
    static func from(_ v: Double?) -> SQLiteValue { v.map { .real($0) } ?? .null }
    static func from(_ v: Double) -> SQLiteValue { .real(v) }
    static func from(_ v: String?) -> SQLiteValue { v.map { .text($0) } ?? .null }
    static func from(_ v: Bool) -> SQLiteValue { .integer(v ? 1 : 0) }
}

/// One result row, accessed positionally (mirrors the `keys = [...]; dict(zip(keys, row))`
/// pattern used throughout the original Python code).
struct SQLRow {
    let values: [SQLiteValue]

    func isNull(_ i: Int) -> Bool { if case .null = values[i] { return true }; return false }

    func int(_ i: Int) -> Int? {
        switch values[i] {
        case .integer(let v): return Int(v)
        case .real(let v): return Int(v)
        default: return nil
        }
    }
    func double(_ i: Int) -> Double? {
        switch values[i] {
        case .real(let v): return v
        case .integer(let v): return Double(v)
        default: return nil
        }
    }
    func string(_ i: Int) -> String? {
        if case .text(let v) = values[i] { return v }
        return nil
    }
    func bool(_ i: Int) -> Bool { (int(i) ?? 0) != 0 }
}

/// Synchronous statement runner over a raw `sqlite3*`. Used by the actor's async `run`/`query`,
/// by migrations, and inside `Database.transaction` - the body of a transaction must not
/// suspend (an actor can interleave other callers at every `await`, and their statements would
/// land inside the open transaction), so it gets this synchronous handle instead of `await`.
struct SQLConnection {
    let handle: OpaquePointer?

    @discardableResult
    func run(_ sql: String, _ params: [SQLiteValue] = []) throws -> Int64 {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(handle)), sql)
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(handle)), sql)
        }
        return sqlite3_last_insert_rowid(handle)
    }

    func query(_ sql: String, _ params: [SQLiteValue] = []) throws -> [SQLRow] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(handle)), sql)
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params)

        var rows: [SQLRow] = []
        loop: while true {
            let rc = sqlite3_step(stmt)
            switch rc {
            case SQLITE_ROW:
                let columnCount = sqlite3_column_count(stmt)
                var values: [SQLiteValue] = []
                values.reserveCapacity(Int(columnCount))
                for i in 0..<columnCount {
                    switch sqlite3_column_type(stmt, i) {
                    case SQLITE_INTEGER:
                        values.append(.integer(sqlite3_column_int64(stmt, i)))
                    case SQLITE_FLOAT:
                        values.append(.real(sqlite3_column_double(stmt, i)))
                    case SQLITE_TEXT:
                        if let cstr = sqlite3_column_text(stmt, i) {
                            values.append(.text(String(cString: cstr)))
                        } else {
                            values.append(.null)
                        }
                    default:
                        values.append(.null)
                    }
                }
                rows.append(SQLRow(values: values))
            case SQLITE_DONE:
                break loop
            default:
                throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(handle)), sql)
            }
        }
        return rows
    }

    func queryOne(_ sql: String, _ params: [SQLiteValue] = []) throws -> SQLRow? {
        try query(sql, params).first
    }

    private func bind(_ stmt: OpaquePointer?, _ params: [SQLiteValue]) {
        for (i, param) in params.enumerated() {
            let idx = Int32(i + 1)
            switch param {
            case .integer(let v): sqlite3_bind_int64(stmt, idx, v)
            case .real(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
    }
}

/// Thin actor-isolated wrapper around the SQLite3 C API - no third-party dependency, so the
/// package builds with zero network access needed for `swift build` / Xcode's dependency
/// resolution. Being an actor serializes all access to the single `sqlite3*` handle, which
/// stands in for the "share one connection per request" pattern `get_connection()` used in
/// the Python version.
actor Database {
    private var handle: OpaquePointer?

    /// - Parameter dataDir: the app-support dir; `source_image` is stored relative to it, and the
    ///   migration that converts absolute paths to relative ones needs it.
    init(path: String, dataDir: URL) throws {
        var db: OpaquePointer?
        if sqlite3_open(path, &db) != SQLITE_OK {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw DatabaseError.openFailed(msg)
        }
        handle = db
        let conn = SQLConnection(handle: db)
        // Per-connection setting (not stored in the file), so it has to be set on every open.
        try conn.run("PRAGMA foreign_keys = ON")
        try Database.migrate(conn, dbPath: path, dataDir: dataDir)
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    // MARK: - Migrations

    private struct Migration {
        let version: Int
        let name: String
        let apply: (SQLConnection, _ dataDir: URL) throws -> Void
    }

    private static func columns(of table: String, _ c: SQLConnection) throws -> Set<String> {
        Set(try c.query("PRAGMA table_info(\(table))").compactMap { $0.string(1) })
    }

    private static func addColumnIfMissing(_ table: String, _ column: String, _ type: String, _ c: SQLConnection) throws {
        if try !columns(of: table, c).contains(column) {
            try c.run("ALTER TABLE \(table) ADD COLUMN \(column) \(type)")
        }
    }

    /// Ordered, numbered, append-only. Never edit a shipped migration - add a new one. The
    /// version of the last entry is what `PRAGMA user_version` holds after a successful run.
    private static let migrations: [Migration] = [
        // 1: the original schema. A no-op on databases that already have these tables/columns
        // (they report user_version 0 because the app didn't use it before).
        Migration(version: 1, name: "baseline schema") { c, _ in
            try c.run("""
                CREATE TABLE IF NOT EXISTS item_dictionary (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    canonical_name TEXT UNIQUE NOT NULL,
                    display_name_de TEXT,
                    translation_en TEXT,
                    category TEXT,
                    subcategory TEXT,
                    item_group TEXT,
                    aliases TEXT,
                    is_manual_override INTEGER DEFAULT 0,
                    needs_review INTEGER DEFAULT 0,
                    times_seen INTEGER DEFAULT 1,
                    created_at TEXT,
                    last_seen_at TEXT
                )
                """)
            try c.run("""
                CREATE TABLE IF NOT EXISTS receipts (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    store TEXT,
                    date TEXT,
                    time TEXT,
                    total REAL,
                    computed_sum REAL,
                    needs_review INTEGER DEFAULT 0,
                    review_reasons TEXT,
                    source_image TEXT,
                    created_at TEXT,
                    reviewed_at TEXT
                )
                """)
            try c.run("""
                CREATE TABLE IF NOT EXISTS line_items (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    receipt_id INTEGER NOT NULL REFERENCES receipts(id),
                    item_dictionary_id INTEGER NOT NULL REFERENCES item_dictionary(id),
                    raw_text TEXT,
                    name_de TEXT,
                    quantity REAL,
                    unit_price REAL,
                    total_price REAL,
                    price_normalized INTEGER DEFAULT 0
                )
                """)
            // DBs created before reviewed_at existed (the old `try? ALTER TABLE` case).
            try addColumnIfMissing("receipts", "reviewed_at", "TEXT", c)
        },
        // 2: indexes for the joins / date filters every list and stats query uses.
        Migration(version: 2, name: "indexes") { c, _ in
            try c.run("CREATE INDEX IF NOT EXISTS idx_line_items_receipt ON line_items(receipt_id)")
            try c.run("CREATE INDEX IF NOT EXISTS idx_line_items_item ON line_items(item_dictionary_id)")
            try c.run("CREATE INDEX IF NOT EXISTS idx_receipts_date ON receipts(date)")
        },
        // 3: duplicate detection (image_hash) and soft delete (deleted_at). Both nullable, so
        // existing rows are untouched (existing receipts simply have no hash).
        Migration(version: 3, name: "image_hash and deleted_at") { c, _ in
            try addColumnIfMissing("receipts", "image_hash", "TEXT", c)
            try addColumnIfMissing("receipts", "deleted_at", "TEXT", c)
            try c.run("CREATE INDEX IF NOT EXISTS idx_receipts_image_hash ON receipts(image_hash)")
        },
        // 4: store source_image relative to the app-support dir (as the Python-era rows already do), so moving the app-support folder
        // doesn't break every image link. Only rewrites paths that start with that dir
        // (plain prefix compare, not LIKE, so `%`/`_` in the path can't misbehave); anything
        // else (e.g. a staging path left by a failed move) stays absolute.
        Migration(version: 4, name: "relative source_image paths") { c, dataDir in
            let prefix = dataDir.path.hasSuffix("/") ? dataDir.path : dataDir.path + "/"
            try c.run("""
                UPDATE receipts SET source_image = substr(source_image, length(?) + 1)
                WHERE source_image IS NOT NULL AND substr(source_image, 1, length(?)) = ?
                """, [.text(prefix), .text(prefix), .text(prefix)])
        },
        // 5: taxonomy rework. Points item_dictionary rows at renamed/merged paths and re-files
        // non-manual rows through the keyword rules (manual overrides only get pure renames).
        Migration(version: 5, name: "taxonomy v5 renames and keyword refile") { c, _ in
            try ItemCategorizer.applyTaxonomyV5(c, taxonomy: Taxonomy.load())
        },
        // 6: re-file manual-override rows the v5 keyword rules would move (approved by the user).
        Migration(version: 6, name: "re-file manual overrides into new categories") { c, _ in
            try ItemCategorizer.applyManualRefilesV6(c, taxonomy: Taxonomy.load())
        },
        // 7: cloud sync fields (uuid, updated_at, sync_state, photo/job status) + the triggers that
        // track local edits. Existing rows get the UUIDs migrate_mac_data.py gives them (Sync/SyncSchema.swift).
        Migration(version: 7, name: "sync fields and change tracking") { c, _ in
            try SyncSchema.apply(c)
        },
    ]

    static var latestSchemaVersion: Int { migrations.last?.version ?? 0 }

    /// Applies every migration newer than `PRAGMA user_version`, each in its own transaction
    /// together with the version bump. Before touching an existing database it copies the file
    /// to `<db>.bak-v<oldVersion>` (kept if already present, so the oldest copy survives).
    /// Static + takes a raw connection so it can run from `init`, before `self` is isolated.
    private static func migrate(_ c: SQLConnection, dbPath: String, dataDir: URL) throws {
        let current = try c.queryOne("PRAGMA user_version")?.int(0) ?? 0
        let pending = migrations.filter { $0.version > current }
        guard !pending.isEmpty else { return }

        // A brand-new file has nothing worth backing up.
        let hasData = try !c.query("SELECT name FROM sqlite_master WHERE type = 'table' LIMIT 1").isEmpty
        let fm = FileManager.default
        if hasData, fm.fileExists(atPath: dbPath) {
            let backup = "\(dbPath).bak-v\(current)"
            if !fm.fileExists(atPath: backup) {
                // If this throws, the app refuses to start rather than migrate without a backup.
                try fm.copyItem(atPath: dbPath, toPath: backup)
            }
        }

        for migration in pending {
            try c.run("BEGIN IMMEDIATE")
            do {
                try migration.apply(c, dataDir)
                try c.run("PRAGMA user_version = \(migration.version)")
                try c.run("COMMIT")
            } catch {
                _ = try? c.run("ROLLBACK")
                throw DatabaseError.stepFailed("migration \(migration.version) (\(migration.name)) failed: \(error)", "")
            }
        }
    }

    // MARK: - Statements

    @discardableResult
    func run(_ sql: String, _ params: [SQLiteValue] = []) throws -> Int64 {
        try SQLConnection(handle: handle).run(sql, params)
    }

    func query(_ sql: String, _ params: [SQLiteValue] = []) throws -> [SQLRow] {
        try SQLConnection(handle: handle).query(sql, params)
    }

    func queryOne(_ sql: String, _ params: [SQLiteValue] = []) throws -> SQLRow? {
        try SQLConnection(handle: handle).queryOne(sql, params)
    }

    /// Runs `body` between BEGIN IMMEDIATE and COMMIT; any throw rolls everything back. `body`
    /// is synchronous on purpose (see `SQLConnection`): no other caller can sneak statements
    /// into the transaction because the actor never suspends while it runs.
    func transaction<T>(_ body: (SQLConnection) throws -> T) throws -> T {
        let conn = SQLConnection(handle: handle)
        try conn.run("BEGIN IMMEDIATE")
        do {
            let result = try body(conn)
            try conn.run("COMMIT")
            return result
        } catch {
            _ = try? conn.run("ROLLBACK")
            throw error
        }
    }
}
