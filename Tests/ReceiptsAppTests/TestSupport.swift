import Foundation
import SQLite3
import XCTest
@testable import ReceiptsApp

/// A throw-away directory per test. Tests NEVER touch ~/Library/Application Support/ReceiptsApp.
func makeTempDir(_ name: String = "receipts-tests") throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func openTempDatabase(in dir: URL) throws -> Database {
    try Database(path: dir.appendingPathComponent("receipts.db").path, dataDir: dir)
}

/// Builds a database exactly as the Mac app left it at schema version 6 (before sync), through
/// the raw SQLite API so the app's own migrations are not involved.
enum LegacyDB {
    static func create(at path: String, _ populate: (OpaquePointer) throws -> Void) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        guard let db else { return }
        for sql in schemaV6 { try exec(db, sql) }
        try populate(db)
        try exec(db, "PRAGMA user_version = 6")
    }

    static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            throw DatabaseError.stepFailed(msg, sql)
        }
    }

    static let schemaV6 = [
        """
        CREATE TABLE item_dictionary (id INTEGER PRIMARY KEY AUTOINCREMENT, canonical_name TEXT UNIQUE NOT NULL,
            display_name_de TEXT, translation_en TEXT, category TEXT, subcategory TEXT, item_group TEXT, aliases TEXT,
            is_manual_override INTEGER DEFAULT 0, needs_review INTEGER DEFAULT 0, times_seen INTEGER DEFAULT 1,
            created_at TEXT, last_seen_at TEXT)
        """,
        """
        CREATE TABLE receipts (id INTEGER PRIMARY KEY AUTOINCREMENT, store TEXT, date TEXT, time TEXT, total REAL,
            computed_sum REAL, needs_review INTEGER DEFAULT 0, review_reasons TEXT, source_image TEXT, created_at TEXT,
            reviewed_at TEXT, image_hash TEXT, deleted_at TEXT)
        """,
        """
        CREATE TABLE line_items (id INTEGER PRIMARY KEY AUTOINCREMENT, receipt_id INTEGER NOT NULL REFERENCES receipts(id),
            item_dictionary_id INTEGER NOT NULL REFERENCES item_dictionary(id), raw_text TEXT, name_de TEXT,
            quantity REAL, unit_price REAL, total_price REAL, price_normalized INTEGER DEFAULT 0)
        """,
    ]

    /// A small realistic data set: 3 dictionary entries, 3 receipts (reviewed / unreviewed / deleted), items
    /// interleaved across receipts, plus an orphan item (its dictionary entry is gone).
    static func populateSample(_ db: OpaquePointer) throws {
        try exec(db, """
            INSERT INTO item_dictionary (id, canonical_name, display_name_de, translation_en, category, subcategory, item_group, aliases, is_manual_override, created_at, last_seen_at) VALUES
            (1, 'bio eier', 'Bio Eier', 'organic eggs', 'Food', 'Dairy & Eggs', 'Eggs', '["bio eier 10er"]', 1, '2026-01-05T10:00:00Z', '2026-02-01T08:30:00Z'),
            (2, 'milch', 'Milch', 'milk', 'Food', 'Dairy & Eggs', 'Milk', '[]', 0, '2026-01-06 11:00:00', NULL),
            (3, 'pfand', 'Pfand', 'deposit', 'Other', 'Deposits & Refunds', 'Pfand', '[]', 0, NULL, NULL)
            """)
        try exec(db, """
            INSERT INTO receipts (id, store, date, time, total, computed_sum, needs_review, review_reasons, source_image, created_at, reviewed_at, deleted_at) VALUES
            (1, 'Edeka', '2026-03-01', '09:12', 5.73, 5.73, 0, '[]', 'receipts_archive/2026/03/2026-03-01_edeka_1.jpg', '2026-03-01T09:30:00Z', '2026-03-02T18:00:00Z', NULL),
            (2, 'Lidl', '2026-03-05', NULL, 3.10, 3.10, 1, '["Possible duplicate of receipt #1"]', NULL, '2026-03-05T12:00:00Z', NULL, NULL),
            (3, 'Rewe', '2026-03-09', '17:45', 1.00, 1.00, 0, '[]', 'receipts_archive/2026/03/x.jpg', '2026-03-09T17:50:00Z', NULL, '2026-03-10T07:00:00Z')
            """)
        // Item 3 is an orphan: its dictionary entry no longer exists (foreign keys are off here), the server
        // migration skips it and it must not use up a position.
        try exec(db, """
            INSERT INTO line_items (id, receipt_id, item_dictionary_id, raw_text, name_de, quantity, unit_price, total_price) VALUES
            (1, 1, 1, 'BIO EIER', 'Bio Eier', 1, 2.49, 2.49),
            (2, 2, 2, 'MILCH', 'Milch', 2, 1.55, 3.10),
            (3, 1, 99, 'GHOST', 'Ghost', 1, 1, 1),
            (4, 1, 2, 'MILCH', 'Milch', 1, 1.55, 1.55),
            (5, 1, 3, 'PFAND', 'Pfand', 6, 0.25, 1.50),
            (6, 3, 3, 'PFAND', 'Pfand', 4, 0.25, 1.00)
            """)
    }
}

extension Database {
    func scalarString(_ sql: String, _ params: [SQLiteValue] = []) async throws -> String? {
        try await queryOne(sql, params)?.string(0)
    }
    func scalarInt(_ sql: String, _ params: [SQLiteValue] = []) async throws -> Int? {
        try await queryOne(sql, params)?.int(0)
    }
}
