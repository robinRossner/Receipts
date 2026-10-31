import XCTest
@testable import ReceiptsApp

@MainActor
final class SyncCoordinatorTests: XCTestCase {
    private var dir: URL!
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUpWithError() throws {
        dir = try makeTempDir()
        suite = "receipts-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeCoordinator(server: FakeReceiptsServer, token: String? = "tok") throws -> SyncCoordinator {
        let db = try openTempDatabase(in: dir)
        let archive = dir.appendingPathComponent("receipts_archive", isDirectory: true)
        let store = SyncStore(db: db, paths: SyncPaths(appSupportDir: dir, archiveDir: archive))
        return SyncCoordinator(store: store, defaults: defaults, tokenProvider: { token }, makeAPI: { _, _ in server })
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    func testWithSyncOffNothingTalksToTheServer() async throws {
        let server = FakeReceiptsServer()
        let sync = try makeCoordinator(server: server)
        sync.configure()
        await sync.syncNow()
        await sync.syncIfLocalChangesPending()
        sync.noteLocalChange()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(sync.phase, .off)
        XCTAssertFalse(sync.isEnabled)
        XCTAssertTrue(server.pullSinceLog.isEmpty)
        XCTAssertTrue(server.pushLog.isEmpty)
        XCTAssertEqual(server.archiveSyncCalls, 0)
        XCTAssertTrue(sync.banners.isEmpty)
        XCTAssertEqual(sync.statusText, "")
    }

    func testEnabledSyncRunsAndShowsTheServersFlagsAsBanners() async throws {
        let server = FakeReceiptsServer()
        server.forcedStatus = ServerStatus(unarchivedCount: 7, unarchivedBytes: 42_000_000, archiveReminderDays: 30,
                                           archiveOverdue: true, diskWarning: true, queue: .init())
        defaults.set(true, forKey: SyncSettings.Keys.enabled)
        defaults.set("http://127.0.0.1:1", forKey: SyncSettings.Keys.serverURL)
        let sync = try makeCoordinator(server: server)
        sync.configure()
        await waitUntil { sync.serverStatus != nil }
        XCTAssertEqual(sync.phase, .idle)
        XCTAssertNotNil(sync.lastSyncAt)
        XCTAssertEqual(server.archiveSyncCalls, 1, "the archive run happens on the first sync")
        XCTAssertEqual(sync.banners.count, 2)
        XCTAssertTrue(sync.banners[0].contains("7 receipt photo(s)"), "\(sync.banners)")
        XCTAssertTrue(sync.banners.contains { $0.contains("low on disk space") })
        XCTAssertTrue(sync.statusText.hasPrefix("Synced"))
        sync.stop()
    }

    func testMissingTokenIsExplainedNotAttempted() async throws {
        let server = FakeReceiptsServer()
        defaults.set(true, forKey: SyncSettings.Keys.enabled)
        defaults.set("http://127.0.0.1:1", forKey: SyncSettings.Keys.serverURL)
        let sync = try makeCoordinator(server: server, token: nil)
        sync.configure()
        XCTAssertNotNil(sync.lastError)
        XCTAssertTrue(server.pullSinceLog.isEmpty)
        sync.stop()
    }

    func testFailureIsShownQuietlyAndScheduledForRetry() async throws {
        let server = FakeReceiptsServer()
        server.offline = true
        defaults.set(true, forKey: SyncSettings.Keys.enabled)
        defaults.set("http://127.0.0.1:1", forKey: SyncSettings.Keys.serverURL)
        let sync = try makeCoordinator(server: server)
        sync.configure()
        await waitUntil { sync.lastError != nil }
        XCTAssertNotNil(sync.lastError)
        XCTAssertNotNil(sync.nextRetryAt, "a failed run retries by itself")
        XCTAssertEqual(sync.statusText, "Sync failed, retrying")
        sync.stop()
    }

    func testThirtyDaysWithoutSyncRaisesTheWarning() async throws {
        let server = FakeReceiptsServer()
        server.offline = true   // never gets to sync
        defaults.set(true, forKey: SyncSettings.Keys.enabled)
        defaults.set("http://127.0.0.1:1", forKey: SyncSettings.Keys.serverURL)
        defaults.set(Date().addingTimeInterval(-31 * 86_400).timeIntervalSince1970, forKey: SyncSettings.Keys.enabledSince)
        let sync = try makeCoordinator(server: server)
        sync.configure()
        await waitUntil { sync.staleSyncWarning != nil }
        XCTAssertNotNil(sync.staleSyncWarning)
        XCTAssertTrue(sync.banners.contains { $0.contains("30 days") })
        sync.stop()
    }

    func testConnectionTest() async throws {
        let server = FakeReceiptsServer()
        let sync = try makeCoordinator(server: server)
        let ok = await sync.testConnection(serverURL: "https://example.test", token: "t")
        XCTAssertTrue(ok.ok, ok.message)
        let noToken = await sync.testConnection(serverURL: "https://example.test", token: nil)
        XCTAssertFalse(noToken.ok)
        let badURL = await sync.testConnection(serverURL: "", token: "t")
        XCTAssertFalse(badURL.ok)
        server.failures["status"] = .http(status: 401, code: nil, message: nil, extra: [:])
        let denied = await sync.testConnection(serverURL: "https://example.test", token: "t")
        XCTAssertFalse(denied.ok)
        XCTAssertTrue(denied.message.contains("401"))
    }
}
