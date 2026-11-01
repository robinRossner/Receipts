import SQLite3
import XCTest
@testable import ReceiptsApp

/// A scripted classification model: answers the n-th call with the n-th response (the last one repeats) and records prompts.
final class ScriptedClassifier: ItemClassificationProvider, @unchecked Sendable {
    let id = "scripted"
    private let lock = NSLock()
    private var responses: [String]
    private(set) var prompts: [String] = []
    var calls: Int { lock.lock(); defer { lock.unlock() }; return prompts.count }

    init(_ responses: [String]) { self.responses = responses }

    func classify(prompt: String, schema: JSONSchema, maxOutputTokens: Int) async throws -> LLMResponse {
        lock.lock(); defer { lock.unlock() }
        prompts.append(prompt)
        let text = responses[min(prompts.count - 1, responses.count - 1)]
        return LLMResponse(text: text, providerId: id)
    }

    /// `{"items": [...]}` with one entry per tuple (index is the 1-based position).
    static func answer(_ items: [(path: Int, flag: Bool?, name: String, parent: String)]) -> String {
        let entries = items.enumerated().map { i, it -> String in
            var s = #"{"index": \#(i + 1), "translation_en": "thing \#(i + 1)", "path_number": \#(it.path)"#
            if let flag = it.flag { s += #", "no_good_match": \#(flag), "suggested_category": "\#(it.name)", "suggested_parent": "\#(it.parent)""# }
            return s + "}"
        }
        return #"{"items": [\#(entries.joined(separator: ","))]}"#
    }
}

final class FlaggedItemsTests: XCTestCase {
    private var dir: URL!
    private let taxonomy = Taxonomy.load()

    override func setUpWithError() throws { dir = try makeTempDir() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private var log: URL { dir.appendingPathComponent("classification_log.jsonl") }

    private func fallbackNumber() -> Int {
        taxonomy.numberedPrompt().indexMap.first { $0.value == ("Other", "Miscellaneous", "General") }!.key
    }
    private func number(_ p: Taxonomy.Path) -> Int {
        taxonomy.numberedPrompt().indexMap.first { $0.value == (p.category, p.subcategory, p.itemGroup) }!.key
    }

    private func resolve(_ db: Database, _ names: [String], _ provider: ScriptedClassifier) async throws -> [ItemDictionaryEntry] {
        try await ItemCategorizer.resolveItems(db: db, rawNames: names, taxonomy: taxonomy, storeName: "Fressnapf", logURL: log, provider: provider).entries
    }

    // MARK: - Parsing the model's answer

    func testFlaggedAnswerIsFiledUnderTheFallbackWithSuggestion() async throws {
        let db = try openTempDatabase(in: dir)
        let llm = ScriptedClassifier([ScriptedClassifier.answer([(fallbackNumber(), true, "Pet Food", "Household")])])
        let entries = try await resolve(db, ["Pedigree Hundefutter"], llm)
        let e = try XCTUnwrap(entries.first)
        XCTAssertTrue(e.categoryFlagged)
        XCTAssertEqual([e.category, e.subcategory, e.itemGroup], ["Other", "Miscellaneous", "General"], "a valid path, so Overview keeps working")
        XCTAssertTrue(e.needsReview, "also visible to clients that only know needs_review")
        XCTAssertEqual(e.suggestedCategory, "Pet Food")
        XCTAssertEqual(e.suggestedParent, "Household")
        XCTAssertTrue(taxonomy.contains(Taxonomy.Path(e.category, e.subcategory, e.itemGroup)))
        // persisted
        let row = try await db.queryOne("SELECT category_flagged, suggested_category, suggested_parent FROM item_dictionary WHERE id = ?", [.from(e.id)])
        XCTAssertEqual(row?.int(0), 1); XCTAssertEqual(row?.string(1), "Pet Food"); XCTAssertEqual(row?.string(2), "Household")
    }

    func testFlaggedWithInvalidPathNumberIsNotRetried() async throws {
        let db = try openTempDatabase(in: dir)
        let llm = ScriptedClassifier([ScriptedClassifier.answer([(99999, true, "Pet Food", "Household > Household Goods")])])
        let e = try await resolve(db, ["Pedigree Hundefutter"], llm).first!
        XCTAssertEqual(llm.calls, 1, "a flagged item needs no valid number and gets no second attempt")
        XCTAssertTrue(e.categoryFlagged)
        XCTAssertEqual(e.suggestedParent, "Household > Household Goods")
    }

    func testUnflaggedInvalidNumberStillRetriesAndFallsBackWithoutFlag() async throws {
        let db = try openTempDatabase(in: dir)
        let llm = ScriptedClassifier([ScriptedClassifier.answer([(99999, false, "", "")])])
        let e = try await resolve(db, ["Pedigree Hundefutter"], llm).first!
        XCTAssertEqual(llm.calls, 2)
        XCTAssertFalse(e.categoryFlagged)
        XCTAssertTrue(e.needsReview)
    }

    func testFlaggedWithoutUsableSuggestionIsStillFlagged() async throws {
        let db = try openTempDatabase(in: dir)
        let llm = ScriptedClassifier([ScriptedClassifier.answer([(fallbackNumber(), true, "", "")])])
        let e = try await resolve(db, ["Pedigree Hundefutter"], llm).first!
        XCTAssertTrue(e.categoryFlagged)
        XCTAssertNil(e.suggestedCategory); XCTAssertNil(e.suggestedParent)
    }

    func testSuggestionThatNamesAnExistingPathIsFiledThereNotFlagged() async throws {
        let db = try openTempDatabase(in: dir)
        let llm = ScriptedClassifier([ScriptedClassifier.answer([(fallbackNumber(), true, "legumes", "food > pantry")])])
        let e = try await resolve(db, ["Pedigree Hundefutter"], llm).first!
        XCTAssertFalse(e.categoryFlagged)
        XCTAssertEqual([e.category, e.subcategory, e.itemGroup], ["Food", "Pantry", "Legumes"])
        XCTAssertNil(e.suggestedCategory)
    }

    func testOldShapedAnswersWithoutTheNewKeysAreNeverFlagged() async throws {
        let db = try openTempDatabase(in: dir)
        let legumes = number(Taxonomy.Path("Food", "Pantry", "Legumes"))
        let llm = ScriptedClassifier([ScriptedClassifier.answer([(legumes, nil, "", "")])])
        let e = try await resolve(db, ["Pedigree Hundefutter"], llm).first!
        XCTAssertFalse(e.categoryFlagged)
        XCTAssertEqual(e.itemGroup, "Legumes")
        let flat = ScriptedClassifier([#"{"translation_en": "x", "path_number": \#(legumes)}"#])
        let f = try await resolve(db, ["Hundekuchen"], flat).first!
        XCTAssertFalse(f.categoryFlagged)
    }

    func testBooleanCoercion() {
        XCTAssertTrue(ItemCategorizer.coerceBool(true)); XCTAssertTrue(ItemCategorizer.coerceBool("true"))
        XCTAssertTrue(ItemCategorizer.coerceBool(1)); XCTAssertTrue(ItemCategorizer.coerceBool(" TRUE "))
        XCTAssertFalse(ItemCategorizer.coerceBool(false)); XCTAssertFalse(ItemCategorizer.coerceBool("no"))
        XCTAssertFalse(ItemCategorizer.coerceBool(nil)); XCTAssertFalse(ItemCategorizer.coerceBool(0))
    }

    func testSuggestionSanitising() {
        let s = ItemCategorizer.sanitizeSuggestion(category: "  \"Pet   Food\" ", parent: "household > HOUSEHOLD goods", taxonomy: taxonomy)
        XCTAssertEqual(s.category, "Pet Food"); XCTAssertEqual(s.parent, "Household > Household Goods"); XCTAssertNil(s.existing)
        // a leaf with ">" is unusable, a parent with three parts or an empty part is unusable
        XCTAssertNil(ItemCategorizer.sanitizeSuggestion(category: "A > B", parent: "Household", taxonomy: taxonomy).category)
        XCTAssertNil(ItemCategorizer.sanitizeSuggestion(category: "Pet Food", parent: "A > B > C", taxonomy: taxonomy).parent)
        XCTAssertNil(ItemCategorizer.sanitizeSuggestion(category: "Pet Food", parent: "Household > ", taxonomy: taxonomy).parent)
        XCTAssertNil(ItemCategorizer.sanitizeSuggestion(category: "Pet Food", parent: nil, taxonomy: taxonomy).parent)
        // truncated to 60
        let long = ItemCategorizer.sanitizeSuggestion(category: String(repeating: "x", count: 80), parent: "Household", taxonomy: taxonomy)
        XCTAssertEqual(long.category?.count, 60)
        // one-part parent: leaf is a new subcategory under it with item group "General"
        XCTAssertEqual(FlaggedItems.path(suggestedCategory: "Pets", suggestedParent: "Household"), Taxonomy.Path("Household", "Pets", "General"))
        XCTAssertEqual(FlaggedItems.path(suggestedCategory: "Pet Food", suggestedParent: "Household > Pets"), Taxonomy.Path("Household", "Pets", "Pet Food"))
        XCTAssertNil(FlaggedItems.path(suggestedCategory: nil, suggestedParent: "Household"))
    }

    func testPromptAndSchemaCarryTheFlagGuidance() async throws {
        let db = try openTempDatabase(in: dir)
        let llm = ScriptedClassifier([ScriptedClassifier.answer([(fallbackNumber(), false, "", "")])])
        _ = try await resolve(db, ["Pedigree Hundefutter"], llm)
        let prompt = llm.prompts[0]
        XCTAssertTrue(prompt.contains("no_good_match"))
        XCTAssertTrue(prompt.contains("Flagging is rare"))
        XCTAssertTrue(prompt.contains("a merely imperfect fit is NOT a reason to flag"))
        XCTAssertTrue(prompt.contains("do NOT flag it"))
        let schema = ItemCategorizer.classificationSchema(itemCount: 2, pathNumbers: [1, 2])
        let entry = ((schema.root["properties"] as? [String: Any])?["items"] as? [String: Any])?["items"] as? [String: Any]
        XCTAssertEqual(entry?["required"] as? [String], ["index", "translation_en", "path_number", "no_good_match", "suggested_category", "suggested_parent"])
    }

    // MARK: - The dictionary must not cement a poor match

    func testExactHitOnAFlaggedEntrySkipsTheModelAndKeepsTheFlag() async throws {
        let db = try openTempDatabase(in: dir)
        let llm = ScriptedClassifier([ScriptedClassifier.answer([(fallbackNumber(), true, "Pet Food", "Household")])])
        let first = try await resolve(db, ["Pedigree Hundefutter"], llm).first!
        let again = try await resolve(db, ["PEDIGREE Hundefutter 85g"], llm).first!
        XCTAssertEqual(llm.calls, 1, "same normalised name: no new call")
        XCTAssertEqual(again.id, first.id)
        XCTAssertTrue(again.categoryFlagged)
    }

    func testFuzzyLookAlikeDoesNotInheritAFlaggedEntry() async throws {
        let db = try openTempDatabase(in: dir)
        let legumes = number(Taxonomy.Path("Food", "Pantry", "Legumes"))
        let llm = ScriptedClassifier([
            ScriptedClassifier.answer([(fallbackNumber(), true, "Pet Food", "Household")]),
            ScriptedClassifier.answer([(legumes, false, "", "")]),
        ])
        let flagged = try await resolve(db, ["Pedigree Hundefutter"], llm).first!
        // fuzzy score is >= 90 against the flagged name, but the flagged entry is not a candidate
        let near = try await resolve(db, ["Pedigree Hundefutte"], llm).first!
        XCTAssertEqual(llm.calls, 2, "the look-alike is classified on its own")
        XCTAssertNotEqual(near.id, flagged.id)
        XCTAssertFalse(near.categoryFlagged)
        XCTAssertEqual(near.itemGroup, "Legumes")
        let aliases = try await db.queryOne("SELECT aliases FROM item_dictionary WHERE id = ?", [.from(flagged.id)])?.string(0)
        XCTAssertFalse(aliases?.contains("hundefutte\"") ?? false, "no alias was added to the flagged entry")
    }

    func testKeywordRuleItemsSkipTheModelAndAreNeverFlagged() async throws {
        let db = try openTempDatabase(in: dir)
        let llm = ScriptedClassifier([ScriptedClassifier.answer([(fallbackNumber(), true, "X", "Household")])])
        let e = try await resolve(db, ["Haferflocken zart"], llm).first!
        XCTAssertEqual(llm.calls, 0)
        XCTAssertFalse(e.categoryFlagged)
        XCTAssertEqual(e.itemGroup, "Cereals & Muesli")
    }

    // MARK: - Migration of an existing database

    private func rawLegacy(version7: Bool) throws {
        let path = dir.appendingPathComponent("receipts.db").path
        try LegacyDB.create(at: path, LegacyDB.populateSample)
        if version7 {
            var raw: OpaquePointer?
            XCTAssertEqual(sqlite3_open(path, &raw), SQLITE_OK)
            defer { sqlite3_close(raw) }
            let c = SQLConnection(handle: raw)
            try SyncSchema.apply(c)           // exactly what migration 7 does
            try c.run("PRAGMA user_version = 7")
        }
    }

    func testMigrationFromAVersion6DatabaseIsAdditive() async throws {
        try rawLegacy(version7: false)
        let db = try openTempDatabase(in: dir)
        let version = try await db.scalarInt("PRAGMA user_version")
        XCTAssertEqual(version, Database.latestSchemaVersion)
        XCTAssertGreaterThanOrEqual(Database.latestSchemaVersion, 8)
        let rows = try await db.query("SELECT id, canonical_name, category, subcategory, item_group, is_manual_override, category_flagged, suggested_category, suggested_parent FROM item_dictionary ORDER BY id")
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map { $0.string(1) }, ["bio eier", "milch", "pfand"], "existing rows untouched")
        XCTAssertEqual(rows[0].string(4), "Eggs"); XCTAssertTrue(rows[0].bool(5))
        for r in rows { XCTAssertFalse(r.bool(6)); XCTAssertNil(r.string(7)); XCTAssertNil(r.string(8)) }
        let additions = try await db.scalarInt("SELECT COUNT(*) FROM taxonomy_additions")
        XCTAssertEqual(additions, 0)
        let items = try await db.scalarInt("SELECT COUNT(*) FROM line_items"), receipts = try await db.scalarInt("SELECT COUNT(*) FROM receipts")
        XCTAssertEqual(items, 6); XCTAssertEqual(receipts, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("receipts.db.bak-v6").path), "a backup copy is made before migrating")
    }

    func testMigrationFromAVersion7DatabaseOnlyAddsTheNewParts() async throws {
        try rawLegacy(version7: true)
        let before = try openRaw()
        XCTAssertEqual(before.userVersion, 7)
        let db = try openTempDatabase(in: dir)
        let version = try await db.scalarInt("PRAGMA user_version")
        XCTAssertEqual(version, Database.latestSchemaVersion)
        let milch = try await db.queryOne("SELECT uuid, category_flagged, sync_state FROM item_dictionary WHERE canonical_name = 'milch'")
        XCTAssertEqual(milch?.string(0), LegacyIDs.uuid(.dictionary, 2), "sync identity untouched")
        XCTAssertEqual(milch?.int(1), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("receipts.db.bak-v7").path))
    }

    private func openRaw() throws -> (userVersion: Int32, ()) {
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dir.appendingPathComponent("receipts.db").path, &raw), SQLITE_OK)
        defer { sqlite3_close(raw) }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(raw, "PRAGMA user_version", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        _ = sqlite3_step(stmt)
        return (sqlite3_column_int(stmt, 0), ())
    }

    func testFlagOnlyChangeMarksTheEntryForPush() async throws {
        let db = try openTempDatabase(in: dir)
        let llm = ScriptedClassifier([ScriptedClassifier.answer([(fallbackNumber(), true, "Pet Food", "Household")])])
        let e = try await resolve(db, ["Pedigree Hundefutter"], llm).first!
        try await db.run("UPDATE item_dictionary SET sync_state = 'synced', updated_at = '2020-01-01T00:00:00.000Z' WHERE id = ?", [.from(e.id)])
        try await db.run("UPDATE item_dictionary SET category_flagged = 0 WHERE id = ?", [.from(e.id)])
        let row = try await db.queryOne("SELECT sync_state, updated_at FROM item_dictionary WHERE id = ?", [.from(e.id)])
        XCTAssertEqual(row?.string(0), "dirty")
        XCTAssertNotEqual(row?.string(1), "2020-01-01T00:00:00.000Z")
    }
}
