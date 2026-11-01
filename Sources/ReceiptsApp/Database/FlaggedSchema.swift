import Foundation

/// Database migration 8: the "no good category" flag of dictionary entries and the user-added taxonomy paths.
///
/// - `item_dictionary.category_flagged` (0/1), `suggested_category` (short name of the missing category) and
///   `suggested_parent` ("Category" or "Category > Subcategory" it would go under). The flag lives on the dictionary entry
///   because the category does: resolving it fixes every receipt that uses the item. These three columns are part of the
///   synced record (docs/api/receipts.md, "Flagged categories").
/// - `taxonomy_additions`: extra category paths on top of the bundled taxonomy (which is a read-only resource shared with
///   the server). Append-only; `sync_state` is `dirty` until the server acknowledged the path.
///
/// Additive and safe on a real database: existing rows keep every value (flag 0, no suggestion).
enum FlaggedSchema {
    static func apply(_ c: SQLConnection) throws {
        let have = Set(try c.query("PRAGMA table_info(item_dictionary)").compactMap { $0.string(1) })
        if !have.contains("category_flagged") { try c.run("ALTER TABLE item_dictionary ADD COLUMN category_flagged INTEGER NOT NULL DEFAULT 0") }
        if !have.contains("suggested_category") { try c.run("ALTER TABLE item_dictionary ADD COLUMN suggested_category TEXT") }
        if !have.contains("suggested_parent") { try c.run("ALTER TABLE item_dictionary ADD COLUMN suggested_parent TEXT") }
        try c.run("CREATE INDEX IF NOT EXISTS idx_item_dictionary_flagged ON item_dictionary(category_flagged)")

        try c.run("""
            CREATE TABLE IF NOT EXISTS taxonomy_additions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                category TEXT NOT NULL,
                subcategory TEXT NOT NULL,
                item_group TEXT NOT NULL,
                created_at TEXT NOT NULL,
                sync_state TEXT NOT NULL DEFAULT 'dirty',
                sync_error TEXT
            )
            """)
        try c.run("""
            CREATE UNIQUE INDEX IF NOT EXISTS idx_taxonomy_additions_path
            ON taxonomy_additions(lower(category), lower(subcategory), lower(item_group))
            """)
        try SyncSchema.recreateDictionaryUpdateTrigger(c)
    }
}
