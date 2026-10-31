import XCTest
@testable import ReceiptsApp

/// The phone is NOT the photo archive: it must never tell the server to delete its copy of a photo. These pin that the
/// guarantee sits in the shared code (the engine's API wrapper and the archive paths), not in the UI leaving a button out.
final class CapabilityTests: XCTestCase {
    private func phone(server: FakeReceiptsServer = FakeReceiptsServer(), cache: Int? = nil) throws -> SyncHarness {
        var caps = SyncCapabilities.mobile
        if let cache { caps.photoCacheBytes = cache }
        return try SyncHarness(server: server, capabilities: caps, deviceId: "iphone-test")
    }

    /// A finished receipt whose photo the server still holds: exactly what the archive device would confirm.
    private func seedArchivableServerPhoto(_ server: FakeReceiptsServer, seed: UInt8 = 7) -> (id: String, data: Data) {
        let id = LegacyIDs.newUUID(), data = fakePhoto(seed)
        server.seedReceipt(WireReceipt(id: id, store: "Edeka", date: "2026-03-01", total: 5, computedSum: 5, createdAt: "2026-03-01T10:00:00.000Z",
                                       photoLocation: "server", photoSha256: Sha256.hex(data), extractionStatus: "done", updatedAt: "2026-03-01T10:00:00.000Z"))
        server.photos[id] = data
        return (id, data)
    }

    func testPhoneSyncNeverCallsAnyArchiveEndpoint() async throws {
        let server = FakeReceiptsServer()
        let photo = seedArchivableServerPhoto(server)
        let h = try phone(server: server)
        let report = await h.engine.syncNow()
        XCTAssertTrue(report.succeeded, "\(report.errors)")
        XCTAssertNil(report.archive)
        XCTAssertEqual(server.archivePendingCalls, 0)
        XCTAssertTrue(server.confirmCalls.isEmpty)
        XCTAssertEqual(server.archiveSyncCalls, 0)
        XCTAssertEqual(server.receipts[photo.id]?.photoLocation, "server", "the server keeps its copy")
        XCTAssertNotNil(server.photos[photo.id])
    }

    func testTheArchiveDeviceDoesConfirmTheSamePhoto() async throws {
        let server = FakeReceiptsServer()
        let photo = seedArchivableServerPhoto(server)
        let h = try SyncHarness(server: server)   // default: the Mac
        let report = await h.engine.syncNow()
        XCTAssertTrue(report.succeeded, "\(report.errors)")
        XCTAssertEqual(server.confirmCalls.count, 1)
        XCTAssertEqual(server.confirmCalls.first?.id, photo.id)
        XCTAssertEqual(server.archiveSyncCalls, 1)
    }

    func testPhoneEngineRefusesToArchiveEvenWhenAskedDirectly() async throws {
        let server = FakeReceiptsServer()
        _ = seedArchivableServerPhoto(server)
        let h = try phone(server: server)
        do {
            _ = try await h.engine.archiveNow()
            XCTFail("the phone must not archive")
        } catch let error as ReceiptsAPIError {
            guard case .notPermitted = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(server.archivePendingCalls, 0)
        XCTAssertTrue(server.confirmCalls.isEmpty)
    }

    func testTheGuardedAPIRefusesArchiveCallsAndForwardsTheRest() async throws {
        let server = FakeReceiptsServer()
        let guarded = CapabilityGuardedAPI(base: server, capabilities: .mobile)
        func refused(_ call: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
            do { try await call(); XCTFail("must be refused", file: file, line: line) }
            catch let error as ReceiptsAPIError { if case .notPermitted = error { return }; XCTFail("\(error)", file: file, line: line) }
            catch { XCTFail("\(error)", file: file, line: line) }
        }
        await refused { _ = try await guarded.archivePending() }
        await refused { _ = try await guarded.archiveConfirm(id: "x", sha256: "y", deviceId: "iphone", acceptFailed: false) }
        await refused { _ = try await guarded.archiveConfirm(id: "x", sha256: "y", deviceId: "iphone", acceptFailed: true) }
        await refused { try await guarded.archiveSync(deviceId: "iphone") }
        XCTAssertEqual(server.archivePendingCalls, 0)
        XCTAssertTrue(server.confirmCalls.isEmpty)
        XCTAssertEqual(server.archiveSyncCalls, 0)
        // everything else goes through
        try await guarded.health()
        _ = try await guarded.status()
        _ = try await guarded.pull(since: nil, limit: 10)
        XCTAssertEqual(server.pullSinceLog.count, 1)

        let archive = CapabilityGuardedAPI(base: server, capabilities: .archiveDevice)
        try await archive.archiveSync(deviceId: "macbook-archive")
        XCTAssertEqual(server.archiveSyncCalls, 1)
    }

    func testNotPermittedIsNeitherRetryableNorAConnectionProblem() {
        let error = ReceiptsAPIError.notPermitted("no")
        XCTAssertFalse(error.isRetryable)
        XCTAssertFalse(error.isConnectionLevel)
    }

    @MainActor
    func testGivingUpOnAFailedReceiptIsIgnoredOnThePhone() async throws {
        let server = FakeReceiptsServer()
        let id = LegacyIDs.newUUID(), data = fakePhoto(3)
        server.seedReceipt(WireReceipt(id: id, createdAt: "2026-03-01T10:00:00.000Z", photoLocation: "server", photoSha256: Sha256.hex(data),
                                       extractionStatus: "failed", extractionError: "unreadable", updatedAt: "2026-03-01T10:00:00.000Z"))
        server.photos[id] = data
        let h = try phone(server: server)
        let suite = "receipts-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: SyncSettings.Keys.enabled)
        defaults.set("https://example.invalid", forKey: SyncSettings.Keys.serverURL)
        let sync = SyncCoordinator(store: h.store, defaults: defaults, capabilities: .mobile, deviceId: "iphone-test",
                                   tokenProvider: { "tok" }, makeAPI: { _, _ in server })
        sync.configure()
        await sync.syncNow()
        let local = try await h.store.localID(forUUID: id)
        await sync.acceptFailedAndArchive(localID: try XCTUnwrap(local))
        let flag = try await h.row("SELECT archive_accept_failed FROM receipts WHERE uuid = ?", [.text(id)])
        XCTAssertEqual(flag?.bool(0), false, "accept_failed is never recorded, so it can never be sent")
        XCTAssertTrue(server.confirmCalls.isEmpty)
        XCTAssertEqual(server.archiveSyncCalls, 0)
        XCTAssertEqual(server.archivePendingCalls, 0)
        sync.stop()
    }

    @MainActor
    func testBannersTellThePhoneToUseTheLaptop() async throws {
        let server = FakeReceiptsServer()
        server.forcedStatus = ServerStatus(unarchivedCount: 4, unarchivedBytes: 8_000_000, archiveReminderDays: 30,
                                           archiveOverdue: true, diskWarning: true, queue: .init())
        let h = try phone(server: server)
        let suite = "receipts-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: SyncSettings.Keys.enabled)
        defaults.set("https://example.invalid", forKey: SyncSettings.Keys.serverURL)
        let sync = SyncCoordinator(store: h.store, defaults: defaults, capabilities: .mobile, deviceId: "iphone-test",
                                   tokenProvider: { "tok" }, makeAPI: { _, _ in server })
        sync.configure()
        await sync.syncNow()
        XCTAssertEqual(sync.banners.count, 2, "\(sync.banners)")
        XCTAssertTrue(sync.banners[0].contains("4 receipt photo(s)") && sync.banners[0].contains("laptop"), "\(sync.banners)")
        XCTAssertTrue(sync.banners[1].contains("low on disk space") && sync.banners[1].contains("laptop"))
        XCTAssertNil(sync.staleSyncWarning, "the 30 day Mac reminder is not for the phone")
        XCTAssertEqual(server.archiveSyncCalls, 0)
        sync.stop()
    }

    // MARK: - photo cache

    func testUploadedPhotoBecomesTheCachedCopyNotDeleted() async throws {
        let h = try phone()
        let p = try await h.addPendingPhoto(seed: 4)
        let report = await h.engine.syncNow()
        XCTAssertEqual(report.uploaded, 1)
        let cached = h.paths.photoCacheDir.appendingPathComponent("\(p.uuid).jpg")
        XCTAssertEqual(try Data(contentsOf: cached), p.data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.paths.outboxDir.appendingPathComponent("\(p.uuid).jpg").path))
        let stored = try await h.receiptField(p.uuid, "source_image")
        XCTAssertEqual(stored, "photo_cache/\(p.uuid).jpg")
    }

    func testEnsurePhotoDownloadsVerifiesAndCachesAServerPhoto() async throws {
        let server = FakeReceiptsServer()
        let photo = seedArchivableServerPhoto(server)
        let h = try phone(server: server)
        _ = await h.engine.syncNow()
        let result = await h.engine.ensurePhoto(uuid: photo.id)
        XCTAssertEqual(result, .cached("photo_cache/\(photo.id).jpg"))
        XCTAssertEqual(try Data(contentsOf: h.paths.photoCacheDir.appendingPathComponent("\(photo.id).jpg")), photo.data)
        let again = await h.engine.ensurePhoto(uuid: photo.id)
        XCTAssertEqual(again, result)
        XCTAssertEqual(server.downloadCalls, 1, "the cached copy is used the second time")
    }

    func testCorruptDownloadIsNotCached() async throws {
        let server = FakeReceiptsServer()
        let photo = seedArchivableServerPhoto(server)
        server.corruptDownloads = true
        let h = try phone(server: server)
        _ = await h.engine.syncNow()
        let result = await h.engine.ensurePhoto(uuid: photo.id)
        guard case .unavailable = result else { return XCTFail("\(result)") }
        XCTAssertEqual(h.engine.photoCache.count, 0)
        let source = try await h.receiptField(photo.id, "source_image")
        XCTAssertNil(source)
    }

    func testArchivedPhotoWithoutACopyIsOnTheLaptop() async throws {
        let server = FakeReceiptsServer()
        let photo = seedArchivableServerPhoto(server)
        let h = try phone(server: server)
        _ = await h.engine.syncNow()
        // the laptop archives it meanwhile (server side), the phone pulls the new state
        _ = try await server.archiveConfirm(id: photo.id, sha256: Sha256.hex(photo.data), deviceId: "macbook-archive", acceptFailed: false)
        _ = await h.engine.syncNow()
        let location = try await h.receiptField(photo.id, "photo_location")
        XCTAssertEqual(location, "archived")
        let result = await h.engine.ensurePhoto(uuid: photo.id)
        XCTAssertEqual(result, .onLaptop)
    }

    func testServerAnswering410MeansOnTheLaptopEvenBeforeThePullSaysSo() async throws {
        let server = FakeReceiptsServer()
        let photo = seedArchivableServerPhoto(server)
        let h = try phone(server: server)
        _ = await h.engine.syncNow()
        server.photos[photo.id] = nil   // archived on the server, the phone has not pulled it yet
        let result = await h.engine.ensurePhoto(uuid: photo.id)
        XCTAssertEqual(result, .onLaptop)
    }

    func testClearingTheCacheLeavesArchivedReceiptsOnTheLaptop() async throws {
        let server = FakeReceiptsServer()
        let photo = seedArchivableServerPhoto(server)
        let h = try phone(server: server)
        _ = await h.engine.syncNow()
        let first = await h.engine.ensurePhoto(uuid: photo.id)
        XCTAssertEqual(first, .cached("photo_cache/\(photo.id).jpg"))
        _ = try await server.archiveConfirm(id: photo.id, sha256: Sha256.hex(photo.data), deviceId: "macbook-archive", acceptFailed: false)
        _ = await h.engine.syncNow()
        let still = await h.engine.ensurePhoto(uuid: photo.id)
        XCTAssertEqual(still, .cached("photo_cache/\(photo.id).jpg"), "the cached copy still shows")
        await h.engine.clearPhotoCache()
        XCTAssertEqual(h.engine.photoCache.count, 0)
        let cleared = await h.engine.ensurePhoto(uuid: photo.id)
        XCTAssertEqual(cleared, .onLaptop)
    }

    func testTheCacheIsBoundedAndEvictsTheOldestFirst() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = PhotoCache(dir: dir.appendingPathComponent("photo_cache"), maxBytes: 2500)
        let now = Date()
        for (i, name) in ["a", "b", "c", "d"].enumerated() {
            let url = try cache.write(Data(repeating: UInt8(i), count: 1000), uuid: name, mediaType: "image/jpeg")
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(Double(i - 10))], ofItemAtPath: url.path)
            cache.trim()
        }
        XCTAssertLessThanOrEqual(cache.totalBytes, 2500)
        let names = Set((try FileManager.default.contentsOfDirectory(atPath: cache.dir.path)).map { ($0 as NSString).deletingPathExtension })
        XCTAssertEqual(names, ["c", "d"], "a and b were the oldest")
        // one photo larger than the whole budget is still kept (it is the newest)
        let big = PhotoCache(dir: cache.dir, maxBytes: 10)
        _ = try big.write(Data(repeating: 9, count: 500), uuid: "e", mediaType: "image/jpeg")
        XCTAssertEqual(big.count, 1)
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
    }

    // MARK: - server URL policy

    func testIPhonePolicyIsHTTPSOnlyAndPlainHTTPOnlyForLocalhostInDebug() {
        let p = ServerURL.PlainHTTPPolicy.debugLoopbackOnly
        XCTAssertNotNil(ServerURL.apiBase(from: "https://receipts.example.com", policy: p, debugBuild: false))
        XCTAssertNil(ServerURL.apiBase(from: "http://receipts.example.com", policy: p, debugBuild: true))
        XCTAssertNil(ServerURL.apiBase(from: "http://192.168.1.20:8000", policy: p, debugBuild: true))
        XCTAssertNotNil(ServerURL.apiBase(from: "http://localhost:8000", policy: p, debugBuild: true))
        XCTAssertNotNil(ServerURL.apiBase(from: "127.0.0.1:8000", policy: p, debugBuild: true))
        XCTAssertNil(ServerURL.apiBase(from: "http://localhost:8000", policy: p, debugBuild: false), "Release builds: no plain HTTP at all")
        XCTAssertNil(ServerURL.apiBase(from: "localhost:8000", policy: p, debugBuild: false))
        // the Mac keeps accepting a server on the home network
        XCTAssertNotNil(ServerURL.apiBase(from: "http://192.168.1.20:8000", policy: .anyHost, debugBuild: false))
    }

    @MainActor
    func testPhoneNotesExplainWhereThePhotoIs() {
        XCTAssertEqual(ReceiptStore.photoNote(location: "archived", hasPath: true, onArchiveDevice: false), "This photo is on your laptop.")
        XCTAssertNotEqual(ReceiptStore.photoNote(location: "archived", hasPath: true, onArchiveDevice: true), "This photo is on your laptop.")
    }
}
