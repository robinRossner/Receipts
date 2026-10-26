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

/// Thin actor-isolated wrapper around the SQLite3 C API - no third-party dependency, so the
/// package builds with zero network access needed for `swift build` / Xcode's dependency
/// resolution. Being an actor serializes all access to the single `sqlite3*` handle, which
/// stands in for the "share one connection per request" pattern `get_connection()` used in
/// the Python version.
actor Database {
    private var handle: OpaquePointer?

    init(path: String) throws {
        var db: OpaquePointer?
        if sqlite3_open(path, &db) != SQLITE_OK {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw DatabaseError.openFailed(msg)
        }
        handle = db
        try Database.initSchema(on: db)
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    /// Creates every table if missing. Safe to call every launch - mirrors init_db() in both
    /// categorize_item.py (item_dictionary) and receipt_pipeline.py (receipts, line_items).
    /// Static + takes the raw handle so it can run synchronously from `init`, before `self` is
    /// actor-isolated (an actor's own instance methods can't be called from its init).
    private static func initSchema(on handle: OpaquePointer?) throws {
        func exec(_ sql: String) throws {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(handle)), sql)
            }
            defer { sqlite3_finalize(stmt) }
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
                throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(handle)), sql)
            }
        }

        try exec("""
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
        try exec("""
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
        try exec("""
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
        // Lightweight migration for DBs created before reviewed_at existed - matches the
        // try/except sqlite3.OperationalError pattern in receipt_pipeline.py's init_db.
        _ = try? exec("ALTER TABLE receipts ADD COLUMN reviewed_at TEXT")
    }

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
