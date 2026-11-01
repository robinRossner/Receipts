import XCTest
@testable import ReceiptsApp

/// What the "Items without a category" screen shows and decides, the chart series for any category name, and what
/// confirming a receipt does next (both apps).
@MainActor
final class FlagReviewLogicTests: XCTestCase {
    private var dir: URL!
    private var store: ReceiptStore!
    private let taxonomy = Taxonomy.load()

    override func setUpWithError() throws {
        dir = try makeTempDir()
        let base = dir.appendingPathComponent("data", isDirectory: true)
        let env = AppEnvironment.make(baseDir: base)
        let db = try Database(path: env.dbPath, dataDir: base)
        store = ReceiptStore(env: env, db: db, taxonomy: taxonomy, capabilities: .mobile, deviceId: "iphone-test", reminders: NoReminders())
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    // MARK: Draft of a new category

    func testDraftStartsFromTheSuggestionAndTrims() {
        var draft = FlagPathDraft(Taxonomy.Path("Household", "Pets", "Pet Food"))
        XCTAssertEqual(draft.path, Taxonomy.Path("Household", "Pets", "Pet Food"))
        draft.itemGroup = "  Dog Food "
        XCTAssertEqual(draft.path.itemGroup, "Dog Food")
        XCTAssertTrue(FlagPathDraft(nil).isEmpty)
    }

    func testDraftStatusSaysNewExistingOrInvalid() {
        XCTAssertEqual(FlagPathDraft(Taxonomy.Path("Household", "Pets", "Pet Food")).status(in: taxonomy), .new)
        XCTAssertEqual(FlagPathDraft(Taxonomy.Path("food", "dairy & eggs", "MILK")).status(in: taxonomy), .existing, "case does not matter")
        guard case .invalid = FlagPathDraft(Taxonomy.Path("Household", "Pets", "Pet > Food")).status(in: taxonomy) else { return XCTFail("a > is refused") }
        guard case .invalid = FlagPathDraft(nil).status(in: taxonomy) else { return XCTFail("empty is refused") }
    }

    func testAddedCategoryShowsInEveryPickerLevel() {
        let merged = taxonomy.adding([Taxonomy.Path("Pets & Animals", "Dogs", "Food")])
        XCTAssertTrue(merged.categoryNames().contains("Pets & Animals"))
        XCTAssertEqual(merged.subcategoryNames(in: "Pets & Animals"), ["Dogs"])
        XCTAssertEqual(merged.itemGroups(category: "Pets & Animals", subcategory: "Dogs"), ["Food"])
    }

    // MARK: Texts

    func testTexts() {
        XCTAssertEqual(FlaggedText.usage(count: 1, spend: 2.5), "1 purchase · €2.50")
        XCTAssertEqual(FlaggedText.usage(count: 3, spend: 12), "3 purchases · €12.00")
        let path = Taxonomy.Path("A", "B", "C")
        XCTAssertEqual(FlaggedText.filed(count: 1, under: path), "Filed 1 item under A > B > C.")
        XCTAssertEqual(FlaggedText.filed(count: 2, under: path), "Filed 2 items under A > B > C.")
        XCTAssertEqual(FlaggedText.mark(suggested: "Pet Food"), "No good category. Suggested: Pet Food")
        XCTAssertEqual(FlaggedText.mark(suggested: nil), "No good category")
        let receipts = [ReceiptSummary(id: 7, store: "ALDI", date: "2026-03-01", time: nil, total: nil, needsReview: false, reviewedAt: nil, processing: nil)]
        XCTAssertEqual(FlaggedText.receiptLabel(id: 7, in: receipts), "ALDI · 2026-03-01")
        XCTAssertEqual(FlaggedText.receiptLabel(id: 8, in: receipts), "Receipt #8")
    }

    // MARK: Chart series

    private func month(_ m: String, _ c: String, _ t: Double) -> MonthCategoryTotal { MonthCategoryTotal(month: m, category: c, total: t) }

    func testAnAddedCategoryGetsItsOwnSeries() {
        let monthly = [month("2026-03", "Food", 10), month("2026-03", "Pets & Animals", 4)]
        XCTAssertEqual(SpendingSeries.names(monthly), ["Food", "Pets & Animals"])
        XCTAssertEqual(Set(SpendingSeries.bars(monthly).map(\.category)), ["Food", "Pets & Animals"])
    }

    func testEveryBarIsInTheColourDomainWhateverTheName() {
        // A "|" is allowed in an added name: it must not cut the name (a bar outside the domain draws without a colour).
        let monthly = [month("2026-03", "Food | Drink", 10), month("2026-04", "Food | Drink", 5), month("2026-04", "Hobby", 1)]
        let names = Set(SpendingSeries.names(monthly))
        let bars = SpendingSeries.bars(monthly)
        XCTAssertEqual(bars.count, 3)
        for bar in bars { XCTAssertTrue(names.contains(bar.category), bar.category) }
        XCTAssertEqual(bars.first?.category, "Food | Drink")
    }

    func testBeyondFiveCategoriesTheRestFoldIntoOther() {
        let monthly = (1...7).map { month("2026-03", "C\($0)", Double($0)) } + [month("2026-03", "Other", 1)]
        XCTAssertEqual(SpendingSeries.names(monthly), ["C7", "C6", "C5", "C4", "C3", "Other"])
        let other = SpendingSeries.bars(monthly).first { $0.category == "Other" }
        XCTAssertEqual(other?.total, 1 + 2 + 1, "C1, C2 and Other itself")
    }

    func testEqualTotalsKeepAStableOrder() {
        let monthly = [month("2026-03", "B", 1), month("2026-03", "A", 1)]
        XCTAssertEqual(SpendingSeries.names(monthly), ["A", "B"])
    }

    // MARK: Confirming on the Mac

    private func addReceipt(_ name: String, status: String? = nil) async throws -> Int {
        Int(try await store.db.run(
            "INSERT INTO receipts (store, date, total, computed_sum, needs_review, review_reasons, created_at, extraction_status) VALUES (?, '2026-10-30', 3, 3, 0, '[]', '2026-10-30', ?)",
            [.text(name), .from(status)]
        ))
    }

    func testLooksGoodMovesToTheNextFinishedReceiptAndSkipsOnesStillBeingRead() async throws {
        let first = try await addReceipt("A")
        _ = try await addReceipt("B", status: "queued")
        let third = try await addReceipt("C")
        await store.refreshList()
        await store.confirmReceipt(id: third)
        XCTAssertEqual(store.selectedReceiptID, first, "the queued one is passed over")
        XCTAssertNotNil(store.receipts.first { $0.id == third }?.reviewedAt)
    }

    func testLooksGoodStaysPutWithNothingLeft() async throws {
        let only = try await addReceipt("A")
        _ = try await addReceipt("B", status: "failed")
        await store.refreshList()
        await store.confirmReceipt(id: only)
        XCTAssertEqual(store.selectedReceiptID, only)
        XCTAssertNotNil(store.selectedReceipt?.reviewedAt)
    }
}
