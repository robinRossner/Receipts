import XCTest
@testable import ReceiptsApp

/// The iPhone's review queue, keyboard input, deltas and the paths behind its `Undo` snackbar.
@MainActor
final class PhoneReviewLogicTests: XCTestCase {
    private var dir: URL!
    private var store: ReceiptStore!

    override func setUpWithError() throws {
        dir = try makeTempDir()
        let base = dir.appendingPathComponent("data", isDirectory: true)
        let env = AppEnvironment.make(baseDir: base)
        let db = try Database(path: env.dbPath, dataDir: base)
        store = ReceiptStore(env: env, db: db, taxonomy: Taxonomy.load(), capabilities: .mobile, deviceId: "iphone-test", reminders: NoReminders())
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func summary(_ id: Int, store name: String? = nil, reviewed: Bool = false, processing: ReceiptProcessing? = nil) -> ReceiptSummary {
        ReceiptSummary(id: id, store: name, date: nil, time: nil, total: nil, needsReview: false, reviewedAt: reviewed ? "2026-10-31T10:00:00Z" : nil, processing: processing)
    }

    /// A receipt with two line items of the same dictionary entry; returns (receipt id, dictionary id).
    private func seedReceipt(store name: String = "Edeka") async throws -> (receipt: Int, dictionary: Int) {
        let db = store.db
        _ = try await db.run("""
            INSERT INTO item_dictionary (canonical_name, display_name_de, translation_en, category, subcategory, item_group, created_at, last_seen_at)
            VALUES ('milch-\(UUID().uuidString)', 'Milch', 'milk', 'Food', 'Dairy & Eggs', 'Milk', '2026-10-01', '2026-10-01')
            """)
        let dictionaryRow = try await db.queryOne("SELECT MAX(id) FROM item_dictionary")
        let dictionary = try XCTUnwrap(dictionaryRow?.int(0))
        _ = try await db.run("INSERT INTO receipts (store, date, total, computed_sum, needs_review, review_reasons, created_at) VALUES (?, '2026-10-30', 3.00, 3.00, 0, '[]', '2026-10-30')", [.text(name)])
        let receiptRow = try await db.queryOne("SELECT MAX(id) FROM receipts")
        let receipt = try XCTUnwrap(receiptRow?.int(0))
        for (name, price) in [("Milch", 1.0), ("Milch 2", 2.0)] {
            _ = try await db.run("INSERT INTO line_items (receipt_id, item_dictionary_id, raw_text, name_de, quantity, unit_price, total_price) VALUES (?, ?, ?, ?, 1, ?, ?)",
                                 [.from(receipt), .from(dictionary), .text(name), .text(name), .from(price), .from(price)])
        }
        await store.refreshList()
        return (receipt, dictionary)
    }

    // MARK: Review queue

    func testNextIsTheOneAfterThisInTheListElseTheFirst() {
        let list = [summary(1, store: "A"), summary(2, store: "B", reviewed: true), summary(3, store: "C"), summary(4, store: "D")]
        XCTAssertEqual(ReviewQueue.next(after: 1, in: list)?.id, 3)
        XCTAssertEqual(ReviewQueue.next(after: 3, in: list)?.id, 4)
        XCTAssertEqual(ReviewQueue.next(after: 4, in: list)?.id, 1, "wraps to the first")
        XCTAssertEqual(ReviewQueue.next(after: 99, in: list)?.id, 1, "unknown id: the first")
    }

    func testTheQueueSkipsReceiptsStillBeingReadOrFailed() {
        let list = [summary(1, store: "A"), summary(2, processing: .processing), summary(3, processing: .failed(nil)), summary(4, store: "D")]
        XCTAssertEqual(ReviewQueue.next(after: 1, in: list)?.id, 4)
        XCTAssertNil(ReviewQueue.next(after: 1, in: [list[0], list[1]]))
    }

    func testHintWording() {
        let list = [summary(1, store: "A"), summary(2, store: "ALDI SÜD"), summary(3)]
        XCTAssertEqual(ReviewQueue.hint(for: 1, in: list), "2 more to review · next: ALDI SÜD")
        XCTAssertEqual(ReviewQueue.hint(for: 2, in: list), "2 more to review", "the next one has no store yet")
        XCTAssertEqual(ReviewQueue.hint(for: 1, in: [list[0]]), "Last one to review")
    }

    // MARK: Input and deltas

    func testDecimalInputAcceptsTheGermanComma() {
        XCTAssertEqual(DecimalInput.parse("12,50"), 12.5)
        XCTAssertEqual(DecimalInput.parse(" 2.59 "), 2.59)
        XCTAssertNil(DecimalInput.parse("abc"))
        XCTAssertNil(DecimalInput.parse(""))
    }

    func testSpendDelta() {
        func text(_ current: Double, _ previous: Double?, comparison: Bool = true) -> String? {
            SpendDelta.make(current: current, previous: previous, hasComparison: comparison, label: "last month")?.text
        }
        XCTAssertEqual(text(112, 100), "+12% vs last month")
        XCTAssertEqual(text(90, 100), "-10% vs last month")
        XCTAssertEqual(text(100.2, 100), "±0% vs last month")
        XCTAssertEqual(text(5, nil), "new vs last month")
        XCTAssertEqual(text(5, 0), "new vs last month")
        XCTAssertNil(text(0, 0))
        XCTAssertNil(text(5, 4, comparison: false), "custom and all time have no comparison")
    }

    func testTheCursorStopsAtTheCurrentPeriod() throws {
        let now = try XCTUnwrap(ReceiptDateFormat.date(from: "2026-10-31"))
        let september = try XCTUnwrap(ReceiptDateFormat.date(from: "2026-09-15"))
        XCTAssertTrue(OverviewCursor.isLatest(now, byYear: false, now: now))
        XCTAssertFalse(OverviewCursor.isLatest(september, byYear: false, now: now))
        XCTAssertTrue(OverviewCursor.isLatest(september, byYear: true, now: now))
    }

    // MARK: Undo paths

    func testConfirmAndUndoMarkTheReceiptDirtyAndRestoreItsState() async throws {
        let (receipt, _) = try await seedReceipt()
        _ = try await store.db.run("UPDATE receipts SET sync_state = 'synced' WHERE id = ?", [.from(receipt)])

        await store.markReviewed(id: receipt)
        XCTAssertNotNil(store.receipts.first { $0.id == receipt }?.reviewedAt)
        var state = try await store.db.queryOne("SELECT sync_state FROM receipts WHERE id = ?", [.from(receipt)])?.string(0)
        XCTAssertEqual(state, "dirty", "goes out with the next sync")
        XCTAssertNil(store.selectedReceipt, "a swipe on a row does not select another receipt")

        _ = try await store.db.run("UPDATE receipts SET sync_state = 'synced' WHERE id = ?", [.from(receipt)])
        await store.markUnreviewed(id: receipt)
        XCTAssertNil(store.receipts.first { $0.id == receipt }?.reviewedAt)
        state = try await store.db.queryOne("SELECT sync_state FROM receipts WHERE id = ?", [.from(receipt)])?.string(0)
        XCTAssertEqual(state, "dirty", "the undo goes out too, even after the confirmation was pushed")
    }

    func testDeletedItemComesBackAsTheSameRecordAtItsPlace() async throws {
        let (receipt, _) = try await seedReceipt()
        let db = store.db
        let before = try await db.query("SELECT id, uuid, position, name_de FROM line_items WHERE receipt_id = ? ORDER BY position, id", [.from(receipt)])
        let first = try XCTUnwrap(before.first)
        let (id, uuid, position) = (try XCTUnwrap(first.int(0)), try XCTUnwrap(first.string(1)), first.int(2))

        let removed = await store.deleteLineItemForUndo(lineItemId: id, receiptId: receipt)
        XCTAssertEqual(removed?.uuid, uuid)
        var tombstones = try await db.queryOne("SELECT COUNT(*) FROM sync_tombstones WHERE entity = 'line_item' AND uuid = ?", [.text(uuid)])?.int(0)
        XCTAssertEqual(tombstones, 1)
        var sum = try await db.queryOne("SELECT computed_sum FROM receipts WHERE id = ?", [.from(receipt)])?.double(0)
        XCTAssertEqual(sum, 2.0)

        await store.restoreDeletedLineItem(try XCTUnwrap(removed))
        let after = try await db.query("SELECT uuid, position, name_de, sync_state, updated_at FROM line_items WHERE receipt_id = ? ORDER BY position, id", [.from(receipt)])
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(after.first?.string(0), uuid, "same record")
        XCTAssertEqual(after.first?.int(1), position, "same place")
        XCTAssertEqual(after.first?.string(2), "Milch")
        XCTAssertEqual(after.first?.string(3), "dirty")
        XCTAssertNotNil(after.first?.string(4))
        tombstones = try await db.queryOne("SELECT COUNT(*) FROM sync_tombstones WHERE entity = 'line_item' AND uuid = ?", [.text(uuid)])?.int(0)
        XCTAssertEqual(tombstones, 0, "the unsent delete is withdrawn")
        sum = try await db.queryOne("SELECT computed_sum FROM receipts WHERE id = ?", [.from(receipt)])?.double(0)
        XCTAssertEqual(sum, 3.0, "the totals are derived again")
    }

    func testReviewReasonsCoverFlaggedUnreviewedOnly() async throws {
        let (flagged, _) = try await seedReceipt(store: "A")
        let (reviewed, _) = try await seedReceipt(store: "B")
        let (clean, _) = try await seedReceipt(store: "C")
        _ = try await store.db.run("UPDATE receipts SET needs_review = 1, review_reasons = ? WHERE id IN (?, ?)",
                                   [.text("[\"Possible duplicate of receipt #1\"]"), .from(flagged), .from(reviewed)])
        await store.markReviewed(id: reviewed)
        let reasons = await store.reviewReasonsByReceipt()
        XCTAssertEqual(reasons[flagged], ["Possible duplicate of receipt #1"])
        XCTAssertNil(reasons[reviewed])
        XCTAssertNil(reasons[clean])
    }

    func testConfirmAllLeavesReceiptsStillBeingReadAlone() async throws {
        let (finished, _) = try await seedReceipt(store: "A")
        let (reading, _) = try await seedReceipt(store: "B")
        let (failed, _) = try await seedReceipt(store: "C")
        _ = try await store.db.run("UPDATE receipts SET extraction_status = 'queued' WHERE id = ?", [.from(reading)])
        _ = try await store.db.run("UPDATE receipts SET extraction_status = 'failed' WHERE id = ?", [.from(failed)])
        await store.refreshList()
        XCTAssertEqual(store.confirmableWithoutFlagsCount, 1)
        await store.confirmAllFinishedWithoutFlags()
        XCTAssertNotNil(store.receipts.first { $0.id == finished }?.reviewedAt)
        XCTAssertNil(store.receipts.first { $0.id == reading }?.reviewedAt)
        XCTAssertNil(store.receipts.first { $0.id == failed }?.reviewedAt)
        XCTAssertEqual(store.confirmableWithoutFlagsCount, 0)
    }

    func testClearReceiptFiltersResetsEverything() {
        store.searchText = "milk"
        store.dateRange = .thisYear
        store.storeFilter = "Edeka"
        store.clearReceiptFilters()
        XCTAssertEqual(store.searchText, "")
        XCTAssertEqual(store.dateRange, .all)
        XCTAssertNil(store.storeFilter)
    }
}
