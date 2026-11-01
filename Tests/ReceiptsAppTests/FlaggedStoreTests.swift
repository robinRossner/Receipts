import XCTest
@testable import ReceiptsApp

// `await` cannot sit inside XCTAssert autoclosures: these take the already-awaited value.
private func unwrapped<T>(_ v: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T { try XCTUnwrap(v, file: file, line: line) }
private func eq<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { XCTAssertEqual(a, b, message, file: file, line: line) }
private func isTrue(_ b: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(b, message, file: file, line: line) }

/// The store APIs for flagged items, resolution, Overview totals and the sync round trip (fake server).
@MainActor
final class FlaggedStoreTests: XCTestCase {
    private var dir: URL!
    private let taxonomy = Taxonomy.load()
    private let pets = Taxonomy.Path("Household", "Pets", "Pet Food")

    override func setUpWithError() throws { dir = try makeTempDir() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private var log: URL { dir.appendingPathComponent("classification_log.jsonl") }
    private func fallbackNumber() -> Int {
        taxonomy.numberedPrompt().indexMap.first { $0.value == ("Other", "Miscellaneous", "General") }!.key
    }

    private func makeStore() throws -> (ReceiptStore, Database) {
        let base = dir.appendingPathComponent("data", isDirectory: true)
        let env = AppEnvironment.make(baseDir: base)
        let db = try Database(path: env.dbPath, dataDir: base)
        return (ReceiptStore(env: env, db: db, taxonomy: taxonomy, capabilities: .mobile, deviceId: "iphone-test", reminders: NoReminders()), db)
    }

    /// A receipt with one line per (name, price) classified by `answers` ((flag?, name, parent) per name; nil = valid normal answer).
    @discardableResult
    private func addReceipt(_ db: Database, date: String = "2026-03-01", items: [(String, Double)],
                            flags: [(name: String, parent: String)?], deleted: Bool = false) async throws -> Int {
        let normal = taxonomy.numberedPrompt().indexMap.first { $0.value == ("Food", "Pantry", "Legumes") }!.key
        let json = ScriptedClassifier.answer(flags.map { f in
            f.map { (fallbackNumber(), true as Bool?, $0.name, $0.parent) } ?? (normal, false as Bool?, "", "")
        })
        let llm = ScriptedClassifier([json])
        let entries = try await ItemCategorizer.resolveItems(db: db, rawNames: items.map(\.0), taxonomy: taxonomy, storeName: "Fressnapf", logURL: log, provider: llm).entries
        let total = items.reduce(0) { $0 + $1.1 }
        let receiptId = Int(try await db.run("INSERT INTO receipts (store, date, total, computed_sum, created_at, deleted_at) VALUES ('Fressnapf', ?, ?, ?, ?, ?)",
                                             [.text(date), .from(total), .from(total), .text("\(date)T10:00:00Z"), deleted ? .text("2026-04-01T00:00:00Z") : .null]))
        for (entry, item) in zip(entries, items) {
            try await db.run("INSERT INTO line_items (receipt_id, item_dictionary_id, raw_text, name_de, quantity, unit_price, total_price) VALUES (?, ?, ?, ?, 1, ?, ?)",
                             [.from(receiptId), .from(entry.id), .text(item.0), .text(item.0), .from(item.1), .from(item.1)])
        }
        return receiptId
    }

    // MARK: - Listing

    func testListGroupsAndCountOnlyLiveFlaggedItems() async throws {
        let (store, db) = try makeStore()
        try await addReceipt(db, items: [("Pedigree Hundefutter", 2.5), ("Kerrygold Butter", 1.5), ("Felix Katzennahrung", 1.0)],
                             flags: [("Pet Food", "Household"), nil, ("pet food", "household")])
        try await addReceipt(db, date: "2026-03-05", items: [("Trixie Kauknochen", 4.0)], flags: [("Dog Toys", "Household > Pets")])
        try await addReceipt(db, date: "2026-03-06", items: [("Schleich Pferd", 9.0)], flags: [("Toys", "Other")], deleted: true)
        try await addReceipt(db, date: "2026-03-07", items: [("Ratgeber Heft", 3.0)], flags: [("", "")])   // flagged, no suggestion

        await store.refreshFlaggedCount()
        XCTAssertEqual(store.flaggedItemCount, 4, "the item only on a deleted receipt does not count")
        let items = await store.flaggedItems()
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items.first { $0.name == "Pedigree Hundefutter" }?.totalSpend, 2.5)
        XCTAssertEqual(items.first { $0.name == "Pedigree Hundefutter" }?.itemCount, 1)
        XCTAssertEqual(items.first { $0.name == "Pedigree Hundefutter" }?.receiptIds.count, 1)

        let groups = await store.flaggedGroups()
        XCTAssertEqual(groups.count, 3, "case-insensitive: Pet Food / pet food are one group; no-suggestion is its own")
        let petGroup = try XCTUnwrap(groups.first { $0.suggestedPath == Taxonomy.Path("Household", "Pet Food", "General") })
        XCTAssertEqual(petGroup.items.count, 2); XCTAssertEqual(petGroup.itemCount, 2); XCTAssertEqual(petGroup.totalSpend, 3.5)
        XCTAssertEqual(groups.last?.id, "", "items without a suggestion come last")
        XCTAssertEqual(groups.last?.items.first?.name, "Ratgeber Heft")
    }

    // MARK: - Resolving

    func testResolveWithAnExistingCategoryClearsTheFlagAndFilesTheItem() async throws {
        let (store, db) = try makeStore()
        try await addReceipt(db, items: [("Pedigree Hundefutter", 2.5)], flags: [("Pet Food", "Household")])
        let item = try unwrapped(await store.flaggedItems().first)
        let result = await store.resolveFlaggedItems([item.id], to: Taxonomy.Path("Household", "Household Goods", "Household Goods & Batteries"))
        XCTAssertEqual(result, .resolved(count: 1))
        let row = try await db.queryOne("SELECT category, subcategory, item_group, category_flagged, suggested_category, suggested_parent, is_manual_override, needs_review, sync_state FROM item_dictionary WHERE id = ?", [.from(item.id)])
        XCTAssertEqual(row?.string(0), "Household"); XCTAssertEqual(row?.string(2), "Household Goods & Batteries")
        XCTAssertEqual(row?.int(3), 0); XCTAssertNil(row?.string(4)); XCTAssertNil(row?.string(5))
        XCTAssertEqual(row?.int(6), 1, "manual override: extraction never changes it again")
        XCTAssertEqual(row?.int(7), 0)
        XCTAssertEqual(row?.string(8), "dirty", "the resolution syncs")
        XCTAssertEqual(store.flaggedItemCount, 0)
        let again = await store.resolveFlaggedItems([item.id], to: Taxonomy.fallback)
        XCTAssertEqual(again, .resolved(count: 0), "not flagged any more: nothing changes")
    }

    func testResolveToAPathThatIsNotInTheTaxonomyIsRefused() async throws {
        let (store, db) = try makeStore()
        try await addReceipt(db, items: [("Pedigree Hundefutter", 2.5)], flags: [("Pet Food", "Household")])
        let item = try unwrapped(await store.flaggedItems().first)
        let result = await store.resolveFlaggedItems([item.id], to: pets)
        guard case .invalid = result else { return XCTFail("\(result)") }
        let flagged = try await db.scalarInt("SELECT category_flagged FROM item_dictionary WHERE id = ?", [.from(item.id)])
        XCTAssertEqual(flagged, 1)
    }

    func testResolveByAddingTheSuggestedCategoryExtendsTheTaxonomyAndResolvesTheGroup() async throws {
        let (store, db) = try makeStore()
        try await addReceipt(db, items: [("Pedigree Hundefutter", 2.5), ("Felix Katzennahrung", 1.0)],
                             flags: [("Pet Food", "Household > Pets"), ("Pet Food", "household > pets")])
        let group = try unwrapped(await store.flaggedGroups().first)
        XCTAssertEqual(group.suggestedPath, pets)
        XCTAssertFalse(store.taxonomy.contains(pets))

        let result = await store.resolveFlaggedItems(group.dictionaryIds, addingCategory: try XCTUnwrap(group.suggestedPath))
        XCTAssertEqual(result, .resolved(count: 2))
        XCTAssertTrue(store.taxonomy.contains(pets), "pickers and the categoriser see it now")
        XCTAssertEqual(store.taxonomy.itemGroups(category: "Household", subcategory: "Pets"), ["Pet Food"])
        XCTAssertTrue(store.taxonomy.numberedPrompt().text.contains("Household > Pets > Pet Food"), "later items can be filed there")
        let add = try await db.query("SELECT category, subcategory, item_group, sync_state FROM taxonomy_additions")
        XCTAssertEqual(add.count, 1); XCTAssertEqual(add[0].string(3), "dirty")
        let filed = try await db.scalarInt("SELECT COUNT(*) FROM item_dictionary WHERE category = 'Household' AND subcategory = 'Pets' AND item_group = 'Pet Food' AND category_flagged = 0")
        XCTAssertEqual(filed, 2)
        // adding the same path again (other case) is a no-op, an existing category keeps its spelling
        let dup = await store.addTaxonomyPath(Taxonomy.Path("household", "pets", "pet food"))
        XCTAssertEqual(dup, .resolved(count: 0))
        let extra = await store.addTaxonomyPath(Taxonomy.Path("household", "PETS", "Cat Litter"))
        XCTAssertEqual(extra, .resolved(count: 1))
        XCTAssertEqual(store.taxonomy.itemGroups(category: "Household", subcategory: "Pets"), ["Pet Food", "Cat Litter"])
        // the additions survive a restart (reloaded from the database)
        let (store2, _) = (ReceiptStore(env: store.env, db: db, taxonomy: taxonomy, capabilities: .mobile, deviceId: "iphone-test", reminders: NoReminders()), db)
        await store2.reloadTaxonomy()
        XCTAssertTrue(store2.taxonomy.contains(pets))
    }

    func testInvalidCategoryNamesAreRefused() async throws {
        let (store, _) = try makeStore()
        for bad in [Taxonomy.Path("", "Pets", "Pet Food"), Taxonomy.Path("Household", "A > B", "x"), Taxonomy.Path("Household", "Pets", String(repeating: "x", count: 61))] {
            let r = await store.addTaxonomyPath(bad)
            guard case .invalid = r else { return XCTFail("\(bad.label): \(r)") }
        }
        let r = await store.resolveFlaggedItems([1], addingCategory: Taxonomy.Path("Household", "Pets", "  "))
        guard case .invalid = r else { return XCTFail("\(r)") }
    }

    func testEditingTheCategoryThroughTheNormalPathClearsTheFlag() async throws {
        let (store, db) = try makeStore()
        let rid = try await addReceipt(db, items: [("Pedigree Hundefutter", 2.5)], flags: [("Pet Food", "Household")])
        let item = try unwrapped(await store.flaggedItems().first)
        await store.correctItem(itemDictionaryId: item.id, category: "Household", subcategory: "Cleaning", itemGroup: "Laundry", translationEn: nil, forReceipt: rid)
        XCTAssertEqual(store.flaggedItemCount, 0)
        let row = try await db.queryOne("SELECT category_flagged, suggested_category, suggested_parent FROM item_dictionary WHERE id = ?", [.from(item.id)])
        XCTAssertEqual(row?.int(0), 0); XCTAssertNil(row?.string(1)); XCTAssertNil(row?.string(2))
    }

    // The dictionary editor is Mac only (ReceiptStore+Data.swift is not in the iPhone app).
    #if os(macOS)
    func testEditingTheCategoryInTheDictionaryEditorClearsTheFlag() async throws {
        let (store, db) = try makeStore()
        try await addReceipt(db, date: "2026-03-09", items: [("Trixie Kauknochen", 4.0)], flags: [("Dog Chews", "Household")])
        let other = try unwrapped(await store.flaggedItems().first)
        var row2 = try unwrapped(await store.dictionaryRows().first { $0.id == other.id })
        row2.category = "Household"; row2.subcategory = "Cleaning"; row2.itemGroup = "Laundry"
        await store.updateDictionaryEntry(row2)
        let left = await store.flaggedItems()
        XCTAssertTrue(left.isEmpty)
    }
    #endif

    // MARK: - Overview

    func testOverviewTotalsStayCorrectWhileFlaggedAndAfterResolving() async throws {
        let (store, db) = try makeStore()
        try await addReceipt(db, items: [("Pedigree Hundefutter", 2.5), ("Kerrygold Butter", 1.5)], flags: [("Pet Food", "Household > Pets"), nil])
        let before = await store.statsSummary(start: nil, end: nil)
        XCTAssertEqual(before.total, 4.0, accuracy: 0.001)
        let other = try XCTUnwrap(before.categories.first { $0.category == "Other" })
        XCTAssertEqual(other.total, 2.5, accuracy: 0.001, "a flagged item counts under Other > Miscellaneous > General")
        XCTAssertEqual(other.subcategories.first?.itemGroups.first?.itemGroup, "General")

        let item = try unwrapped(await store.flaggedItems().first)
        _ = await store.resolveFlaggedItems([item.id], addingCategory: pets)
        let after = await store.statsSummary(start: nil, end: nil)
        XCTAssertEqual(after.total, 4.0, accuracy: 0.001, "same money, filed elsewhere")
        XCTAssertNil(after.categories.first { $0.category == "Other" })
        XCTAssertEqual(after.categories.first { $0.category == "Household" }?.subcategories.first?.subcategory, "Pets")
    }

    // MARK: - Sync

    private func twoDevices() throws -> (a: SyncHarness, b: SyncHarness, server: FakeReceiptsServer) {
        let server = FakeReceiptsServer()
        return (try SyncHarness(server: server), try SyncHarness(server: server, capabilities: .mobile, deviceId: "iphone-test"), server)
    }

    private func seedFlaggedLocally(_ h: SyncHarness) async throws -> Int {
        let llm = ScriptedClassifier([ScriptedClassifier.answer([(fallbackNumber(), true, "Pet Food", "Household > Pets")])])
        let e = try await ItemCategorizer.resolveItems(db: h.db, rawNames: ["Pedigree Hundefutter"], taxonomy: taxonomy, storeName: nil, logURL: log, provider: llm).entries[0]
        return e.id
    }

    func testFlagAndResolutionRoundTripBetweenDevicesThroughTheServer() async throws {
        let (a, b, server) = try twoDevices()
        let id = try await seedFlaggedLocally(a)
        var report = await a.engine.syncNow()
        XCTAssertTrue(report.succeeded, "\(report.errors)")
        let onServer = try XCTUnwrap(server.dictionary.values.first)
        XCTAssertEqual(onServer.categoryFlagged, true)
        XCTAssertEqual(onServer.suggestedCategory, "Pet Food"); XCTAssertEqual(onServer.suggestedParent, "Household > Pets")

        // device B receives the flag
        report = await b.engine.syncNow()
        XCTAssertTrue(report.succeeded, "\(report.errors)")
        let seen = try await b.row("SELECT category_flagged, suggested_category, suggested_parent, category FROM item_dictionary")
        XCTAssertEqual(seen?.int(0), 1); XCTAssertEqual(seen?.string(1), "Pet Food"); XCTAssertEqual(seen?.string(2), "Household > Pets")
        XCTAssertEqual(seen?.string(3), "Other")

        // B adds the category and resolves; the server gets the path and the resolved entry
        let bid = try unwrapped(try await b.row("SELECT id FROM item_dictionary")?.int(0))
        isTrue(try await FlaggedItems.addPath(db: b.db, pets))
        eq(try await FlaggedItems.resolve(db: b.db, dictionaryIds: [bid], to: pets), 1)
        report = await b.engine.syncNow()
        XCTAssertTrue(report.succeeded, "\(report.errors)")
        XCTAssertEqual(server.taxonomyAdditions.map(\.label), ["Household > Pets > Pet Food"])
        let resolved = try XCTUnwrap(server.dictionary.values.first)
        XCTAssertEqual(resolved.categoryFlagged, false)
        XCTAssertNil(resolved.suggestedCategory); XCTAssertNil(resolved.suggestedParent)
        XCTAssertEqual(resolved.itemGroup, "Pet Food"); XCTAssertTrue(resolved.isManualOverride)
        eq(try await b.row("SELECT sync_state FROM taxonomy_additions")?.string(0), "synced")
        let addIndex = server.pushLog.firstIndex { !($0.taxonomyAdditions ?? []).isEmpty }
        let dictIndex = server.pushLog.lastIndex { !$0.dictionary.isEmpty }
        XCTAssertNotNil(addIndex)
        XCTAssertLessThan(try XCTUnwrap(addIndex), try XCTUnwrap(dictIndex), "the new path is pushed before the entry that uses it")

        // A receives the resolution and the new category
        report = await a.engine.syncNow()
        XCTAssertTrue(report.succeeded, "\(report.errors)")
        let back = try await a.row("SELECT category_flagged, suggested_category, item_group FROM item_dictionary WHERE id = ?", [.from(id)])
        XCTAssertEqual(back?.int(0), 0); XCTAssertNil(back?.string(1)); XCTAssertEqual(back?.string(2), "Pet Food")
        let adds = try await FlaggedItems.additions(db: a.db)
        XCTAssertEqual(adds, [pets])
        eq(try await a.row("SELECT sync_state FROM taxonomy_additions")?.string(0), "synced")
    }

    func testPulledRecordFromAnOlderServerKeepsTheLocalFlagUnlessTheCategoryChanged() async throws {
        let server = FakeReceiptsServer()
        server.legacyServer = true
        let h = try SyncHarness(server: server)
        let id = try await seedFlaggedLocally(h)
        var report = await h.engine.syncNow()
        XCTAssertTrue(report.succeeded, "\(report.errors)")
        eq(try await h.row("SELECT category_flagged FROM item_dictionary WHERE id = ?", [.from(id)])?.int(0), 1)

        // another (old) client changes only the translation: the server sends the record without the flag keys
        var entry = try XCTUnwrap(server.dictionary.values.first)
        entry.translationEn = "dog food"; entry.updatedAt = SyncDate.now(); entry.categoryFlagged = nil
        server.seedDictionary(entry)
        report = await h.engine.syncNow()
        XCTAssertTrue(report.succeeded, "\(report.errors)")
        let kept = try await h.row("SELECT translation_en, category_flagged, suggested_category FROM item_dictionary WHERE id = ?", [.from(id)])
        XCTAssertEqual(kept?.string(0), "dog food")
        XCTAssertEqual(kept?.int(1), 1, "the server did not say anything about the flag: ours stays")
        XCTAssertEqual(kept?.string(2), "Pet Food")

        // an old client picks a category: the flag is resolved
        entry.category = "Household"; entry.subcategory = "Cleaning"; entry.itemGroup = "Laundry"; entry.updatedAt = SyncDate.now()
        server.seedDictionary(entry)
        report = await h.engine.syncNow()
        XCTAssertTrue(report.succeeded, "\(report.errors)")
        let resolved = try await h.row("SELECT category_flagged, suggested_category, suggested_parent, item_group FROM item_dictionary WHERE id = ?", [.from(id)])
        XCTAssertEqual(resolved?.int(0), 0); XCTAssertNil(resolved?.string(1)); XCTAssertNil(resolved?.string(2)); XCTAssertEqual(resolved?.string(3), "Laundry")
    }

    func testAnAdditionAgainstAnOlderServerStaysQueuedUntilItIsAcknowledged() async throws {
        let server = FakeReceiptsServer()
        server.legacyServer = true
        let h = try SyncHarness(server: server)
        isTrue(try await FlaggedItems.addPath(db: h.db, pets))
        // a legacy server answers with no result for it (it ignores the key): nothing is lost, the path stays dirty
        let batch = try await h.store.collectPush(.taxonomyAddition)
        XCTAssertEqual(batch.taxonomyAdditions.map(\.label), ["Household > Pets > Pet Food"])
        let summary = try await h.store.applyPushResults(batch: batch, response: PushResponse(serverTime: SyncDate.now(), results: []))
        XCTAssertEqual(summary.applied + summary.stale, 0)
        eq(try await h.row("SELECT sync_state FROM taxonomy_additions")?.string(0), "dirty")
        let unsent = try await h.store.unsentChangeCount()
        XCTAssertEqual(unsent, 1)
    }

    // MARK: - Wire format

    func testOldPayloadsDecodeAndNewFieldsStayOffTheWireWhenUnset() throws {
        let oldJSON = """
        {"id": "0625a3cf-1f76-4ece-982c-8ce3214be232", "canonical_name": "bio eier", "aliases": [], "is_manual_override": false,
         "needs_review": false, "updated_at": "2026-10-31T12:30:00.000Z"}
        """
        let e = try WireCoding.decoder().decode(WireDictionaryEntry.self, from: Data(oldJSON.utf8))
        XCTAssertNil(e.categoryFlagged); XCTAssertNil(e.suggestedCategory)
        let encoded = String(data: try WireCoding.encoder().encode(e), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains("category_flagged"), "an entry that knows nothing about the flag does not send it (the server keeps its value)")
        var flagged = e; flagged.categoryFlagged = true; flagged.suggestedCategory = "Pet Food"; flagged.suggestedParent = "Household"
        let withFlag = String(data: try WireCoding.encoder().encode(flagged), encoding: .utf8) ?? ""
        XCTAssertTrue(withFlag.contains("\"category_flagged\":true")); XCTAssertTrue(withFlag.contains("\"suggested_parent\":\"Household\""))

        let pullJSON = #"{"cursor": "c1", "has_more": false, "dictionary": [], "receipts": [], "line_items": []}"#
        let pull = try WireCoding.decoder().decode(PullResponse.self, from: Data(pullJSON.utf8))
        XCTAssertNil(pull.taxonomyAdditions)
        let newPull = #"{"cursor": "c1", "has_more": false, "dictionary": [], "receipts": [], "line_items": [], "taxonomy_additions": [{"category": "Household", "subcategory": "Pets", "item_group": "Pet Food", "created_at": "2026-10-31T12:00:00.000Z"}]}"#
        XCTAssertEqual(try WireCoding.decoder().decode(PullResponse.self, from: Data(newPull.utf8)).taxonomyAdditions?.first?.path, pets)

        let push = String(data: try WireCoding.encoder().encode(PushRequest(deviceId: "x")), encoding: .utf8) ?? ""
        XCTAssertFalse(push.contains("taxonomy_additions"))
        let result = try WireCoding.decoder().decode(PushResult.self, from: Data(#"{"entity": "taxonomy_addition", "id": "A > B > C", "status": "applied"}"#.utf8))
        XCTAssertEqual(result.entity, .taxonomyAddition)
    }

    func testTaxonomyMergeMatchesTheServersRules() {
        let t = taxonomy.adding([Taxonomy.Path("Household", "Pets", "Pet Food"), Taxonomy.Path("household", "pets", "Cat Litter"),
                                 Taxonomy.Path("Household", "Cleaning", "Windows"), Taxonomy.Path("Garden", "Plants", "Seeds"),
                                 Taxonomy.Path("Food", "Pantry", "legumes")])
        XCTAssertEqual(t.itemGroups(category: "Household", subcategory: "Pets"), ["Pet Food", "Cat Litter"])
        XCTAssertEqual(t.itemGroups(category: "Household", subcategory: "Cleaning").last, "Windows")
        XCTAssertEqual(t.categoryNames().last, "Garden", "a new category goes last")
        XCTAssertEqual(t.itemGroups(category: "Food", subcategory: "Pantry").filter { $0.lowercased() == "legumes" }.count, 1, "an existing path changes nothing")
        XCTAssertEqual(taxonomy.adding([]).categoryNames(), taxonomy.categoryNames())
    }
}
