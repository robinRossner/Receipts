import Foundation

/// Cloud sync, from the app's side: starting it, the upload of new photos (straighten here, the server reads them), and
/// the user actions on receipts the server could not read.
extension ReceiptStore {
    // MARK: - Lifecycle

    /// At launch: wire the "data changed" callback and start (or stay off) according to the settings.
    func startSync() {
        sync.onDataChanged = { [weak self] in
            guard let self else { return }
            await self.refreshList()
            if let id = self.selectedReceiptID { await self.loadReceiptDetail(id: id) }
        }
        sync.configure()
    }

    /// Settings changed (switch, URL, token): re-read them after a short pause (the URL field reports every keystroke).
    func syncSettingsChanged() {
        syncSettingsTask?.cancel()
        syncSettingsTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.sync.configure()
        }
    }

    func syncNow() {
        Task { await sync.syncNow() }
    }

    // MARK: - Upload of a new photo with cloud sync on

    /// Copies the file to staging, checks it was not imported before, straightens it with `DocumentScanner`, converts it to
    /// a JPEG of about 2500 px under 5 MB, stores it in the upload outbox with a new receipt (so nothing is lost if the
    /// server is out of reach) and sends it. The server extracts; the result arrives through sync.
    func runCloudUploadJob(id: UUID) async {
        guard let job = uploadQueue.first(where: { $0.id == id }) else { return }
        // A retry of a photo that is already prepared and stored: only the upload is repeated.
        if let uuid = job.cloudReceiptUUID { await sendCloudUpload(jobID: id, uuid: uuid); return }

        let fileURL = job.fileURL
        let ext = fileURL.pathExtension.isEmpty ? "jpg" : fileURL.pathExtension
        let stagingDir = env.appSupportDir.appendingPathComponent("uploads_incoming", isDirectory: true)
        try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let tempURL = stagingDir.appendingPathComponent("\(UUID().uuidString).\(ext)")
        let accessed = fileURL.startAccessingSecurityScopedResource()
        defer { if accessed { fileURL.stopAccessingSecurityScopedResource() } }
        let takenAt = (try? fileURL.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        do {
            try FileManager.default.copyItem(at: fileURL, to: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            setState(.failed("Couldn't read the file: \(error.localizedDescription)"), for: id)
            return
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }
        guard !Task.isCancelled else { setState(.cancelled, for: id); return }

        let imagePath = tempURL.path
        let hash = await Task.detached(priority: .userInitiated) { try? ReceiptPipeline.sha256Hex(ofFileAt: imagePath) }.value
        if let hash { await acquireHash(hash) }
        defer { if let hash { releaseHash(hash) } }
        if let hash, let dup = try? await db.queryOne("SELECT id FROM receipts WHERE image_hash = ? AND deleted_at IS NULL ORDER BY id LIMIT 1", [.text(hash)]),
           let dupId = dup.int(0) {
            setState(.duplicate(receiptId: dupId), for: id)
            return
        }
        guard !Task.isCancelled else { setState(.cancelled, for: id); return }

        let prepared: Result<Data, Error> = await Task.detached(priority: .userInitiated) {
            Result { try PhotoPreparer.prepare(imagePath: imagePath) }
        }.value
        guard !Task.isCancelled else { setState(.cancelled, for: id); return }
        let data: Data
        switch prepared {
        case .success(let bytes): data = bytes
        case .failure(let error):
            setState(.failed("\(error.localizedDescription) Try a clearer, flatter photo."), for: id)
            return
        }

        let uuid = LegacyIDs.newUUID()
        let file = env.syncPaths.outboxDir.appendingPathComponent("\(uuid).jpg")
        do {
            try AtomicFile.write(data, to: file)
            _ = try await sync.store.insertPendingUpload(uuid: uuid, createdAt: min(takenAt, Date()), photoPath: env.syncPaths.stored(file), imageHash: hash)
        } catch {
            try? FileManager.default.removeItem(at: file)
            setState(.failed("Couldn't store the prepared photo: \(error.localizedDescription)"), for: id)
            return
        }
        if let i = uploadQueue.firstIndex(where: { $0.id == id }) { uploadQueue[i].cloudReceiptUUID = uuid }
        invalidateStatsCache()
        if let rows = try? await fetchSummaries(deleted: false) { receipts = rows }   // the receipt shows up as "waiting to upload"
        await sendCloudUpload(jobID: id, uuid: uuid)
    }

    private func sendCloudUpload(jobID id: UUID, uuid: String) async {
        setState(.uploading, for: id)
        if let local = try? await sync.store.localID(forUUID: uuid) { try? await sync.store.requeueUpload(localID: local) }
        guard let report = await sync.upload(uuid: uuid) else {
            setState(.failed("Cloud sync is not set up. The photo is saved and uploads as soon as it is."), for: id)
            return
        }
        if let existing = report.duplicates[uuid] {
            var local = try? await sync.store.localID(forUUID: existing)
            if local == nil { await sync.syncNow(); local = try? await sync.store.localID(forUUID: existing) }
            if let local {
                setState(.duplicate(receiptId: local), for: id)
            } else {
                setState(.failed("Already on the server under another receipt; it appears after the next sync."), for: id)
            }
            await refreshList()
            return
        }
        guard report.uploaded > 0, let localId = try? await sync.store.localID(forUUID: uuid) else {
            setState(.failed("\(report.errors.first ?? "Upload failed"). It retries automatically."), for: id)
            return
        }
        setState(.uploaded(receiptId: localId), for: id)
        invalidateStatsCache()
        if let rows = try? await fetchSummaries(deleted: false) { receipts = rows }
        if uploadQueue.count == 1 { await loadReceiptDetail(id: localId) }
    }

    // MARK: - Receipts the server could not read, or could not receive

    /// Queues the extraction on the server again (fresh attempt budget).
    func retryServerExtraction(id: Int) async {
        guard let uuid = try? await sync.store.uuid(forLocalReceipt: id) else { return }
        busyReceiptIDs.insert(id)
        defer { busyReceiptIDs.remove(id) }
        do {
            try await sync.retryExtraction(uuid: uuid)
        } catch {
            lastError = "Retrying the extraction failed: \(error.localizedDescription)"
        }
        await refreshList()
        if selectedReceiptID == id { await loadReceiptDetail(id: id) }
    }

    /// Puts a photo the server refused (not an image, too large) back in the upload queue.
    func retryUpload(id: Int) async {
        try? await sync.store.requeueUpload(localID: id)
        await refreshList()
        await sync.syncNow()
    }

    /// Removes a receipt that never reached the server (its photo could not be uploaded).
    func discardFailedUpload(id: Int) async {
        guard let uuid = try? await sync.store.uuid(forLocalReceipt: id) else { return }
        if let path = try? await sync.store.discardLocalReceipt(uuid: uuid), let file = env.syncPaths.resolve(path) {
            try? FileManager.default.removeItem(at: file)
        }
        if selectedReceiptID == id { selectedReceipt = nil; selectedReceiptID = nil }
        await refreshList()
    }

    /// The user's explicit choice to give up on a receipt the server could not read: its photo is archived here anyway
    /// (the only place `accept_failed` is ever sent), and then leaves the server.
    func giveUpAndArchive(id: Int) async {
        await sync.acceptFailedAndArchive(localID: id)
        await refreshList()
        if selectedReceiptID == id { await loadReceiptDetail(id: id) }
    }
}
