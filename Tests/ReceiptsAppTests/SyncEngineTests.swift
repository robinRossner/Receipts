import XCTest
@testable import ReceiptsApp

final class SyncEngineTests: XCTestCase {
    // MARK: upload queue

    func testUploadThenExtractionArrivesThroughPull() async throws {
        let h = try SyncHarness()
        let photo = try await h.addPendingPhoto()

        var report = await h.engine.syncNow()
        XCTAssertEqual(report.uploaded, 1)
        XCTAssertTrue(report.succeeded, "\(report.errors)")
        XCTAssertEqual(h.server.uploadCalls, [photo.uuid])
        XCTAssertEqual(h.server.photos[photo.uuid], photo.data)
        // the stub is not pushed (upload creates the server receipt), status/sha come from the server
        XCTAssertTrue(h.server.pushLog.isEmpty)
        let status = try await h.receiptField(photo.uuid, "extraction_status")
        let sha = try await h.receiptField(photo.uuid, "photo_sha256")
        XCTAssertEqual(status, "queued")
        XCTAssertEqual(sha, Sha256.hex(photo.data))

        // the server finishes the extraction; it arrives through pull
        let dict = LegacyIDs.newUUID()
        h.server.finishExtraction(photo.uuid, store: "Edeka")
        h.server.seedDictionary(WireDictionaryEntry(id: dict, canonicalName: "milch", displayNameDe: "Milch", translationEn: "milk", category: "Food",
                                                    subcategory: "Dairy & Eggs", itemGroup: "Milk", aliases: [], isManualOverride: false, needsReview: false,
                                                    timesSeen: 1, createdAt: "2026-04-01T10:00:00.000Z", lastSeenAt: "2026-04-01T10:00:00.000Z", updatedAt: "2026-04-01T10:00:00.000Z"))
        h.server.seedItem(WireLineItem(id: LegacyIDs.newUUID(), receiptId: photo.uuid, itemDictionaryId: dict, position: 0, rawText: "MILCH", nameDe: "Milch",
                                       quantity: 1, unitPrice: 1.2, totalPrice: 1.2, priceNormalized: false, updatedAt: "2026-04-01T10:00:00.000Z"))
        report = await h.engine.syncNow()
        XCTAssertTrue(report.succeeded, "\(report.errors)")
        let store = try await h.receiptField(photo.uuid, "store")
        let finalStatus = try await h.receiptField(photo.uuid, "extraction_status")
        XCTAssertEqual(store, "Edeka")
        XCTAssertEqual(finalStatus, "done")
        let items = try await h.count("line_items")
        XCTAssertEqual(items, 1)
        // pulled data is not an unsent edit
        let unsent = try await h.store.unsentChangeCount()
        XCTAssertEqual(unsent, 0)
    }

    func testOfflineUploadStaysQueuedAndRetries() async throws {
        let h = try SyncHarness()
        let photo = try await h.addPendingPhoto()
        h.server.offline = true
        let failed = await h.engine.syncNow()
        XCTAssertFalse(failed.succeeded)
        XCTAssertTrue(failed.connectionProblem)
        let queued = try await h.receiptField(photo.uuid, "extraction_status")
        XCTAssertEqual(queued, "pending_upload")
        let inFlight = try await h.store.inFlightCount()
        XCTAssertEqual(inFlight, 1)

        h.server.offline = false
        let ok = await h.engine.syncNow()
        XCTAssertEqual(ok.uploaded, 1)
        let uploaded = try await h.receiptField(photo.uuid, "extraction_status")
        XCTAssertEqual(uploaded, "queued")
        XCTAssertEqual(h.server.uploadCalls.count, 1, "the failed attempt never reached the fake server")
    }

    func testRetryAfterLostResponseIsIdempotent() async throws {
        let h = try SyncHarness()
        let photo = try await h.addPendingPhoto()
        _ = await h.engine.syncNow()
        // pretend the response was lost: the app thinks the upload is still pending
        try await h.db.run("UPDATE receipts SET extraction_status = 'pending_upload' WHERE uuid = ?", [.text(photo.uuid)])
        let report = await h.engine.syncNow()
        XCTAssertTrue(report.succeeded, "\(report.errors)")
        XCTAssertEqual(h.server.receipts.count, 1)
        let status = try await h.receiptField(photo.uuid, "extraction_status")
        XCTAssertEqual(status, "queued")
    }

    func testDuplicateImageDropsTheLocalReceipt() async throws {
        let h = try SyncHarness()
        let first = try await h.addPendingPhoto(seed: 7)
        _ = await h.engine.syncNow()
        // same bytes under a new uuid
        let second = try await h.addPendingPhoto(seed: 7)
        let report = await h.engine.syncNow()
        XCTAssertEqual(report.duplicates[second.uuid], first.uuid)
        let local = try await h.count("receipts", where: "uuid = '\(second.uuid)'")
        XCTAssertEqual(local, 0)
        let leftover = FileManager.default.fileExists(atPath: h.paths.outboxDir.appendingPathComponent("\(second.uuid).jpg").path)
        XCTAssertFalse(leftover)
    }

    func testPermanentUploadErrorNeedsTheUser() async throws {
        let h = try SyncHarness()
        let photo = try await h.addPendingPhoto()
        h.server.failures["upload"] = .http(status: 415, code: "invalid_image", message: "not an image", extra: [:])
        let report = await h.engine.syncNow()
        XCTAssertFalse(report.connectionProblem)
        let status = try await h.receiptField(photo.uuid, "extraction_status")
        XCTAssertEqual(status, "upload_failed")
        // a second run does not hammer the server with the same bytes
        _ = await h.engine.syncNow()
        XCTAssertEqual(h.server.uploadCalls.count, 0, "the rejected attempt never counted, and nothing was sent again")
        // Retry puts it back in the queue
        let id = try await h.store.localID(forUUID: photo.uuid)!
        try await h.store.requeueUpload(localID: id)
        let retried = await h.engine.syncNow()
        XCTAssertEqual(retried.uploaded, 1)
    }

    // MARK: push

    func testEditsArePushedOnce() async throws {
        let h = try SyncHarness()
        let ids = h.seedExtractedReceipt()
        _ = await h.engine.syncNow()
        let id = try await h.store.localID(forUUID: ids.receipt)!

        try await h.db.run("UPDATE receipts SET reviewed_at = ?, store = 'Rewe Markt' WHERE id = ?", [.text("2026-10-31T10:00:00Z"), .from(id)])
        let pending = try await h.store.unsentChangeCount()
        XCTAssertEqual(pending, 1)
        let report = await h.engine.syncNow()
        XCTAssertEqual(report.push.applied, 1)
        XCTAssertEqual(h.server.receipts[ids.receipt]?.store, "Rewe Markt")
        XCTAssertEqual(h.server.receipts[ids.receipt]?.reviewedAt, "2026-10-31T10:00:00Z")
        let again = await h.engine.syncNow()
        XCTAssertEqual(again.push.applied + again.push.stale, 0)
        XCTAssertEqual(h.server.pushLog.count, 1)
        // photoLocation is sent only as none/archived (the server rejects `server`)
        XCTAssertEqual(h.server.pushLog[0].receipts.first?.photoLocation, "none")
    }

    func testDeleteBecomesTombstoneAndEditsAreNeverLost() async throws {
        let h = try SyncHarness()
        let ids = h.seedExtractedReceipt()
        _ = await h.engine.syncNow()
        try await h.db.run("DELETE FROM line_items WHERE uuid = ?", [.text(ids.item)])
        let report = await h.engine.syncNow()
        XCTAssertTrue(report.succeeded, "\(report.errors)")
        XCTAssertNotNil(h.server.items[ids.item]?.deletedAt)
        let tombstones = try await h.count("sync_tombstones")
        XCTAssertEqual(tombstones, 0, "acknowledged tombstones are forgotten")
        let items = try await h.count("line_items")
        XCTAssertEqual(items, 0)
    }

    func testRecordRejectedByTheServerIsKeptOutOfTheQueueUntilEditedAgain() async throws {
        let h = try SyncHarness()
        let ids = h.seedExtractedReceipt()
        _ = await h.engine.syncNow()
        let id = try await h.store.localID(forUUID: ids.receipt)!
        try await h.db.run("UPDATE receipts SET store = 'X' WHERE id = ?", [.from(id)])
        // the fake rejects receipts whose photo_location is not none/archived; force a rejection with a bad id instead
        h.server.failures["push"] = nil
        let rejecting = RejectingServer(wrapping: h.server)
        let engine = SyncEngine(api: rejecting, store: h.store, config: SyncConfig(cursorKey: "cursor:test"))
        let first = await engine.syncNow()
        XCTAssertEqual(first.push.rejected.count, 1)
        XCTAssertFalse(first.succeeded)
        let state = try await h.receiptField(ids.receipt, "sync_state")
        let reason = try await h.receiptField(ids.receipt, "sync_error")
        XCTAssertEqual(state, "rejected")
        XCTAssertEqual(reason, "invalid: date")
        let second = await engine.syncNow()
        XCTAssertEqual(second.push.rejected.count, 0, "not retried unchanged")
        try await h.db.run("UPDATE receipts SET store = 'Y' WHERE id = ?", [.from(id)])
        let unsent = try await h.store.unsentChangeCount()
        XCTAssertEqual(unsent, 1)
    }

    // MARK: last write wins

    func testLocalEditNewerThanServerChangeWinsAndServerOwnedFieldsStillCome() async throws {
        let h = try SyncHarness()
        let ids = h.seedExtractedReceipt(stamp: "2026-04-01T10:00:00.000Z")
        _ = await h.engine.syncNow()
        let id = try await h.store.localID(forUUID: ids.receipt)!

        // another device edits the store at T1; we edit it locally later (T2 = now) without having synced
        var theirs = h.server.receipts[ids.receipt]!
        theirs.store = "Theirs"; theirs.updatedAt = "2026-05-01T10:00:00.000Z"; theirs.extractionStatus = "done"; theirs.photoLocation = "archived"
        h.server.seedReceipt(theirs)
        try await h.db.run("UPDATE receipts SET store = 'Ours' WHERE id = ?", [.from(id)])

        // pull alone (offline for push): simulate by applying the pull directly
        let page = try await h.server.pull(since: nil, limit: 100)
        _ = try await h.store.applyPull(dictionary: page.dictionary, receipts: page.receipts, lineItems: page.lineItems)
        let store = try await h.receiptField(ids.receipt, "store")
        let location = try await h.receiptField(ids.receipt, "photo_location")
        XCTAssertEqual(store, "Ours", "the unsent local edit is newer")
        XCTAssertEqual(location, "archived", "server-owned fields always come from the server")

        let report = await h.engine.syncNow()
        XCTAssertEqual(report.push.applied, 1)
        XCTAssertEqual(h.server.receipts[ids.receipt]?.store, "Ours")
    }

    func testServerChangeNewerThanLocalEditWins() async throws {
        let h = try SyncHarness()
        let ids = h.seedExtractedReceipt(stamp: "2026-04-01T10:00:00.000Z")
        _ = await h.engine.syncNow()
        let id = try await h.store.localID(forUUID: ids.receipt)!
        try await h.db.run("UPDATE receipts SET store = 'Ours' WHERE id = ?", [.from(id)])
        // pretend our edit happened a year ago
        try await h.db.run("UPDATE receipts SET updated_at = '2025-01-01T00:00:00.000Z' WHERE id = ?", [.from(id)])
        var theirs = h.server.receipts[ids.receipt]!
        theirs.store = "Theirs"; theirs.updatedAt = "2026-05-01T10:00:00.000Z"
        h.server.seedReceipt(theirs)

        let report = await h.engine.syncNow()
        XCTAssertEqual(report.push.stale, 1)
        let store = try await h.receiptField(ids.receipt, "store")
        XCTAssertEqual(store, "Theirs")
        XCTAssertEqual(h.server.receipts[ids.receipt]?.store, "Theirs")
        let unsent = try await h.store.unsentChangeCount()
        XCTAssertEqual(unsent, 0)
    }

    func testTombstonesFromTheServer() async throws {
        let h = try SyncHarness()
        let ids = h.seedExtractedReceipt()
        _ = await h.engine.syncNow()
        var item = h.server.items[ids.item]!
        item.deletedAt = "2026-06-01T00:00:00.000Z"; item.updatedAt = "2026-06-01T00:00:00.000Z"
        h.server.seedItem(item)
        var receipt = h.server.receipts[ids.receipt]!
        receipt.deletedAt = "2026-06-01T00:00:00.000Z"; receipt.updatedAt = "2026-06-01T00:00:00.000Z"
        h.server.seedReceipt(receipt)
        _ = await h.engine.syncNow()
        let items = try await h.count("line_items")
        XCTAssertEqual(items, 0)
        // the receipt stays as a soft-deleted row (shows under "Recently deleted")
        let deleted = try await h.receiptField(ids.receipt, "deleted_at")
        XCTAssertNotNil(deleted)
        // and it can be undeleted by a newer record
        receipt.deletedAt = nil; receipt.updatedAt = "2026-06-02T00:00:00.000Z"
        h.server.seedReceipt(receipt)
        _ = await h.engine.syncNow()
        let restored = try await h.receiptField(ids.receipt, "deleted_at")
        XCTAssertNil(restored)
    }

    func testPermanentlyDeletedReceiptIsNotBroughtBack() async throws {
        let h = try SyncHarness()
        let ids = h.seedExtractedReceipt()
        _ = await h.engine.syncNow()
        let id = try await h.store.localID(forUUID: ids.receipt)!
        try await h.db.run("UPDATE receipts SET deleted_at = '2026-06-01T00:00:00Z' WHERE id = ?", [.from(id)])
        try await h.db.transaction { c in
            try c.run("DELETE FROM line_items WHERE receipt_id = ?", [.from(id)])
            try c.run("DELETE FROM receipts WHERE id = ?", [.from(id)])
        }
        _ = await h.engine.syncNow()
        XCTAssertNotNil(h.server.receipts[ids.receipt]?.deletedAt)
        // the server changes the record again (e.g. an archive confirmation) and sends it down
        h.server.finishExtraction(ids.receipt)
        _ = await h.engine.syncNow()
        let back = try await h.count("receipts", where: "uuid = '\(ids.receipt)'")
        XCTAssertEqual(back, 0)
    }

    // MARK: pull details

    func testCursorIsStoredAndUsedForTheNextPull() async throws {
        let h = try SyncHarness()
        _ = h.seedExtractedReceipt()
        _ = await h.engine.syncNow()
        _ = await h.engine.syncNow()
        XCTAssertEqual(h.server.pullSinceLog.count, 2)
        XCTAssertNil(h.server.pullSinceLog[0])
        XCTAssertEqual(h.server.pullSinceLog[1], "c3")
        let stored = try await h.store.meta("cursor:test")
        XCTAssertEqual(stored, "c3")
    }

    func testFailedPullKeepsTheCursor() async throws {
        let h = try SyncHarness()
        _ = h.seedExtractedReceipt()
        _ = await h.engine.syncNow()
        h.server.failures["pull"] = .http(status: 500, code: nil, message: nil, extra: [:])
        let report = await h.engine.syncNow()
        XCTAssertFalse(report.succeeded)
        let stored = try await h.store.meta("cursor:test")
        XCTAssertEqual(stored, "c3")
    }

    func testPullAppliesAllThreeListsTogetherWhateverTheOrder() async throws {
        let h = try SyncHarness()
        // seeded line item first, dictionary entry last: same pull, so the reference resolves
        let item = LegacyIDs.newUUID(), receipt = LegacyIDs.newUUID(), dict = LegacyIDs.newUUID()
        h.server.seedItem(WireLineItem(id: item, receiptId: receipt, itemDictionaryId: dict, position: 0, rawText: "A", nameDe: "A", quantity: 1, unitPrice: 1, totalPrice: 1, priceNormalized: false, updatedAt: "2026-04-01T10:00:00.000Z"))
        _ = h.seedExtractedReceipt(id: receipt, dictionaryId: dict, itemId: LegacyIDs.newUUID())
        let report = await h.engine.syncNow()
        XCTAssertTrue(report.succeeded, "\(report.errors)")
        XCTAssertEqual(report.pulled.unresolved, 0)
        let items = try await h.count("line_items")
        XCTAssertEqual(items, 2)
    }

    func testDictionaryNameClashWithAnUnsyncedLocalEntryMergesIntoTheServersEntry() async throws {
        let h = try SyncHarness()
        // a local-only entry named "brot" with an item, never synced
        try await h.db.run("INSERT INTO item_dictionary (canonical_name, display_name_de, category, subcategory, item_group, aliases, created_at, last_seen_at) VALUES ('brot', 'Brot', 'Food', 'Bakery', 'Bread', '[]', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')")
        let localReceipt = try await h.db.run("INSERT INTO receipts (store, created_at) VALUES ('Lokal', '2026-01-01T00:00:00Z')")
        try await h.db.run("INSERT INTO line_items (receipt_id, item_dictionary_id, raw_text, name_de, quantity, unit_price, total_price) VALUES (?, 1, 'BROT', 'Brot', 1, 1, 1)", [.integer(localReceipt)])
        let ids = h.seedExtractedReceipt(canonical: "brot")
        // the server answers the local entry's push with a rejection (name already used), then the pull brings the server's entry
        _ = await h.engine.syncNow()
        let entries = try await h.count("item_dictionary", where: "canonical_name = 'brot'")
        XCTAssertEqual(entries, 1)
        let item = try await h.row("SELECT d.uuid FROM line_items li JOIN item_dictionary d ON d.id = li.item_dictionary_id WHERE li.receipt_id = ?", [.integer(localReceipt)])
        XCTAssertEqual(item?.string(0), ids.dictionary)
    }

    // MARK: first sync of existing data

    func testFirstSyncAgainstAServerMigratedFromTheSameDataCreatesNoDuplicates() async throws {
        let h = try SyncHarness(legacy: true)
        // The server as migrate_mac_data.py leaves it: same UUIDs, same updated_at (read back from the local rows)
        for row in try await h.db.query("SELECT uuid, canonical_name, display_name_de, category, subcategory, item_group, updated_at FROM item_dictionary") {
            h.server.seedDictionary(WireDictionaryEntry(id: row.string(0)!, canonicalName: row.string(1)!, displayNameDe: row.string(2), category: row.string(3), subcategory: row.string(4),
                                                        itemGroup: row.string(5), aliases: [], isManualOverride: false, needsReview: false, timesSeen: 1, updatedAt: row.string(6)!))
        }
        for row in try await h.db.query("SELECT uuid, store, updated_at FROM receipts") {
            h.server.seedReceipt(WireReceipt(id: row.string(0)!, store: row.string(1), photoLocation: "archived", extractionStatus: "done", updatedAt: row.string(2)!))
        }
        for row in try await h.db.query("SELECT li.uuid, r.uuid, d.uuid, li.position, li.updated_at FROM line_items li JOIN receipts r ON r.id = li.receipt_id JOIN item_dictionary d ON d.id = li.item_dictionary_id WHERE li.sync_state = 'dirty'") {
            h.server.seedItem(WireLineItem(id: row.string(0)!, receiptId: row.string(1)!, itemDictionaryId: row.string(2)!, position: row.int(3)!, quantity: 1, unitPrice: 1,
                                           totalPrice: 1, priceNormalized: false, updatedAt: row.string(4)!))
        }
        let before = (h.server.receipts.count, h.server.items.count, h.server.dictionary.count)

        let report = await h.engine.syncNow()
        XCTAssertTrue(report.succeeded, "\(report.errors)")
        XCTAssertEqual(report.push.applied, 0, "everything the server already has is stale, nothing is overwritten")
        XCTAssertGreaterThan(report.push.stale, 0)
        XCTAssertEqual(h.server.receipts.count, before.0)
        XCTAssertEqual(h.server.items.count, before.1)
        XCTAssertEqual(h.server.dictionary.count, before.2)
        let localReceipts = try await h.count("receipts")
        let dirty = try await h.store.unsentChangeCount()
        XCTAssertEqual(localReceipts, 3)
        XCTAssertEqual(dirty, 0)
    }

    func testFirstSyncToAnEmptyServerUploadsTheExistingData() async throws {
        let h = try SyncHarness(legacy: true)
        let report = await h.engine.syncNow()
        XCTAssertTrue(report.succeeded, "\(report.errors)")
        XCTAssertEqual(h.server.receipts.count, 3)
        XCTAssertEqual(h.server.dictionary.count, 3)
        XCTAssertEqual(h.server.items.count, 5, "the orphan item (no dictionary entry) is never pushed")
        XCTAssertEqual(h.server.receipts[LegacyIDs.uuid(.receipt, 1)]?.photoLocation, "none", "the photo file is not on disk in this fixture")
        XCTAssertNotNil(h.server.receipts[LegacyIDs.uuid(.receipt, 3)]?.deletedAt)
        XCTAssertEqual(h.server.items[LegacyIDs.uuid(.lineItem, 4)]?.position, 1)
        let unsent = try await h.store.unsentChangeCount()
        XCTAssertEqual(unsent, 0)
    }
}

/// Wraps the fake server but rejects every pushed receipt (to test rejection handling).
final class RejectingServer: ReceiptsAPI, @unchecked Sendable {
    let base: FakeReceiptsServer
    init(wrapping base: FakeReceiptsServer) { self.base = base }
    func health() async throws { try await base.health() }
    func status() async throws -> ServerStatus { try await base.status() }
    func uploadPhoto(id: String, data: Data, mediaType: String, createdAt: Date?) async throws -> UploadResponse { try await base.uploadPhoto(id: id, data: data, mediaType: mediaType, createdAt: createdAt) }
    func retryExtraction(id: String) async throws { try await base.retryExtraction(id: id) }
    func push(_ request: PushRequest) async throws -> PushResponse {
        PushResponse(serverTime: SyncDate.now(), results: request.receipts.map { .init(entity: .receipt, id: $0.id, status: .rejected, reason: "invalid: date") }
            + request.dictionary.map { .init(entity: .dictionary, id: $0.id, status: .stale) } + request.lineItems.map { .init(entity: .lineItem, id: $0.id, status: .stale) })
    }
    func pull(since: String?, limit: Int) async throws -> PullResponse { try await base.pull(since: since, limit: limit) }
    func archivePending() async throws -> [ArchivePendingPhoto] { try await base.archivePending() }
    func downloadPhoto(path: String) async throws -> DownloadedPhoto { try await base.downloadPhoto(path: path) }
    func archiveConfirm(id: String, sha256: String, deviceId: String, acceptFailed: Bool) async throws -> ArchiveConfirmResponse { try await base.archiveConfirm(id: id, sha256: sha256, deviceId: deviceId, acceptFailed: acceptFailed) }
    func archiveSync(deviceId: String) async throws { try await base.archiveSync(deviceId: deviceId) }
}
