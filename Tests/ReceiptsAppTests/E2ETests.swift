import CoreImage
import Darwin
import XCTest
@testable import ReceiptsApp

/// End to end: the Swift sync engine (real `URLSessionReceiptsAPI`, real SQLite database) against the real backend.
/// Only runs with `RECEIPTS_E2E=1` (see Tests/run-e2e.sh). The backend runs from a temp var dir with a dummy
/// receipts token, no LLM credentials and its worker thread off; extraction results come from the backend test
/// suite's fake provider through Tests/e2e/seed_extractions.py. The app side uses a temp data dir.
final class E2ETests: XCTestCase {
    private var root: URL!
    private var serverProcess: Process?
    private var port = 0
    private let token = "e2e-dummy-receipts-token"

    /// The server code lives in the FitnessBuddy repo: RECEIPTS_BACKEND_DIR, default ~/Projects/FitnessBuddy/backend.
    private var backendDir: URL {
        let env = ProcessInfo.processInfo.environment
        let path = env["RECEIPTS_BACKEND_DIR"] ?? (NSHomeDirectory() + "/Projects/FitnessBuddy/backend")
        return URL(fileURLWithPath: path)
    }
    private var seedScript: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("e2e/seed_extractions.py").path
    }
    private var serverVar: URL { root.appendingPathComponent("server-var") }
    private var photosDir: URL { serverVar.appendingPathComponent("receipts_photos") }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RECEIPTS_E2E"] == "1", "set RECEIPTS_E2E=1 (Tests/run-e2e.sh)")
        guard FileManager.default.fileExists(atPath: backendDir.appendingPathComponent("apps/receipts").path) else {
            throw NSError(domain: "E2ETests", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Server code not found at \(backendDir.path) (expected apps/receipts inside). It lives in the FitnessBuddy repo: "
                + "set RECEIPTS_BACKEND_DIR=/path/to/FitnessBuddy/backend"])
        }
        root = try makeTempDir("receipts-e2e")
    }

    override func tearDown() {
        stopServer()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - Processes

    private func serverEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let path = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = path + ":/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin"
        let fitnessDir = serverVar.appendingPathComponent("fitness")
        for (k, v) in [
            "DATABASE_URL": "sqlite:///\(fitnessDir.path)/fitness.db",
            "RECEIPTS_DATABASE_URL": "sqlite:///\(serverVar.path)/receipts.db",
            "RECEIPTS_PHOTOS_DIR": photosDir.path,
            "RECEIPTS_API_TOKEN": token,
            "API_TOKEN": "e2e-dummy-fitness-token",
            "RECEIPTS_WORKER_ENABLED": "false",
            "SCHEDULER_ENABLED": "false",
            "ANTHROPIC_API_KEY": "",
            "CLAUDE_CODE_OAUTH_TOKEN": "",
            "GARMIN_TOKEN_CACHE_PATH": fitnessDir.appendingPathComponent("garmin_token.json").path,
            "GARMIN_CONNECT_TOKEN_DIR": fitnessDir.appendingPathComponent("garminconnect").path,
            "GARMIN_FIT_DIR": fitnessDir.appendingPathComponent("fit").path,
            "NOTIFY_URL": "", "RECEIPTS_NOTIFY_URL": "",
        ] { env[k] = v }
        return env
    }

    @discardableResult
    private func run(_ arguments: [String], label: String, timeout: TimeInterval = 180) throws -> String {
        let log = root.appendingPathComponent("\(label)-\(UUID().uuidString.prefix(6)).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = backendDir
        process.environment = serverEnv()
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning { process.terminate(); XCTFail("\(label) timed out") }
        try? handle.close()
        let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "\(label) failed:\n\(output.suffix(2000))")
        return output
    }

    private func freePort() throws -> Int {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(bound, 0)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(fd, $0, &len) } }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    private func startServer() async throws -> URLSessionReceiptsAPI {
        try FileManager.default.createDirectory(at: serverVar.appendingPathComponent("fitness"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: photosDir, withIntermediateDirectories: true)
        // both migrations, as docker-entrypoint.sh does
        try run(["uv", "run", "alembic", "-c", "apps/fitness/alembic.ini", "upgrade", "head"], label: "alembic-fitness")
        try run(["uv", "run", "alembic", "-c", "apps/receipts/alembic.ini", "upgrade", "head"], label: "alembic-receipts")

        port = try freePort()
        let log = root.appendingPathComponent("uvicorn.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["uv", "run", "uvicorn", "server:app", "--host", "127.0.0.1", "--port", "\(port)"]
        process.currentDirectoryURL = backendDir
        process.environment = serverEnv()
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        serverProcess = process

        let base = URL(string: "http://127.0.0.1:\(port)/api/v1/receipts")!
        let api = URLSessionReceiptsAPI(baseURL: base, token: token)
        for _ in 0..<300 {
            if (try? await api.health()) != nil { return api }
            if !process.isRunning { break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        XCTFail("server did not start:\n\(output.suffix(3000))")
        throw ReceiptsAPIError.notConfigured("server did not start")
    }

    private func stopServer() {
        guard let process = serverProcess else { return }
        process.terminate()
        // `uv run` may sit between us and uvicorn: make sure the listener really goes away
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", "uvicorn server:app --host 127.0.0.1 --port \(port)"]
        try? pkill.run()
        pkill.waitUntilExit()
        // port closed AND the process gone (uvicorn shuts down gracefully, which takes a moment)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, canConnect(port: port) || process.isRunning || isRunning(pattern: "uvicorn server:app --host 127.0.0.1 --port \(port)") {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertFalse(canConnect(port: port), "the e2e server is still listening on \(port)")
        XCTAssertFalse(isRunning(pattern: "uvicorn server:app --host 127.0.0.1 --port \(port)"), "the e2e server process is still running")
        serverProcess = nil
    }

    private func isRunning(pattern: String) -> Bool {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", pattern]
        pgrep.standardOutput = FileHandle.nullDevice
        try? pgrep.run()
        pgrep.waitUntilExit()
        return pgrep.terminationStatus == 0
    }

    private func canConnect(port: Int) -> Bool {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = UInt16(port).bigEndian
        return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }

    // MARK: - Helpers

    private func jpeg(seed: Int) throws -> Data {
        let color = CIColor(red: CGFloat(seed % 7) / 7, green: CGFloat((seed * 3) % 11) / 11, blue: 0.5)
        let image = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 420 + seed, height: 600))
        return try XCTUnwrap(DocumentScanner.jpegData(from: image, maxDimension: 1024, quality: 0.9))
    }

    private func serverPhotoFiles(containing uuid: String) -> [URL] {
        (FileManager.default.enumerator(at: photosDir, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
            .filter { $0.path.contains(uuid) }
    }

    private struct App {
        let dir: URL, db: Database, paths: SyncPaths, store: SyncStore, engine: SyncEngine
    }

    private func makeApp(api: ReceiptsAPI, appDir: URL) throws -> App {
        let env = AppEnvironment.make(baseDir: appDir)
        XCTAssertTrue(env.appSupportDir.path.hasPrefix(root.path), "the e2e must only use its temp data dir")
        let db = try Database(path: env.dbPath, dataDir: env.appSupportDir)
        let store = SyncStore(db: db, paths: env.syncPaths)
        let engine = SyncEngine(api: api, store: store, config: SyncConfig(cursorKey: "cursor:e2e"))
        return App(dir: appDir, db: db, paths: env.syncPaths, store: store, engine: engine)
    }

    private func addPhoto(_ app: App, seed: Int) async throws -> (uuid: String, data: Data) {
        let uuid = LegacyIDs.newUUID()
        let data = try jpeg(seed: seed)
        try FileManager.default.createDirectory(at: app.paths.outboxDir, withIntermediateDirectories: true)
        let file = app.paths.outboxDir.appendingPathComponent("\(uuid).jpg")
        try AtomicFile.write(data, to: file)
        _ = try await app.store.insertPendingUpload(uuid: uuid, createdAt: Date(), photoPath: app.paths.stored(file), imageHash: nil)
        return (uuid, data)
    }

    private func serverReceipt(_ api: ReceiptsAPI, _ uuid: String) async throws -> WireReceipt? {
        try await api.pull(since: nil, limit: 5000).receipts.first { $0.id == uuid }
    }

    // MARK: - The run

    func testSwiftSyncEngineAgainstTheRealBackend() async throws {
        let backendVar = backendDir.appendingPathComponent("var")
        let marker = root.appendingPathComponent("marker")
        FileManager.default.createFile(atPath: marker.path, contents: nil)

        let api = try await startServer()

        // The token is enforced: a wrong one is refused.
        do {
            try await URLSessionReceiptsAPI(baseURL: api.baseURL, token: "wrong").status().self
            XCTFail("wrong token accepted")
        } catch let error as ReceiptsAPIError { XCTAssertEqual(error.status, 401) }

        // ---- Phase A: the Mac's existing data, migrated on the server by migrate_mac_data.py, then synced by the app.
        let appDir = root.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: appDir.appendingPathComponent("receipts_archive/2026/03"), withIntermediateDirectories: true)
        let dbPath = appDir.appendingPathComponent("receipts.db").path
        try LegacyDB.create(at: dbPath, LegacyDB.populateSample)
        for name in ["2026-03-01_edeka_1.jpg", "x.jpg"] {   // the photo files of receipts 1 and 3
            try jpeg(seed: name.count).write(to: appDir.appendingPathComponent("receipts_archive/2026/03/\(name)"))
        }
        let preSyncCopy = root.appendingPathComponent("mac-before-v7.db")
        try FileManager.default.copyItem(atPath: dbPath, toPath: preSyncCopy.path)   // what the operator hands to the script

        let dry = try run(["uv", "run", "python", "-m", "apps.receipts.migrate_mac_data", "--db", preSyncCopy.path, "--archive", appDir.appendingPathComponent("receipts_archive").path],
                          label: "migrate-dry-run")
        XCTAssertTrue(dry.contains("DRY RUN"), dry)
        let applied = try run(["uv", "run", "python", "-m", "apps.receipts.migrate_mac_data", "--db", preSyncCopy.path, "--archive", appDir.appendingPathComponent("receipts_archive").path, "--apply"],
                              label: "migrate-apply")
        XCTAssertTrue(applied.contains("receipts:") && applied.contains("3 new"), applied)

        let serverBefore = try await api.pull(since: nil, limit: 5000)
        XCTAssertEqual(serverBefore.receipts.count, 3)
        XCTAssertEqual(serverBefore.lineItems.count, 5)
        XCTAssertEqual(serverBefore.dictionary.count, 3)

        let app = try makeApp(api: api, appDir: appDir)   // opening the legacy database runs migration 7
        let localUUIDs = try await app.db.query("SELECT uuid FROM receipts ORDER BY id").compactMap { $0.string(0) }
        XCTAssertEqual(Set(localUUIDs), Set(serverBefore.receipts.map(\.id)), "local UUIDs equal the migration's: no duplicates possible")
        // updated_at agrees too (hence the push below is `stale` for everything)
        let localStamps = try await app.db.query("SELECT uuid, updated_at FROM receipts").reduce(into: [String: String]()) { $0[$1.string(0)!] = $1.string(1)! }
        for r in serverBefore.receipts {
            XCTAssertTrue(SyncDate.sameInstant(localStamps[r.id], r.updatedAt), "receipt \(r.id): local \(localStamps[r.id] ?? "-") vs server \(r.updatedAt)")
        }

        let first = await app.engine.syncNow()
        XCTAssertTrue(first.succeeded, "\(first.errors)")
        XCTAssertEqual(first.push.applied, 0, "nothing of the Mac's data replaced the server's: \(first.push)")
        XCTAssertGreaterThan(first.push.stale, 0)
        let serverAfter = try await api.pull(since: nil, limit: 5000)
        XCTAssertEqual(serverAfter.receipts.count, 3, "no receipt was duplicated")
        XCTAssertEqual(serverAfter.lineItems.count, 5)
        XCTAssertEqual(serverAfter.dictionary.count, 3)
        let localCount = try await app.db.scalarInt("SELECT COUNT(*) FROM receipts")
        let localItems = try await app.db.scalarInt("SELECT COUNT(*) FROM line_items")
        XCTAssertEqual(localCount, 3)
        XCTAssertEqual(localItems, 6, "the orphan item is still there locally, never pushed")
        let unsent = try await app.store.unsentChangeCount()
        XCTAssertEqual(unsent, 0)
        let status0 = try await api.status()
        XCTAssertEqual(status0.archiveDeviceId, "macbook-archive", "this Mac identified itself as the archive device")
        XCTAssertNotNil(status0.lastArchiveSyncAt)
        XCTAssertFalse(status0.archiveOverdue)

        // ---- Phase B: upload, extraction (seeded), download, verified write, confirm.
        let one = try await addPhoto(app, seed: 1)
        let up = await app.engine.uploadOne(uuid: one.uuid)
        XCTAssertEqual(up.uploaded, 1, "\(up.errors)")
        XCTAssertEqual(serverPhotoFiles(containing: one.uuid).count, 1, "the server stores the photo")
        let queued = try await serverReceipt(api, one.uuid)
        XCTAssertEqual(queued?.extractionStatus, "queued")
        XCTAssertEqual(queued?.photoSha256, Sha256.hex(one.data))

        // no LLM credential: the receipt stays queued, so the photo is saved here but must NOT be confirmed
        let waiting = await app.engine.syncNow()
        XCTAssertTrue(waiting.succeeded, "\(waiting.errors)")
        XCTAssertEqual(waiting.archive?.savedWaiting, [one.uuid])
        XCTAssertEqual(serverPhotoFiles(containing: one.uuid).count, 1, "not archivable yet: the server keeps its copy")
        let saved = FileManager.default.enumerator(at: app.paths.archiveDir, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }
            .first { $0.lastPathComponent.hasPrefix(one.uuid) }
        let savedPath = try XCTUnwrap(saved)
        XCTAssertEqual(try Data(contentsOf: savedPath), one.data)

        // a second photo, finished BEFORE the next sync: download -> verified write -> confirm in one run
        let two = try await addPhoto(app, seed: 2)
        _ = await app.engine.uploadOne(uuid: two.uuid)
        let seeded = try run(["uv", "run", "python", seedScript], label: "seed-extractions")
        XCTAssertEqual(seeded.split(separator: "\n").last.map(String.init), "2", "both queued extractions were finished by the fake provider")
        let doneRun = await app.engine.syncNow()
        XCTAssertTrue(doneRun.succeeded, "\(doneRun.errors)")
        XCTAssertEqual(Set(doneRun.archive?.archived ?? []), [one.uuid, two.uuid])

        for photo in [one, two] {
            XCTAssertTrue(serverPhotoFiles(containing: photo.uuid).isEmpty, "server file of \(photo.uuid) is gone after the confirmation")
            let local = try await app.db.queryOne("SELECT source_image, photo_location, extraction_status, store, total FROM receipts WHERE uuid = ?", [.text(photo.uuid)])
            XCTAssertEqual(local?.string(1), "archived")
            XCTAssertEqual(local?.string(2), "done")
            XCTAssertEqual(local?.string(3), "Edeka", "the extraction result arrived through pull")
            let file = try XCTUnwrap(app.paths.resolve(local?.string(0)))
            XCTAssertEqual(try Data(contentsOf: file), photo.data, "the local archive file is intact")
            XCTAssertEqual(Sha256.hex(try Data(contentsOf: file)), Sha256.hex(photo.data))
            XCTAssertFalse(FileManager.default.fileExists(atPath: app.paths.outboxDir.appendingPathComponent("\(photo.uuid).jpg").path))
            let onServer = try await serverReceipt(api, photo.uuid)
            XCTAssertEqual(onServer?.photoLocation, "archived")
            XCTAssertNotNil(onServer?.archivedAt)
        }
        let items = try await app.db.scalarInt("SELECT COUNT(*) FROM line_items li JOIN receipts r ON r.id = li.receipt_id WHERE r.uuid IN (?, ?)", [.text(one.uuid), .text(two.uuid)])
        XCTAssertEqual(items, 4, "two items per extracted receipt")
        // an archived photo cannot be downloaded any more, and the status counts nothing unarchived
        do { _ = try await api.downloadPhoto(path: "/api/v1/receipts/\(one.uuid)/photo"); XCTFail("download of an archived photo succeeded") }
        catch let error as ReceiptsAPIError { XCTAssertEqual(error.status, 410) }
        let status1 = try await api.status()
        XCTAssertEqual(status1.unarchivedCount, 0)

        // ---- Phase C: the server's own rules, from the client's side
        let three = try await addPhoto(app, seed: 3)
        _ = await app.engine.uploadOne(uuid: three.uuid)
        _ = try run(["uv", "run", "python", seedScript], label: "seed-extractions")
        do {   // a wrong checksum is refused and the server keeps the file
            _ = try await api.archiveConfirm(id: three.uuid, sha256: String(repeating: "0", count: 64), deviceId: "macbook-archive", acceptFailed: false)
            XCTFail("a wrong checksum was accepted")
        } catch let error as ReceiptsAPIError { XCTAssertEqual(error.code, "sha256_mismatch") }
        XCTAssertEqual(serverPhotoFiles(containing: three.uuid).count, 1, "the server kept the photo after a mismatch")
        // an upload of the same photo again (idempotent, and a duplicate under another id)
        let again = try await api.uploadPhoto(id: three.uuid, data: three.data, mediaType: "image/jpeg", createdAt: nil)
        XCTAssertFalse(again.created)
        do { _ = try await api.uploadPhoto(id: LegacyIDs.newUUID(), data: three.data, mediaType: "image/jpeg", createdAt: nil); XCTFail("duplicate accepted") }
        catch let error as ReceiptsAPIError { XCTAssertEqual(error.code, "duplicate_image"); XCTAssertEqual(error.extra["duplicate_of"], three.uuid) }

        // edits and deletes travel both ways
        let editedID = try await app.store.localID(forUUID: one.uuid)!
        try await app.db.run("UPDATE receipts SET store = 'Edeka Test', reviewed_at = ? WHERE id = ?", [.text(SyncDate.now()), .from(editedID)])
        let itemToDelete = try await app.db.queryOne("SELECT id, uuid FROM line_items WHERE receipt_id = ? LIMIT 1", [.from(editedID)])
        try await app.db.run("DELETE FROM line_items WHERE id = ?", [.from(itemToDelete!.int(0)!)])
        let last = await app.engine.syncNow()
        XCTAssertTrue(last.succeeded, "\(last.errors)")
        XCTAssertEqual(Set(last.archive?.archived ?? []), [three.uuid])
        XCTAssertTrue(serverPhotoFiles(containing: three.uuid).isEmpty)
        let edited = try await serverReceipt(api, one.uuid)
        XCTAssertEqual(edited?.store, "Edeka Test")
        XCTAssertNotNil(edited?.reviewedAt)
        let finalPull = try await api.pull(since: nil, limit: 5000)
        XCTAssertNotNil(finalPull.lineItems.first { $0.id == itemToDelete!.string(1) }?.deletedAt, "the delete arrived as a tombstone")
        let unsentEnd = try await app.store.unsentChangeCount()
        XCTAssertEqual(unsentEnd, 0)

        // a second Mac (empty database, same server) receives everything
        let second = try makeApp(api: api, appDir: root.appendingPathComponent("second-mac"))
        let secondRun = await second.engine.syncNow()
        XCTAssertTrue(secondRun.succeeded, "\(secondRun.errors)")
        let secondReceipts = try await second.db.scalarInt("SELECT COUNT(*) FROM receipts")
        XCTAssertEqual(secondReceipts, 6, "3 migrated + 3 uploaded")

        // nothing outside the temp dirs was touched
        let touched = try FileManager.default.contentsOfDirectory(atPath: backendVar.path).filter {
            let attrs = try? FileManager.default.attributesOfItem(atPath: backendVar.appendingPathComponent($0).path)
            return (attrs?[.modificationDate] as? Date).map { $0 > ((try? FileManager.default.attributesOfItem(atPath: marker.path)[.modificationDate] as? Date) ?? Date.distantFuture) } ?? false
        }
        XCTAssertTrue(touched.isEmpty, "backend/var was modified: \(touched)")
    }
}
