import XCTest
@testable import ReceiptsApp

/// Not a test of its own: the "laptop" side of the iPhone simulator e2e run (Tests/ios-e2e/run.sh). With
/// `RECEIPTS_ARCHIVE_HELPER_URL` and `RECEIPTS_ARCHIVE_HELPER_TOKEN` set it runs the real Mac sync engine (archive
/// device, temp data dir) against that server once: pull, download, verify, archive-confirm. Skipped otherwise.
final class ArchiveHelperTests: XCTestCase {
    func testRunTheMacArchiveOnce() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let urlText = env["RECEIPTS_ARCHIVE_HELPER_URL"], let token = env["RECEIPTS_ARCHIVE_HELPER_TOKEN"], let base = ServerURL.apiBase(from: urlText, policy: .anyHost) else {
            throw XCTSkip("only for Tests/ios-e2e/run.sh")
        }
        let dir = try makeTempDir("archive-helper")
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try openTempDatabase(in: dir)
        let archive = dir.appendingPathComponent("receipts_archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let store = SyncStore(db: db, paths: SyncPaths(appSupportDir: dir, archiveDir: archive))
        let engine = SyncEngine(api: URLSessionReceiptsAPI(baseURL: base, token: token), store: store, config: SyncConfig(cursorKey: "cursor:helper"))
        let report = await engine.syncNow()
        XCTAssertTrue(report.succeeded, "\(report.errors)")
        print("ARCHIVE-HELPER archived=\(report.archive?.archived.count ?? -1) waiting=\(report.archive?.savedWaiting.count ?? -1)")
        XCTAssertGreaterThan(report.archive?.archived.count ?? 0, 0)
    }
}
