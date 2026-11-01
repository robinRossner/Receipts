import Foundation

struct SyncConfig: Sendable {
    /// What this device calls itself on the archive endpoints and in push (the Mac: `macbook-archive`).
    var deviceId = "macbook-archive"
    /// Cursor key, one per server (cursors are global to the server's database).
    var cursorKey: String
    var pageLimit = 2000
    var pushChunk = 400
    /// What this device may do. Only the archive device (the Mac) runs the archive protocol after every sync; the
    /// engine cannot call the archive endpoints without it (see `SyncCapabilities`).
    var capabilities = SyncCapabilities.archiveDevice
    var isArchiveDevice: Bool { capabilities.archivesPhotos }
    static let maxPages = 500
}

struct SyncReport: Sendable {
    var uploaded = 0
    /// local uuid -> uuid of the receipt the server already has for the same photo (local copy dropped).
    var duplicates: [String: String] = [:]
    var push = PushSummary()
    var pulled = ApplySummary()
    var archive: ArchiveReport?
    var status: ServerStatus?
    var errors: [String] = []
    /// The run stopped early because the server is unreachable / refuses us (retry with backoff).
    var connectionProblem = false
    var finishedAt = Date()

    var succeeded: Bool { errors.isEmpty }
    /// Something changed locally that views should reload.
    var changedLocalData: Bool {
        uploaded > 0 || !duplicates.isEmpty || pulled.dictionary + pulled.receipts + pulled.lineItems + pulled.deletedLocally + pulled.taxonomyAdditions > 0
            || !(archive?.archived.isEmpty ?? true) || !(archive?.savedWaiting.isEmpty ?? true)
    }
}

/// Offline-first sync with the receipts backend (docs/api/receipts.md): upload queued photos, push local edits, pull
/// the server's changes with the stored cursor, then run the photo archive protocol.
///
/// Last write wins per record by `updated_at` (`SyncMerge`), deletes are tombstones, and the cursor is persisted only
/// after a pulled page was applied. Every phase may fail on its own (the failure is reported, the rest still runs
/// unless the server itself is unreachable); nothing is lost, the next run repeats what failed.
actor SyncEngine {
    /// Always the capability-guarded wrapper: a device that is not the archive cannot reach the archive endpoints.
    let api: ReceiptsAPI
    let store: SyncStore
    let config: SyncConfig
    nonisolated let photoCache: PhotoCache
    private let archiver: PhotoArchiver
    private var current: Task<SyncReport, Never>?
    /// A push answered `stale` for a record we thought was ahead: the server holds something newer that may sit
    /// before our cursor, so the next pull starts from scratch (applying a record twice is harmless).
    private var needsFullPull = false

    init(api: ReceiptsAPI, store: SyncStore, config: SyncConfig, fileSystem: ArchiveFileSystem = DiskFileSystem()) {
        let guarded = CapabilityGuardedAPI(base: api, capabilities: config.capabilities)
        self.api = guarded
        self.store = store
        self.config = config
        self.photoCache = PhotoCache(dir: store.paths.photoCacheDir, maxBytes: config.capabilities.photoCacheBytes)
        self.archiver = PhotoArchiver(api: guarded, store: store, fileSystem: fileSystem, deviceId: config.deviceId)
    }

    /// One full run. Calls made while a run is in progress join it.
    func syncNow() async -> SyncReport {
        if let current { return await current.value }
        let task = Task { await self.runOnce() }
        current = task
        let report = await task.value
        current = nil
        return report
    }

    // MARK: - A run

    private func runOnce() async -> SyncReport {
        var report = SyncReport()
        func fail(_ phase: String, _ error: Error) -> Bool {
            report.errors.append("\(phase): \(error.localizedDescription)")
            if let api = error as? ReceiptsAPIError, api.isConnectionLevel { report.connectionProblem = true }
            return report.connectionProblem
        }

        do { try await uploadPending(&report) } catch { if fail("Upload", error) { return finish(report) } }
        var pushedOK = false, pulledOK = false
        do { try await pushAll(&report); pushedOK = true } catch { if fail("Push", error) { return finish(report) } }
        do { try await pullAll(&report); pulledOK = true } catch { if fail("Pull", error) { return finish(report) } }
        // "Synced" = what we had was sent and what the server had was received (a record the server rejected or a
        // photo problem does not change that).
        if pushedOK, pulledOK { try? await store.setMeta("last_sync_at", SyncDate.now()) }
        if config.isArchiveDevice {
            do { report.archive = try await archiver.run() } catch { if fail("Photo archive", error) { return finish(report) } }
            if let failures = report.archive?.failures, !failures.isEmpty {
                report.errors.append(contentsOf: failures.map { "Photo archive: \($0)" })
            }
        }
        do { report.status = try await api.status() } catch { _ = fail("Status", error) }
        return finish(report)
    }

    private func finish(_ report: SyncReport) -> SyncReport {
        var r = report
        r.finishedAt = Date()
        return r
    }

    // MARK: - Upload queue

    private func uploadPending(_ report: inout SyncReport) async throws {
        for pending in try await store.pendingUploads() {
            try await upload(pending, &report)
        }
    }

    private func upload(_ pending: PendingUpload, _ report: inout SyncReport) async throws {
        guard let url = store.paths.resolve(pending.photoPath), let data = try? Data(contentsOf: url) else {
            try await store.markUploadFailed(uuid: pending.uuid, message: "The prepared photo file is missing; add the photo again.", permanent: true)
            return
        }
        do {
            let response = try await api.uploadPhoto(id: pending.uuid, data: data, mediaType: PhotoPreparer.mediaType(of: data),
                                                     createdAt: SyncDate.parse(pending.createdAt))
            try await store.markUploaded(uuid: pending.uuid, server: response.receipt)
            await keepCachedCopy(of: pending, mediaType: PhotoPreparer.mediaType(of: data))
            report.uploaded += 1
        } catch let error as ReceiptsAPIError {
            if error.code == "duplicate_image", let existing = error.extra["duplicate_of"] {
                // "drop your local receipt and use the existing one" (it arrives through pull)
                if let path = try await store.discardLocalReceipt(uuid: pending.uuid), let file = store.paths.resolve(path) {
                    try? FileManager.default.removeItem(at: file)
                }
                report.duplicates[pending.uuid] = existing.lowercased()
            } else if error.isConnectionLevel || error.isRetryable {
                try await store.markUploadFailed(uuid: pending.uuid, message: error.localizedDescription, permanent: false)
                throw error
            } else {
                try await store.markUploadFailed(uuid: pending.uuid, message: error.localizedDescription, permanent: true)
            }
        }
    }

    /// A phone keeps the photo it just uploaded as its (bounded) cached copy instead of deleting it. Best effort: the
    /// upload itself is done, so a failure here only means the photo is downloaded again when it is opened.
    private func keepCachedCopy(of pending: PendingUpload, mediaType: String) async {
        guard config.capabilities.cachesPhotos, let source = store.paths.resolve(pending.photoPath),
              let cached = try? photoCache.adopt(source, uuid: pending.uuid, mediaType: mediaType) else { return }
        try? await store.setLocalPhoto(uuid: pending.uuid, path: store.paths.stored(cached))
    }

    /// The server's answer to one upload outside a full run (the upload queue UI), same handling.
    func uploadOne(uuid: String) async -> SyncReport {
        var report = SyncReport()
        do {
            if let pending = try await store.pendingUpload(uuid: uuid) { try await upload(pending, &report) }
        } catch {
            report.errors.append("Upload: \(error.localizedDescription)")
            if let api = error as? ReceiptsAPIError, api.isConnectionLevel { report.connectionProblem = true }
        }
        return finish(report)
    }

    // MARK: - Push

    private func pushAll(_ report: inout SyncReport) async throws {
        // new category paths, then dictionary, receipts, line items: a record may only reference what the server already has
        for entity in [PushResult.Entity.taxonomyAddition, .dictionary, .receipt, .lineItem] {
            var rounds = 0
            while rounds < 100 {
                rounds += 1
                let batch = try await store.collectPush(entity, limit: config.pushChunk)
                if batch.isEmpty { break }
                let request = PushRequest(deviceId: config.deviceId, dictionary: batch.dictionary, receipts: batch.receipts, lineItems: batch.lineItems,
                                          taxonomyAdditions: batch.taxonomyAdditions.isEmpty ? nil : batch.taxonomyAdditions)
                let response = try await api.push(request)
                let summary = try await store.applyPushResults(batch: batch, response: response)
                report.push.applied += summary.applied
                report.push.stale += summary.stale
                report.push.rejected += summary.rejected
                if summary.stale > 0 { needsFullPull = true }
                // Nothing acknowledged and nothing rejected means the same chunk would come back: stop.
                if summary.applied + summary.stale + summary.rejected.count == 0 { break }
            }
        }
        if !report.push.rejected.isEmpty {
            report.errors.append("Push: \(report.push.rejected.count) record(s) rejected by the server, first: \(report.push.rejected[0])")
        }
    }

    // MARK: - Pull

    private func pullAll(_ report: inout SyncReport) async throws {
        var cursor = needsFullPull ? nil : try await store.meta(config.cursorKey)
        var restarted = false
        var dictionary: [String: WireDictionaryEntry] = [:]
        var receipts: [String: WireReceipt] = [:]
        var items: [String: WireLineItem] = [:]
        var additions: [WireTaxonomyAddition] = []
        var pages = 0
        while true {
            pages += 1
            let page: PullResponse
            do {
                page = try await api.pull(since: cursor, limit: config.pageLimit)
            } catch let error as ReceiptsAPIError where error.code == "bad_cursor" && !restarted {
                restarted = true; cursor = nil
                dictionary = [:]; receipts = [:]; items = [:]; additions = []
                continue
            }
            // Later versions of a record supersede earlier ones; everything is applied together below.
            for d in page.dictionary { dictionary[d.id] = d }
            for r in page.receipts { receipts[r.id] = r }
            for l in page.lineItems { items[l.id] = l }
            if let a = page.taxonomyAdditions { additions = a }   // every page carries the full list
            cursor = page.cursor
            if !page.hasMore || pages >= SyncConfig.maxPages { break }
        }
        // Applied first, cursor persisted second: a crash in between just repeats the pull.
        report.pulled = try await store.applyPull(dictionary: Array(dictionary.values), receipts: Array(receipts.values), lineItems: Array(items.values), taxonomyAdditions: additions)
        if let cursor { try await store.setMeta(config.cursorKey, cursor) }
        needsFullPull = false
    }

    // MARK: - User actions

    /// "Retry" on a failed receipt: the server queues the extraction again with a fresh attempt budget.
    func retryExtraction(uuid: String) async throws {
        do {
            try await api.retryExtraction(id: uuid)
        } catch let error as ReceiptsAPIError where error.code == "already_queued" {
            // fine: it is queued or running
        }
        try await store.db.run("UPDATE receipts SET extraction_status = 'queued', extraction_error = NULL WHERE uuid = ?", [.text(uuid)])
    }

    /// Runs just the archive protocol (after the user chose to give up on a failed receipt, whose photo may then go).
    /// Only the archive device may; anything else gets `notPermitted` without a request.
    func archiveNow() async throws -> ArchiveReport {
        guard config.capabilities.archivesPhotos else {
            throw ReceiptsAPIError.notPermitted("This device is not the photo archive.")
        }
        return try await archiver.run()
    }

    // MARK: - Photos on the phone

    enum PhotoFetchResult: Equatable, Sendable {
        /// The photo is in the local cache (stored path, relative to the app-support dir).
        case cached(String)
        /// The server released its copy to the laptop and there is no copy here.
        case onLaptop
        case unavailable(String)
    }

    /// Makes sure a cached copy of a receipt's photo exists: downloads it from the server when the server still holds
    /// it. A photo that was archived (410) and is not here is "on your laptop". The checksum must equal the
    /// server's `photo_sha256`, else nothing is kept.
    func ensurePhoto(uuid: String) async -> PhotoFetchResult {
        guard config.capabilities.cachesPhotos else { return .unavailable("This device does not keep photo copies.") }
        do {
            guard let info = try await store.archiveInfo(uuid: uuid) else { return .unavailable("Unknown receipt.") }
            if let url = store.paths.resolve(info.sourceImage), FileManager.default.fileExists(atPath: url.path) {
                return .cached(info.sourceImage ?? "")
            }
            if info.photoLocation == "archived" { return .onLaptop }
            if info.photoLocation != "server" { return .unavailable("This receipt has no photo.") }
            let download: DownloadedPhoto
            do {
                download = try await api.downloadPhoto(path: "\(ServerURL.apiPath)/\(uuid)/photo")
            } catch let error as ReceiptsAPIError where error.code == "photo_archived" {
                return .onLaptop
            }
            if let expected = try await store.photoSHA256(uuid: uuid), Sha256.hex(download.data) != expected.lowercased() {
                return .unavailable("The downloaded photo did not match the server's checksum.")
            }
            let url = try photoCache.write(download.data, uuid: uuid, mediaType: download.mediaType)
            try await store.setLocalPhoto(uuid: uuid, path: store.paths.stored(url))
            return .cached(store.paths.stored(url))
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    /// "Clear cached photos": removes the local copies (receipts keep their data).
    func clearPhotoCache() {
        photoCache.removeAll()
    }
}
