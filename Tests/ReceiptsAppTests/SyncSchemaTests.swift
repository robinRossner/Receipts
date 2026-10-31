import XCTest
@testable import ReceiptsApp

final class SyncSchemaTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws { dir = try makeTempDir() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func legacyDatabase() async throws -> Database {
        try LegacyDB.create(at: dir.appendingPathComponent("receipts.db").path, LegacyDB.populateSample)
        return try openTempDatabase(in: dir)
    }

    func testMigrationAssignsTheUUIDsThePythonMigrationUses() async throws {
        let db = try await legacyDatabase()
        let version = try await db.scalarInt("PRAGMA user_version")
        XCTAssertEqual(version, Database.latestSchemaVersion)
        XCTAssertGreaterThanOrEqual(Database.latestSchemaVersion, 7)

        for (table, kind) in [("receipts", LegacyIDs.Kind.receipt), ("item_dictionary", .dictionary), ("line_items", .lineItem)] {
            let rows = try await db.query("SELECT id, uuid FROM \(table) ORDER BY id")
            XCTAssertFalse(rows.isEmpty)
            for row in rows {
                XCTAssertEqual(row.string(1), LegacyIDs.uuid(kind, row.int(0)!), "\(table) #\(row.int(0)!)")
            }
        }
        // spot check against values printed by migrate_mac_data.uid()
        let r1 = try await db.scalarString("SELECT uuid FROM receipts WHERE id = 1")
        XCTAssertEqual(r1, "f79084c1-899d-5a3c-b750-a23294f970b0")
        let d2 = try await db.scalarString("SELECT uuid FROM item_dictionary WHERE id = 2")
        XCTAssertEqual(d2, "daf7da63-f4cc-5607-a6a9-f97ecdebfcaf")
    }

    func testMigrationComputesUpdatedAtAndPositionLikeThePythonMigration() async throws {
        let db = try await legacyDatabase()
        func updated(_ table: String, _ id: Int) async throws -> String? {
            try await db.scalarString("SELECT updated_at FROM \(table) WHERE id = ?", [.from(id)])
        }
        // dictionary: max(created_at, last_seen_at); space separated and missing timestamps are handled
        let d1 = try await updated("item_dictionary", 1), d2 = try await updated("item_dictionary", 2), d3 = try await updated("item_dictionary", 3)
        XCTAssertEqual(d1, "2026-02-01T08:30:00.000Z")
        XCTAssertEqual(d2, "2026-01-06T11:00:00.000Z")
        XCTAssertEqual(d3, "1970-01-01T00:00:00.000Z")
        // receipts: max(created, reviewed, deleted)
        let r1 = try await updated("receipts", 1), r2 = try await updated("receipts", 2), r3 = try await updated("receipts", 3)
        XCTAssertEqual(r1, "2026-03-02T18:00:00.000Z")
        XCTAssertEqual(r2, "2026-03-05T12:00:00.000Z")
        XCTAssertEqual(r3, "2026-03-10T07:00:00.000Z")
        // line items: the receipt's created_at
        let l1 = try await updated("line_items", 1), l6 = try await updated("line_items", 6)
        XCTAssertEqual(l1, "2026-03-01T09:30:00.000Z")
        XCTAssertEqual(l6, "2026-03-09T17:50:00.000Z")

        // position = rank among the importable items of the receipt by id; the orphan (id 3) is skipped
        let positions = try await db.query("SELECT id, position, sync_state FROM line_items ORDER BY id")
        XCTAssertEqual(positions.map { $0.int(1) }, [0, 0, 0, 1, 2, 0])
        XCTAssertEqual(positions.map { $0.string(2) }, ["dirty", "dirty", "synced", "dirty", "dirty", "dirty"])
    }

    func testExistingRowsStartDirtyAndUntouchedBackupIsKept() async throws {
        let db = try await legacyDatabase()
        let dirty = try await db.scalarInt("SELECT COUNT(*) FROM receipts WHERE sync_state = 'dirty'")
        XCTAssertEqual(dirty, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("receipts.db.bak-v6").path))
    }

    func testReopeningDoesNotChangeAssignedIds() async throws {
        var db: Database? = try await legacyDatabase()
        let before = try await db!.scalarString("SELECT group_concat(uuid) FROM receipts")
        db = nil
        let again = try openTempDatabase(in: dir)
        let after = try await again.scalarString("SELECT group_concat(uuid) FROM receipts")
        XCTAssertEqual(before, after)
    }

    // MARK: - change tracking triggers

    func testEditMarksRowDirtyAndAdvancesUpdatedAt() async throws {
        let db = try await legacyDatabase()
        try await db.run("UPDATE receipts SET sync_state = 'synced'")
        try await db.run("UPDATE receipts SET store = 'Edeka Nord' WHERE id = 1")
        let rows = try await db.query("SELECT id, sync_state, updated_at FROM receipts ORDER BY id")
        XCTAssertEqual(rows.map { $0.string(1) }, ["dirty", "synced", "synced"])
        let stamp = SyncDate.parse(rows[0].string(2))!
        XCTAssertLessThan(abs(stamp.timeIntervalSinceNow), 5)
    }

    func testServerOwnedColumnsAreNotEdits() async throws {
        let db = try await legacyDatabase()
        try await db.run("UPDATE receipts SET sync_state = 'synced'")
        try await db.run("UPDATE item_dictionary SET sync_state = 'synced'")
        try await db.run("UPDATE receipts SET photo_location = 'archived', extraction_status = 'done', photo_sha256 = 'x' WHERE id = 1")
        try await db.run("UPDATE item_dictionary SET times_seen = times_seen + 1, last_seen_at = '2026-10-01T00:00:00Z' WHERE id = 1")
        let dirty = try await db.scalarInt("SELECT (SELECT COUNT(*) FROM receipts WHERE sync_state='dirty') + (SELECT COUNT(*) FROM item_dictionary WHERE sync_state='dirty')")
        XCTAssertEqual(dirty, 0)
        try await db.run("UPDATE item_dictionary SET category = 'Household' WHERE id = 1")
        let d1 = try await db.scalarString("SELECT sync_state FROM item_dictionary WHERE id = 1")
        XCTAssertEqual(d1, "dirty")
    }

    func testNewRowsGetUUIDPositionAndKeepLastInsertRowID() async throws {
        let db = try await legacyDatabase()
        let id = try await db.run("INSERT INTO receipts (store, created_at) VALUES ('Aldi Süd', '2026-10-01T10:00:00Z')")
        let uuid = try await db.scalarString("SELECT uuid FROM receipts WHERE id = ?", [.integer(id)])
        XCTAssertNotNil(uuid)
        XCTAssertNotNil(UUID(uuidString: uuid!))
        XCTAssertEqual(uuid, uuid?.lowercased())
        XCTAssertEqual(uuid?.dropFirst(14).first, "4")

        let item1 = try await db.run("INSERT INTO line_items (receipt_id, item_dictionary_id, raw_text, name_de, quantity, unit_price, total_price) VALUES (?, 1, 'a', 'a', 1, 1, 1)", [.integer(id)])
        let item2 = try await db.run("INSERT INTO line_items (receipt_id, item_dictionary_id, raw_text, name_de, quantity, unit_price, total_price) VALUES (?, 2, 'b', 'b', 1, 1, 1)", [.integer(id)])
        XCTAssertEqual(item2, item1 + 1)
        let positions = try await db.query("SELECT position, sync_state, uuid FROM line_items WHERE receipt_id = ? ORDER BY id", [.integer(id)])
        XCTAssertEqual(positions.map { $0.int(0) }, [0, 1])
        XCTAssertEqual(positions.map { $0.string(1) }, ["dirty", "dirty"])
        XCTAssertTrue(positions.allSatisfy { $0.string(2) != nil })

        // an item added to a migrated receipt continues after its last position
        try await db.run("INSERT INTO line_items (receipt_id, item_dictionary_id, raw_text, name_de, quantity, unit_price, total_price) VALUES (1, 1, 'n', 'n', 1, 1, 1)")
        let last = try await db.scalarInt("SELECT position FROM line_items WHERE receipt_id = 1 ORDER BY id DESC LIMIT 1")
        XCTAssertEqual(last, 3)
    }

    func testHardDeleteLeavesTombstoneWithFullPayload() async throws {
        let db = try await legacyDatabase()
        try await db.run("DELETE FROM line_items WHERE id = 4")
        let row = try await db.queryOne("SELECT entity, uuid, payload FROM sync_tombstones")
        XCTAssertEqual(row?.string(0), "line_item")
        XCTAssertEqual(row?.string(1), LegacyIDs.uuid(.lineItem, 4))
        let payload = try JSONSerialization.jsonObject(with: Data(row!.string(2)!.utf8)) as! [String: Any]
        XCTAssertEqual(payload["receipt_id"] as? String, LegacyIDs.uuid(.receipt, 1))
        XCTAssertEqual(payload["item_dictionary_id"] as? String, LegacyIDs.uuid(.dictionary, 2))
        XCTAssertEqual(payload["quantity"] as? Double, 1)
    }

    func testSyncsOwnWritesAreNotTrackedWhileApplying() async throws {
        let db = try await legacyDatabase()
        try await db.run("UPDATE receipts SET sync_state = 'synced'")
        try await db.run("INSERT OR REPLACE INTO sync_meta (key, value) VALUES ('applying', '1')")
        try await db.run("UPDATE receipts SET store = 'From server' WHERE id = 2")
        try await db.run("DELETE FROM line_items WHERE id = 6")
        try await db.run("UPDATE sync_meta SET value = '0' WHERE key = 'applying'")
        let dirty = try await db.scalarInt("SELECT COUNT(*) FROM receipts WHERE sync_state = 'dirty'")
        let tombstones = try await db.scalarInt("SELECT COUNT(*) FROM sync_tombstones")
        XCTAssertEqual(dirty, 0)
        XCTAssertEqual(tombstones, 0)
    }
}
