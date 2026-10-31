import Foundation

/// Database migration 7: the fields cloud sync needs, added to the existing tables.
///
/// Every row gets a `uuid` (wire id), `updated_at` (last-write-wins clock) and a `sync_state`
/// (`dirty` = has a local change the server has not acknowledged, `synced`, `rejected`). Receipts also keep the
/// server-owned `photo_location` / `photo_sha256` / `extraction_status` / `extraction_error` (job status).
///
/// Local edits are tracked by SQLite TRIGGERS rather than by every UPDATE in the app: whatever
/// code changes a receipt, line item or dictionary entry (including the local pipeline and the
/// dictionary editor) stamps `updated_at` and marks the row dirty, and a hard DELETE leaves a
/// tombstone record in `sync_tombstones`. Sync itself writes with `sync_meta.applying = 1` so its own writes
/// are not mistaken for edits. Without sync turned on the triggers only cost a few column writes.
///
/// Existing rows get the UUID `migrate_mac_data.py` gives them (see `LegacyIDs`) and the same
/// `updated_at` / `position` it computes, and start `dirty`, so a server that has not been
/// migrated receives them and one that has answers `stale` (no duplicates, nothing overwritten).
enum SyncSchema {
    private static let uuidExpr = """
        lower(hex(randomblob(4)) || '-' || hex(randomblob(2)) || '-4' || substr(hex(randomblob(2)), 2) || '-' \
        || substr('89ab', 1 + (abs(random()) % 4), 1) || substr(hex(randomblob(2)), 2) || '-' || hex(randomblob(6)))
        """
    private static let nowExpr = "strftime('%Y-%m-%dT%H:%M:%fZ', 'now')"
    private static let notApplying = "COALESCE((SELECT value FROM sync_meta WHERE key = 'applying'), '0') = '0'"

    static func apply(_ c: SQLConnection) throws {
        try c.run("CREATE TABLE IF NOT EXISTS sync_meta (key TEXT PRIMARY KEY, value TEXT)")
        try c.run("""
            CREATE TABLE IF NOT EXISTS sync_tombstones (
                entity TEXT NOT NULL,
                uuid TEXT NOT NULL,
                payload TEXT NOT NULL,
                deleted_at TEXT NOT NULL,
                PRIMARY KEY (entity, uuid)
            )
            """)

        for table in ["receipts", "line_items", "item_dictionary"] {
            try add(table, "uuid", "TEXT", c)
            try add(table, "updated_at", "TEXT", c)
            try add(table, "sync_state", "TEXT NOT NULL DEFAULT 'dirty'", c)
            try add(table, "sync_error", "TEXT", c)
        }
        try add("line_items", "position", "INTEGER NOT NULL DEFAULT 0", c)
        try add("receipts", "photo_location", "TEXT", c)   // server | archived | none; NULL = never synced
        try add("receipts", "photo_sha256", "TEXT", c)
        try add("receipts", "extraction_status", "TEXT", c) // job status: pending_upload, upload_failed, queued, ...
        try add("receipts", "extraction_error", "TEXT", c)
        try add("receipts", "archive_accept_failed", "INTEGER NOT NULL DEFAULT 0", c)

        try backfill(c)

        for table in ["receipts", "line_items", "item_dictionary"] {
            try c.run("CREATE UNIQUE INDEX IF NOT EXISTS idx_\(table)_uuid ON \(table)(uuid)")
            try c.run("CREATE INDEX IF NOT EXISTS idx_\(table)_sync_state ON \(table)(sync_state)")
        }
        try createTriggers(c)
    }

    private static func add(_ table: String, _ column: String, _ type: String, _ c: SQLConnection) throws {
        let have = Set(try c.query("PRAGMA table_info(\(table))").compactMap { $0.string(1) })
        if !have.contains(column) { try c.run("ALTER TABLE \(table) ADD COLUMN \(column) \(type)") }
    }

    // MARK: - Existing rows

    /// uuid + updated_at (+ position) exactly as migrate_mac_data.py computes them. `now` there is
    /// the server migration's clock, unknown here: rows without a created_at get the epoch, so the
    /// server's copy wins the first sync.
    static func backfill(_ c: SQLConnection) throws {
        let epoch = Date(timeIntervalSince1970: 0)

        for row in try c.query("SELECT id, created_at, last_seen_at FROM item_dictionary WHERE uuid IS NULL ORDER BY id") {
            guard let id = row.int(0) else { continue }
            let created = SyncDate.parse(row.string(1)) ?? epoch
            let seen = SyncDate.parse(row.string(2)) ?? created
            try c.run("UPDATE item_dictionary SET uuid = ?, updated_at = ? WHERE id = ?",
                      [.text(LegacyIDs.uuid(.dictionary, id)), .text(SyncDate.string(from: max(created, seen))), .from(id)])
        }

        for row in try c.query("SELECT id, created_at, reviewed_at, deleted_at FROM receipts WHERE uuid IS NULL ORDER BY id") {
            guard let id = row.int(0) else { continue }
            let created = SyncDate.parse(row.string(1)) ?? epoch
            var latest = created
            if let reviewed = row.string(2), !reviewed.isEmpty { latest = max(latest, SyncDate.parse(reviewed) ?? created) }
            if let deleted = row.string(3), !deleted.isEmpty { latest = max(latest, SyncDate.parse(deleted) ?? created) }
            try c.run("UPDATE receipts SET uuid = ?, updated_at = ? WHERE id = ?",
                      [.text(LegacyIDs.uuid(.receipt, id)), .text(SyncDate.string(from: latest)), .from(id)])
        }

        // Line items: position = rank among the receipt's items by id, counting only rows the
        // server migration imports (receipt AND dictionary entry exist); the others are orphans
        // from the Python era that it skips, and they are never pushed (marked synced).
        var counters: [Int: Int] = [:]
        let rows = try c.query("""
            SELECT li.id, li.receipt_id, r.id IS NOT NULL AND d.id IS NOT NULL, r.created_at
            FROM line_items li
            LEFT JOIN receipts r ON r.id = li.receipt_id
            LEFT JOIN item_dictionary d ON d.id = li.item_dictionary_id
            WHERE li.uuid IS NULL ORDER BY li.id
            """)
        for row in rows {
            guard let id = row.int(0), let receiptId = row.int(1) else { continue }
            let importable = row.bool(2)
            var position = 0
            if importable {
                position = counters[receiptId, default: 0]
                counters[receiptId] = position + 1
            }
            let updated = SyncDate.parse(row.string(3)) ?? epoch
            try c.run("""
                UPDATE line_items SET uuid = ?, updated_at = ?, position = ?, sync_state = ? WHERE id = ?
                """, [.text(LegacyIDs.uuid(.lineItem, id)), .text(SyncDate.string(from: updated)), .from(position),
                      .text(importable ? "dirty" : "synced"), .from(id)])
        }
    }

    // MARK: - Triggers

    private static func createTriggers(_ c: SQLConnection) throws {
        // Receipts ---------------------------------------------------------------------------
        try c.run("""
            CREATE TRIGGER IF NOT EXISTS trg_receipts_sync_insert AFTER INSERT ON receipts
            WHEN NEW.uuid IS NULL
            BEGIN
                UPDATE receipts SET uuid = \(uuidExpr), updated_at = COALESCE(NEW.updated_at, \(nowExpr)),
                    sync_state = 'dirty' WHERE id = NEW.id;
            END
            """)
        try c.run("""
            CREATE TRIGGER IF NOT EXISTS trg_receipts_sync_update
            AFTER UPDATE OF store, date, time, total, computed_sum, needs_review, review_reasons, reviewed_at, deleted_at ON receipts
            WHEN NEW.uuid IS NOT NULL AND \(notApplying)
            BEGIN
                UPDATE receipts SET updated_at = \(nowExpr), sync_state = 'dirty', sync_error = NULL WHERE id = NEW.id;
            END
            """)
        try c.run("""
            CREATE TRIGGER IF NOT EXISTS trg_receipts_sync_delete BEFORE DELETE ON receipts
            WHEN OLD.uuid IS NOT NULL AND \(notApplying)
            BEGIN
                INSERT OR REPLACE INTO sync_tombstones (entity, uuid, deleted_at, payload) VALUES (
                    'receipt', OLD.uuid, COALESCE(OLD.deleted_at, \(nowExpr)),
                    json_object('id', OLD.uuid, 'store', OLD.store, 'date', OLD.date, 'time', OLD.time,
                        'total', OLD.total, 'computed_sum', OLD.computed_sum, 'needs_review', OLD.needs_review,
                        'review_reasons', OLD.review_reasons, 'reviewed_at', OLD.reviewed_at,
                        'has_photo', OLD.source_image IS NOT NULL));
            END
            """)

        // Line items -------------------------------------------------------------------------
        try c.run("""
            CREATE TRIGGER IF NOT EXISTS trg_line_items_sync_insert AFTER INSERT ON line_items
            WHEN NEW.uuid IS NULL
            BEGIN
                UPDATE line_items SET uuid = \(uuidExpr), updated_at = COALESCE(NEW.updated_at, \(nowExpr)),
                    sync_state = 'dirty',
                    position = COALESCE((SELECT MAX(position) FROM line_items
                                         WHERE receipt_id = NEW.receipt_id AND id != NEW.id), -1) + 1
                WHERE id = NEW.id;
            END
            """)
        try c.run("""
            CREATE TRIGGER IF NOT EXISTS trg_line_items_sync_update
            AFTER UPDATE OF receipt_id, item_dictionary_id, raw_text, name_de, quantity, unit_price, total_price, price_normalized
            ON line_items
            WHEN NEW.uuid IS NOT NULL AND \(notApplying)
            BEGIN
                UPDATE line_items SET updated_at = \(nowExpr), sync_state = 'dirty', sync_error = NULL WHERE id = NEW.id;
            END
            """)
        try c.run("""
            CREATE TRIGGER IF NOT EXISTS trg_line_items_sync_delete BEFORE DELETE ON line_items
            WHEN OLD.uuid IS NOT NULL AND \(notApplying)
            BEGIN
                INSERT OR REPLACE INTO sync_tombstones (entity, uuid, deleted_at, payload) VALUES (
                    'line_item', OLD.uuid, \(nowExpr),
                    json_object('id', OLD.uuid,
                        'receipt_id', (SELECT uuid FROM receipts WHERE id = OLD.receipt_id),
                        'item_dictionary_id', (SELECT uuid FROM item_dictionary WHERE id = OLD.item_dictionary_id),
                        'position', OLD.position, 'raw_text', OLD.raw_text, 'name_de', OLD.name_de,
                        'quantity', OLD.quantity, 'unit_price', OLD.unit_price, 'total_price', OLD.total_price,
                        'price_normalized', OLD.price_normalized));
            END
            """)

        // Dictionary -------------------------------------------------------------------------
        // times_seen / last_seen_at are server-owned counters: changing them is not an edit.
        try c.run("""
            CREATE TRIGGER IF NOT EXISTS trg_item_dictionary_sync_insert AFTER INSERT ON item_dictionary
            WHEN NEW.uuid IS NULL
            BEGIN
                UPDATE item_dictionary SET uuid = \(uuidExpr), updated_at = COALESCE(NEW.updated_at, \(nowExpr)),
                    sync_state = 'dirty' WHERE id = NEW.id;
            END
            """)
        try c.run("""
            CREATE TRIGGER IF NOT EXISTS trg_item_dictionary_sync_update
            AFTER UPDATE OF canonical_name, display_name_de, translation_en, category, subcategory, item_group,
                            aliases, is_manual_override, needs_review ON item_dictionary
            WHEN NEW.uuid IS NOT NULL AND \(notApplying)
            BEGIN
                UPDATE item_dictionary SET updated_at = \(nowExpr), sync_state = 'dirty', sync_error = NULL WHERE id = NEW.id;
            END
            """)
        try c.run("""
            CREATE TRIGGER IF NOT EXISTS trg_item_dictionary_sync_delete BEFORE DELETE ON item_dictionary
            WHEN OLD.uuid IS NOT NULL AND \(notApplying)
            BEGIN
                INSERT OR REPLACE INTO sync_tombstones (entity, uuid, deleted_at, payload) VALUES (
                    'dictionary', OLD.uuid, \(nowExpr),
                    json_object('id', OLD.uuid, 'canonical_name', OLD.canonical_name,
                        'display_name_de', OLD.display_name_de, 'translation_en', OLD.translation_en,
                        'category', OLD.category, 'subcategory', OLD.subcategory, 'item_group', OLD.item_group,
                        'aliases_json', OLD.aliases, 'is_manual_override', OLD.is_manual_override,
                        'needs_review', OLD.needs_review));
            END
            """)
    }
}
