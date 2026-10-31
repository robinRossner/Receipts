import CoreImage
import XCTest
@testable import ReceiptsApp

final class SyncMergeTests: XCTestCase {
    private let t1 = Date(timeIntervalSince1970: 1_000), t2 = Date(timeIntervalSince1970: 2_000)

    func testUnknownLocallyTakesTheServer() { XCTAssertEqual(SyncMerge.decide(localUpdatedAt: nil, dirty: false, serverUpdatedAt: t1), .takeServer) }
    func testCleanLocalCopyIsReplaced() { XCTAssertEqual(SyncMerge.decide(localUpdatedAt: t2, dirty: false, serverUpdatedAt: t1), .takeServer) }
    func testNewerUnsentEditWins() { XCTAssertEqual(SyncMerge.decide(localUpdatedAt: t2, dirty: true, serverUpdatedAt: t1), .keepLocal) }
    func testOlderUnsentEditLoses() { XCTAssertEqual(SyncMerge.decide(localUpdatedAt: t1, dirty: true, serverUpdatedAt: t2), .takeServer) }
    func testTieGoesToTheServerLikeItsStalePushRule() { XCTAssertEqual(SyncMerge.decide(localUpdatedAt: t1, dirty: true, serverUpdatedAt: t1), .takeServer) }

    func testLocalDeleteBeatsAnOlderServerRecordOnly() {
        XCTAssertTrue(SyncMerge.localDeleteWins(deletedAt: t2, serverUpdatedAt: t1))
        XCTAssertTrue(SyncMerge.localDeleteWins(deletedAt: t1, serverUpdatedAt: t1))
        XCTAssertFalse(SyncMerge.localDeleteWins(deletedAt: t1, serverUpdatedAt: t2))
        XCTAssertFalse(SyncMerge.localDeleteWins(deletedAt: nil, serverUpdatedAt: t2))
    }

    func testTimestampsAreComparedAsInstantsNotText() {
        // as text "…:30.500Z" < "…:30Z"; as instants it is later
        let withMillis = SyncDate.parse("2026-07-14T10:20:30.500Z")!, without = SyncDate.parse("2026-07-14T10:20:30Z")!
        XCTAssertGreaterThan(withMillis, without)
        XCTAssertEqual(SyncDate.parse("2026-07-14 10:20:30"), without)
        XCTAssertEqual(SyncDate.parse("2026-07-14T12:20:30+02:00"), without)
        XCTAssertEqual(SyncDate.parse("2026-07-14T10:20:30.000Z"), without)
        XCTAssertNil(SyncDate.parse("not a date"))
        XCTAssertEqual(SyncDate.string(from: without), "2026-07-14T10:20:30.000Z")
    }
}

final class WireFormatTests: XCTestCase {
    func testDecodesTheContractsReceiptAndPullExamples() throws {
        let json = """
        {"cursor": "c16", "has_more": false, "server_time": "2026-10-31T12:21:39.119Z", "taxonomy_version": "1b014dce5b21c26a",
         "dictionary": [{"id": "0625a3cf-1f76-4ece-982c-8ce3214be232", "legacy_id": null, "canonical_name": "bio eier 10er", "display_name_de": "Bio Eier 10er",
            "translation_en": "organic eggs", "category": "Food", "subcategory": "Dairy & Eggs", "item_group": "Eggs", "aliases": ["bio eier 10er"],
            "is_manual_override": true, "needs_review": false, "times_seen": 1, "created_at": "2026-10-31T12:21:21.789Z",
            "last_seen_at": "2026-10-31T12:21:21.789Z", "updated_at": "2026-10-31T12:30:00.000Z", "deleted_at": null}],
         "receipts": [{"id": "3b241101-e2bb-4255-8caf-4136c566a962", "legacy_id": null, "store": "Edeka", "date": "2026-03-01", "time": "09:12", "total": 5.73,
            "computed_sum": 5.73, "needs_review": false, "review_reasons": [], "reviewed_at": null, "created_at": "2026-10-31T12:21:21.775Z",
            "photo_location": "server", "photo_sha256": "823c", "photo_bytes": 198, "photo_media_type": "image/jpeg", "uploaded_at": "2026-10-31T12:21:21.775Z",
            "archived_at": null, "extraction_status": "done", "extraction_attempts": 1, "extraction_error": null,
            "extraction_provider": "claude-cli-token/claude-haiku-5-5", "extraction_completed_at": "2026-10-31T12:21:21.790Z",
            "updated_at": "2026-10-31T12:21:21.775Z", "deleted_at": null}],
         "line_items": [{"id": "9773404b-69b9-4a69-848f-2eeb0a80845f", "legacy_id": null, "receipt_id": "3b241101-e2bb-4255-8caf-4136c566a962",
            "item_dictionary_id": "0625a3cf-1f76-4ece-982c-8ce3214be232", "position": 0, "raw_text": "Bio Eier 10er", "name_de": "Bio Eier 10er", "quantity": 1.0,
            "unit_price": 2.49, "total_price": 2.49, "price_normalized": false, "updated_at": "2026-10-31T12:21:21.790Z", "deleted_at": null}]}
        """
        let page = try WireCoding.decoder().decode(PullResponse.self, from: Data(json.utf8))
        XCTAssertEqual(page.cursor, "c16")
        XCTAssertEqual(page.receipts[0].photoSha256, "823c")
        XCTAssertEqual(page.receipts[0].extractionStatus, "done")
        XCTAssertEqual(page.lineItems[0].itemDictionaryId, "0625a3cf-1f76-4ece-982c-8ce3214be232")
        XCTAssertEqual(page.dictionary[0].aliases, ["bio eier 10er"])
        XCTAssertTrue(page.dictionary[0].isManualOverride)
    }

    func testPushPayloadUsesTheContractsFieldNamesAndOmitsServerOwnedOnes() throws {
        let receipt = WireReceipt(id: "r1", store: "Edeka", date: "2026-03-01", total: 5.73, needsReview: true, reviewReasons: ["x"],
                                  reviewedAt: "2026-10-31T12:30:05.000Z", photoSha256: "abc", extractionStatus: "done",
                                  updatedAt: "2026-10-31T12:30:05.000Z").forPush(photoLocation: "none")
        let request = PushRequest(deviceId: "macbook-archive", receipts: [receipt])
        let object = try JSONSerialization.jsonObject(with: WireCoding.encoder().encode(request)) as! [String: Any]
        XCTAssertEqual(object["device_id"] as? String, "macbook-archive")
        let r = (object["receipts"] as! [[String: Any]])[0]
        XCTAssertEqual(r["needs_review"] as? Bool, true)
        XCTAssertEqual(r["reviewed_at"] as? String, "2026-10-31T12:30:05.000Z")
        XCTAssertEqual(r["photo_location"] as? String, "none")
        XCTAssertNil(r["photo_sha256"])
        XCTAssertNil(r["extraction_status"])
        XCTAssertNotNil(object["line_items"])
    }

    func testApiErrorParsing() {
        let body = #"{"detail": {"code": "duplicate_image", "message": "dup", "duplicate_of": "abc"}}"#
        let error = URLSessionReceiptsAPI.httpError(409, Data(body.utf8))
        XCTAssertEqual(error.code, "duplicate_image")
        XCTAssertEqual(error.extra["duplicate_of"], "abc")
        XCTAssertFalse(error.isRetryable)
        XCTAssertTrue(URLSessionReceiptsAPI.httpError(503, Data()).isRetryable)
        XCTAssertTrue(URLSessionReceiptsAPI.httpError(401, Data()).isConnectionLevel)
        XCTAssertFalse(URLSessionReceiptsAPI.httpError(409, Data(body.utf8)).isConnectionLevel)
    }

    func testServerURLNormalisation() {
        XCTAssertEqual(ServerURL.apiBase(from: "https://receipts.example.com")?.absoluteString, "https://receipts.example.com/api/v1/receipts")
        XCTAssertEqual(ServerURL.apiBase(from: " receipts.example.com/ ")?.absoluteString, "https://receipts.example.com/api/v1/receipts")
        XCTAssertEqual(ServerURL.apiBase(from: "localhost:8000")?.absoluteString, "http://localhost:8000/api/v1/receipts")
        XCTAssertEqual(ServerURL.apiBase(from: "http://127.0.0.1:8765/api/v1/receipts/")?.absoluteString, "http://127.0.0.1:8765/api/v1/receipts")
        XCTAssertNil(ServerURL.apiBase(from: ""))
        XCTAssertNil(ServerURL.apiBase(from: "ftp://x"))
        XCTAssertEqual(ServerURL.healthURL(apiBase: ServerURL.apiBase(from: "https://h.example")!).absoluteString, "https://h.example/health")
    }
}

final class SyncReminderTests: XCTestCase {
    private let day: TimeInterval = 86_400
    func testOverdueAfter30DaysSinceLastSync() {
        let last = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(SyncReminder.isOverdue(lastSync: last, enabledSince: nil, now: last.addingTimeInterval(29 * day)))
        XCTAssertTrue(SyncReminder.isOverdue(lastSync: last, enabledSince: nil, now: last.addingTimeInterval(30 * day)))
    }
    func testCountsFromEnablingWhenNeverSynced() {
        let enabled = Date(timeIntervalSince1970: 5_000_000)
        XCTAssertTrue(SyncReminder.isOverdue(lastSync: nil, enabledSince: enabled, now: enabled.addingTimeInterval(31 * day)))
        XCTAssertFalse(SyncReminder.isOverdue(lastSync: nil, enabledSince: nil, now: Date()))
        XCTAssertEqual(SyncReminder.dueDate(lastSync: nil, enabledSince: enabled), enabled.addingTimeInterval(30 * day))
    }
    func testLastSyncWinsOverEnablingDate() {
        let enabled = Date(timeIntervalSince1970: 5_000_000), last = enabled.addingTimeInterval(20 * day)
        XCTAssertEqual(SyncReminder.dueDate(lastSync: last, enabledSince: enabled), last.addingTimeInterval(30 * day))
    }
}

final class PhotoPreparerTests: XCTestCase {
    /// Random noise does not compress: 4000x3000 would be ~12 MB at full quality.
    private func noisyImage(width: Int, height: Int) -> CIImage {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            bytes[i] = UInt8.random(in: 0...255, using: &generator); bytes[i + 1] = UInt8.random(in: 0...255, using: &generator)
            bytes[i + 2] = UInt8.random(in: 0...255, using: &generator); bytes[i + 3] = 255
        }
        return CIImage(bitmapData: Data(bytes), bytesPerRow: width * 4, size: CGSize(width: width, height: height),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    func testLargeImageIsScaledTo2500pxAndUnderTheLimit() throws {
        let data = try PhotoPreparer.encode(noisyImage(width: 4000, height: 3000))
        XCTAssertLessThanOrEqual(data.count, PhotoPreparer.maxBytes)
        XCTAssertLessThan(PhotoPreparer.maxBytes, 5 * 1024 * 1024)
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8])
        XCTAssertEqual(Array(data.suffix(2)), [0xFF, 0xD9], "a complete JPEG (the server checks both markers)")
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        let longEdge = max(props[kCGImagePropertyPixelWidth] as! Int, props[kCGImagePropertyPixelHeight] as! Int)
        XCTAssertLessThanOrEqual(longEdge, 2500)
    }

    func testTinyBudgetForcesFurtherCompressionInsteadOfFailing() throws {
        let data = try PhotoPreparer.encode(noisyImage(width: 3000, height: 2000), maxBytes: 600_000)
        XCTAssertLessThanOrEqual(data.count, 600_000)
    }

    func testImpossibleBudgetThrows() {
        XCTAssertThrowsError(try PhotoPreparer.encode(noisyImage(width: 1000, height: 1000), maxBytes: 100))
    }

    func testMediaTypeSniffing() {
        XCTAssertEqual(PhotoPreparer.mediaType(of: Data([0x89, 0x50, 0x4E, 0x47, 0])), "image/png")
        XCTAssertEqual(PhotoPreparer.mediaType(of: Data([0xFF, 0xD8, 0xFF])), "image/jpeg")
    }
}
