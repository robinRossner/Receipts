import Combine
import Foundation

/// Top-level tab of the Mac window (the iPhone app has its own tab bar).
enum AppPage {
    case review
    case overview
}

/// Ports every endpoint from api.py into plain async methods that SwiftUI views call directly -
/// no HTTP, no JSON serialization boundary, no CORS, since there's no separate server process
/// anymore. `@Published` state drives the UI the same way the dashboard's re-fetch-and-render
/// calls did.
@MainActor
final class ReceiptStore: ObservableObject {
    let env: AppEnvironment
    let db: Database
    let taxonomy: Taxonomy
    /// LLM providers + pipeline switches, rebuilt from LLMSettings whenever Settings change.
    private(set) var services: PipelineServices
    /// Cloud sync (off by default): schedules the sync engine and publishes its status for the views.
    let sync: SyncCoordinator

    struct HighlightRequest: Equatable {
        let receiptId: Int
        let itemDictionaryId: Int
        let token: UUID
    }

    @Published var receipts: [ReceiptSummary] = []
    @Published var selectedReceipt: ReceiptDetail?
    @Published var isProcessingUpload = false
    /// Batch upload queue, shown in the review sidebar. Jobs stay until cleared.
    @Published var uploadQueue: [UploadJob] = []
    /// Set by File > Import Receipts… (⌘O) and the upload zone; presents the file picker.
    @Published var isImporterPresented = false
    private var uploadTasks: [UUID: Task<Void, Never>] = [:]
    private var inFlightHashes: Set<String> = []
    private var hashWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    @Published var deletedReceipts: [ReceiptSummary] = []
    /// Last failed database/file operation, shown as a dismissible banner in ContentView.
    @Published var lastError: String?
    /// From the selected AI backend's readiness() check; shown in the top bar.
    @Published var providerWarning: String?
    @Published var highlightRequest: HighlightRequest?
    /// Top-level tab; lives here so menu commands (⌘1 / ⌘2) can switch it.
    @Published var page: AppPage = .review
    /// Id-based selection, set the moment a row is picked (before the detail finishes loading).
    @Published var selectedReceiptID: Int?
    /// Bumped by Edit > Find (⌘F); the search field focuses itself when it changes.
    @Published var searchFocusToken = UUID()
    /// Presents the delete confirmation for the selected receipt (button and ⌘⌫ share it).
    @Published var deleteConfirmationPresented = false
    @Published var isCheckingProvider = false
    /// Receipts currently being re-extracted / re-categorized.
    @Published var busyReceiptIDs: Set<Int> = []
    /// Overview's current range (set by OverviewView) so File > Export… can offer "current range".
    @Published var overviewRange: (start: String?, end: String?, label: String) = (nil, nil, "All time")
    @Published var exportSheetPresented = false
    #if os(macOS)
    @Published var lastBackupDate: Date? = BackupService.lastBackupDate
    #endif
    /// Why a receipt's photo cannot be shown right now (phone: the download failed), by local receipt id.
    @Published var photoFetchNotes: [Int: String] = [:]
    /// Stats query results, dropped whenever data changes (see invalidateStatsCache).
    var statsCache: [String: Any] = [:]
    func invalidateStatsCache() { statsCache.removeAll() }

    // Search & filters for the receipt list.
    enum DateRange: String, CaseIterable, Identifiable {
        case all = "All time", thisMonth = "This month", last3Months = "Last 3 months", thisYear = "This year"
        var id: String { rawValue }
    }
    @Published var searchText = "" { didSet { scheduleSearch() } }
    @Published var dateRange: DateRange = .all
    @Published var storeFilter: String?
    /// Receipt ids matching `searchText` (store, item names de/en, amount); nil = no search active.
    @Published private(set) var searchMatches: Set<Int>?
    private var searchTask: Task<Void, Never>?
    var syncSettingsTask: Task<Void, Never>?

    /// Mirrors goToReceiptItem() in dashboard.html: jump to the Review tab, load the receipt,
    /// and let the view scroll to + briefly highlight the matching item group.
    func jumpToItem(receiptId: Int, itemDictionaryId: Int) async {
        await loadReceiptDetail(id: receiptId)
        highlightRequest = HighlightRequest(receiptId: receiptId, itemDictionaryId: itemDictionaryId, token: UUID())
    }

    /// `capabilities` says which device this is: the default (Mac) archives photos; the iPhone passes `.mobile`.
    init(env: AppEnvironment, db: Database, taxonomy: Taxonomy, settings: LLMSettings = .load(),
         capabilities: SyncCapabilities = .archiveDevice, deviceId: String = "macbook-archive",
         reminders: ReminderScheduling? = nil) {
        self.env = env
        self.db = db
        self.taxonomy = taxonomy
        self.settings = settings
        self.services = ProviderFactory.makeServices(settings: settings, env: env)
        self.sync = SyncCoordinator(
            store: SyncStore(db: db, paths: env.syncPaths), capabilities: capabilities, deviceId: deviceId,
            reminders: reminders ?? (capabilities.archivesPhotos ? UserNotificationReminder() : NoReminders())
        )
    }

    func report(_ action: String, _ error: Error) {
        lastError = "\(action) failed: \(error)"
    }

    // MARK: - AI backend

    private var settings: LLMSettings
    private var readinessTask: Task<Void, Never>?

    /// Asks the selected backend whether it's usable (Ollama: starts `ollama serve`, checks models).
    func checkProviderReadiness() async {
        isCheckingProvider = true
        defer { isCheckingProvider = false }
        let health = services.health
        providerWarning = await health.readiness().warningMessage
    }

    /// Called by SettingsView after any change: rebuilds the providers from the stored settings
    /// and, if anything backend-related changed, re-checks readiness (debounced, since text
    /// fields report every keystroke). Receipts already processing keep their old services.
    /// `secretsChanged`: an API key / token was saved or cleared in the Keychain, which the
    /// UserDefaults-backed settings can't see.
    func applySettings(secretsChanged: Bool = false) {
        let newSettings = LLMSettings.load()
        guard newSettings != settings || secretsChanged else { return }
        var backendOnly = newSettings
        backendOnly.debugDump = settings.debugDump
        let backendChanged = backendOnly != settings || secretsChanged
        settings = newSettings
        services = ProviderFactory.makeServices(settings: newSettings, env: env)
        guard backendChanged else { return }
        readinessTask?.cancel()
        readinessTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            await self?.checkProviderReadiness()
        }
    }

    // MARK: - Listing / detail (GET /receipts, GET /receipts/{id})

    func refreshList() async {
        invalidateStatsCache()
        do {
            receipts = try await fetchSummaries(deleted: false)
            deletedReceipts = try await fetchSummaries(deleted: true)
        } catch {
            report("Loading receipts", error)
        }
        await runSearch()
        await sync.syncIfLocalChangesPending()   // an edit just changed the data: sync soon (no-op with sync off)
    }

    // MARK: - Search / filter / selection order

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            await self?.runSearch()
        }
    }

    private func runSearch() async {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { searchMatches = nil; return }
        let like = "%\(q.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: "_", with: ""))%"
        // Amounts: accept "12,50" and "€12.50"; compare against the total as text with 2 decimals.
        let amount = "%\(q.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "€", with: "").trimmingCharacters(in: .whitespaces))%"
        do {
            let rows = try await db.query("""
                SELECT DISTINCT r.id FROM receipts r
                LEFT JOIN line_items li ON li.receipt_id = r.id
                LEFT JOIN item_dictionary d ON d.id = li.item_dictionary_id
                WHERE r.deleted_at IS NULL AND (r.store LIKE ? OR li.name_de LIKE ? OR d.translation_en LIKE ?
                    OR printf('%.2f', r.total) LIKE ?)
                """, [.text(like), .text(like), .text(like), .text(amount)])
            guard !Task.isCancelled else { return }
            searchMatches = Set(rows.compactMap { $0.int(0) })
        } catch { report("Searching receipts", error) }
    }

    /// Stores to offer in the filter menu and as suggestions: canonical chains + stores already in use.
    var knownStores: [String] {
        Set(ReceiptPipeline.canonicalStoreNames).union(receipts.compactMap(\.store).filter { !$0.isEmpty }).sorted()
    }
    var storesInUse: [String] { Set(receipts.compactMap(\.store).filter { !$0.isEmpty }).sorted() }

    private var dateCutoff: String? {
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        let start: Date?
        switch dateRange {
        case .all: start = nil
        case .thisMonth: start = cal.dateInterval(of: .month, for: now)?.start
        case .last3Months: start = cal.date(byAdding: .month, value: -3, to: now)
        case .thisYear: start = cal.dateInterval(of: .year, for: now)?.start
        }
        guard let start else { return nil }
        return ReceiptDateFormat.dateString(from: start)
    }

    /// `receipts` (already SQL-ordered date DESC) narrowed by search, date range and store.
    var filteredReceipts: [ReceiptSummary] {
        let cutoff = dateCutoff
        return receipts.filter { r in
            if let matches = searchMatches, !matches.contains(r.id) { return false }
            if let storeFilter, r.store != storeFilter { return false }
            if let cutoff, (r.date ?? "") < cutoff { return false }
            return true
        }
    }
    var isFiltering: Bool { searchMatches != nil || dateRange != .all || storeFilter != nil }

    /// Order the list shows rows in (needs review first), used for ↑/↓ navigation.
    var displayOrder: [ReceiptSummary] {
        let f = filteredReceipts
        return f.filter { $0.reviewedAt == nil } + f.filter { $0.reviewedAt != nil }
    }

    func selectAdjacentReceipt(offset: Int) async {
        let order = displayOrder
        guard !order.isEmpty else { return }
        let idx = order.firstIndex { $0.id == selectedReceiptID }
        let target = idx.map { min(max($0 + offset, 0), order.count - 1) } ?? (offset > 0 ? 0 : order.count - 1)
        guard order[target].id != selectedReceiptID else { return }
        await loadReceiptDetail(id: order[target].id)
    }

    func fetchSummaries(deleted: Bool) async throws -> [ReceiptSummary] {
        // Receipts still being uploaded / read / failed come first (so a new photo is visible at once), then by date.
        let pendingFirst = "CASE WHEN extraction_status IN ('pending_upload', 'upload_failed', 'queued', 'processing', 'failed') THEN 0 ELSE 1 END"
        let rows = try await db.query("""
            SELECT id, store, date, time, total, needs_review, reviewed_at, extraction_status, extraction_error
            FROM receipts WHERE deleted_at IS \(deleted ? "NOT NULL" : "NULL")
            ORDER BY \(deleted ? "deleted_at DESC" : "\(pendingFirst), date DESC, id DESC")
            """)
        return rows.map { row in
            ReceiptSummary(
                id: row.int(0) ?? 0, store: row.string(1), date: row.string(2), time: row.string(3),
                total: row.double(4), needsReview: row.bool(5), reviewedAt: row.string(6),
                processing: ReceiptProcessing(status: row.string(7), error: row.string(8))
            )
        }
    }

    func loadReceiptDetail(id: Int) async {
        selectedReceiptID = id
        do {
            let detail = try await fetchReceiptDetail(id: id)
            // A newer selection may have happened while this was loading.
            guard selectedReceiptID == id else { return }
            selectedReceipt = detail
            if detail == nil { selectedReceiptID = nil }
        } catch {
            selectedReceipt = nil
            report("Loading receipt #\(id)", error)
        }
    }

    private func fetchReceiptDetail(id: Int) async throws -> ReceiptDetail? {
        guard let row = try await db.queryOne("""
            SELECT id, store, date, time, total, computed_sum, needs_review, review_reasons, source_image, reviewed_at,
                   uuid, photo_location, extraction_status, extraction_error
            FROM receipts WHERE id = ? AND deleted_at IS NULL
            """, [.from(id)]) else { return nil }

        let itemRows = try await db.query("""
            SELECT li.id, li.item_dictionary_id, li.raw_text, li.name_de,
                   li.quantity, li.unit_price, li.total_price,
                   d.translation_en, d.category, d.subcategory, d.item_group, d.needs_review
            FROM line_items li JOIN item_dictionary d ON li.item_dictionary_id = d.id
            WHERE li.receipt_id = ? ORDER BY li.position, li.id
            """, [.from(id)])

        let items = itemRows.map { r in
            LineItemDetail(
                id: r.int(0) ?? 0, itemDictionaryId: r.int(1) ?? 0, rawText: r.string(2), nameDe: r.string(3),
                quantity: r.double(4) ?? 0, unitPrice: r.double(5) ?? 0, totalPrice: r.double(6) ?? 0,
                translationEn: r.string(7), category: r.string(8) ?? "", subcategory: r.string(9) ?? "",
                itemGroup: r.string(10) ?? "", needsReview: r.bool(11)
            )
        }

        let imagePath = env.resolveImagePath(row.string(8))
        let imageExists = imagePath.map { FileManager.default.fileExists(atPath: $0) } ?? false
        return ReceiptDetail(
            id: row.int(0) ?? 0, store: row.string(1), date: row.string(2), time: row.string(3),
            total: row.double(4), computedSum: row.double(5), needsReview: row.bool(6),
            reviewReasons: decodeStringArray(row.string(7)), sourceImage: imagePath, reviewedAt: row.string(9),
            items: items,
            uuid: row.string(10), processing: ReceiptProcessing(status: row.string(12), error: row.string(13)),
            photoLocation: row.string(11),
            photoNote: imageExists ? nil : Self.photoNote(location: row.string(11), hasPath: imagePath != nil, onArchiveDevice: sync.capabilities.archivesPhotos)
        )
    }

    /// Why a receipt has no photo to show. nil for the plain "file not found" of a local-only receipt (the photo view
    /// then names the path, as before sync existed).
    static func photoNote(location: String?, hasPath: Bool, onArchiveDevice: Bool = true) -> String? {
        if !onArchiveDevice {
            // The phone: the laptop is the archive. A photo the server still holds is downloaded on demand.
            switch location {
            case "archived": return "This photo is on your laptop."
            case "server": return "Loading the photo from the server…"
            default: return hasPath ? nil : "This receipt has no photo."
            }
        }
        switch location {
        case "server": return "This photo is still on the server. It is saved on this Mac, the photo archive, at the next sync."
        case "archived": return "This photo is archived on this Mac, but its file is missing here. It may have been moved or deleted."
        default: return hasPath ? nil : "This receipt has no photo."
        }
    }

    // MARK: - Upload (POST /receipts/upload)

    /// How many receipts may be in the pipeline at once, from the active backend chain. Local
    /// Ollama as the primary is GPU-bound, so it runs one at a time; the Claude API tolerates
    /// parallel requests; the CLI spawns a process per call, so keep it modest. Tune here.
    static func maxConcurrentUploads(for settings: LLMSettings) -> Int {
        switch ProviderFactory.backendChain(for: settings).first ?? .ollama {
        case .ollama: return 1
        case .anthropicAPI: return 3
        case .claudeSubscriptionToken, .claudeCodeLogin: return 2
        }
    }

    /// Adds files (and the image files directly inside any folders) to the queue and starts
    /// processing. Safe to call while a batch is running; new jobs just join the queue.
    func upload(fileURLs: [URL], preStraightened: Bool = false) {
        let (supported, unsupported) = UploadInput.expand(fileURLs)
        var added: [UploadJob] = []
        for url in supported {
            var job = UploadJob(fileURL: url)
            job.preStraightened = preStraightened
            added.append(job)
        }
        for url in unsupported {
            var job = UploadJob(fileURL: url)
            job.state = .failed("Unsupported file type (\(url.pathExtension.isEmpty ? "no extension" : url.pathExtension.lowercased()))")
            added.append(job)
        }
        guard !added.isEmpty else { return }
        uploadQueue.append(contentsOf: added)
        for job in added where job.state == .queued {
            Task { [weak self] in
                let image = await Task.detached(priority: .utility) { UploadInput.thumbnail(for: job.fileURL) }.value
                self?.setThumbnail(image, for: job.id)
            }
        }
        pumpUploadQueue()
    }

    private func setThumbnail(_ image: PlatformImage?, for id: UUID) {
        guard let i = uploadQueue.firstIndex(where: { $0.id == id }) else { return }
        uploadQueue[i].thumbnail = image
    }

    func setState(_ state: UploadJob.State, for id: UUID) {
        guard let i = uploadQueue.firstIndex(where: { $0.id == id }) else { return }
        uploadQueue[i].state = state
    }

    /// Starts queued jobs until the concurrency limit is reached.
    private func pumpUploadQueue() {
        let limit = sync.isEnabled || sync.capabilities.cachesPhotos ? 3 : Self.maxConcurrentUploads(for: settings)   // cloud: the server queues the extraction
        while uploadTasks.count < limit, let job = uploadQueue.first(where: { $0.state == .queued && uploadTasks[$0.id] == nil }) {
            let id = job.id
            setState(.scanning, for: id)
            uploadTasks[id] = Task { [weak self] in
                await self?.runUploadJob(id: id)
                self?.uploadJobEnded(id: id)
            }
        }
        isProcessingUpload = !uploadTasks.isEmpty
    }

    private func uploadJobEnded(id: UUID) {
        uploadTasks[id] = nil
        pumpUploadQueue()
        if uploadTasks.isEmpty {
            // Batch drained (or only cancelled/failed jobs remain): one full refresh, including trash.
            Task { await refreshList() }
        }
    }

    /// Stops queued jobs and asks running ones to cancel at their next stage boundary (an
    /// in-flight LLM call may still finish; nothing is written after cancellation is seen).
    func cancelAllUploads() {
        for i in uploadQueue.indices where uploadQueue[i].state == .queued { uploadQueue[i].state = .cancelled }
        for task in uploadTasks.values { task.cancel() }
    }

    func cancelUpload(id: UUID) {
        if uploadQueue.first(where: { $0.id == id })?.state == .queued { setState(.cancelled, for: id) }
        uploadTasks[id]?.cancel()
    }

    func retryFailedUploads() {
        for i in uploadQueue.indices {
            if case .failed = uploadQueue[i].state { uploadQueue[i].state = .queued }
        }
        pumpUploadQueue()
    }

    /// Removes done, duplicate and cancelled jobs; failed ones stay so they can be retried.
    func clearFinishedUploads() {
        uploadQueue.removeAll { job in
            switch job.state {
            case .done, .uploaded, .duplicate, .cancelled: return true
            default: return false
            }
        }
    }

    /// Waits until no other job is running the pipeline on a file with this hash. The pipeline's
    /// duplicate check (SELECT) and insert aren't atomic across jobs, so two identical files in
    /// one batch would both pass the check; serialising per hash makes the second one see the
    /// first's committed row and report "duplicate".
    func acquireHash(_ hash: String) async {
        while inFlightHashes.contains(hash) {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                hashWaiters[hash, default: []].append(c)
            }
        }
        inFlightHashes.insert(hash)
    }

    func releaseHash(_ hash: String) {
        inFlightHashes.remove(hash)
        let waiters = hashWaiters.removeValue(forKey: hash) ?? []
        waiters.forEach { $0.resume() }
    }

    /// Copies the file into a staging folder (mirrors INCOMING_FOLDER in api.py) and runs the
    /// full pipeline on it. The pipeline work (Vision scanning, JPEG encoding, LLM calls) runs
    /// in a detached task rather than inline: this store is @MainActor and that CPU-bound work
    /// would otherwise freeze the UI. Cancelling the job's Task is forwarded to that detached task.
    private func runUploadJob(id: UUID) async {
        // Cloud: straighten here, the server reads the receipt. The phone has no other way (its AI is the server).
        if sync.isEnabled || sync.capabilities.cachesPhotos { await runCloudUploadJob(id: id); return }
        guard let fileURL = uploadQueue.first(where: { $0.id == id })?.fileURL else { return }
        let ext = fileURL.pathExtension.isEmpty ? "jpg" : fileURL.pathExtension
        let stagingDir = env.appSupportDir.appendingPathComponent("uploads_incoming", isDirectory: true)
        try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let tempPath = stagingDir.appendingPathComponent("\(UUID().uuidString).\(ext)")

        let accessed = fileURL.startAccessingSecurityScopedResource()
        defer { if accessed { fileURL.stopAccessingSecurityScopedResource() } }

        do {
            try FileManager.default.copyItem(at: fileURL, to: tempPath)
        } catch {
            try? FileManager.default.removeItem(at: tempPath)
            setState(.failed("Couldn't read the file: \(error.localizedDescription)"), for: id)
            return
        }
        let imagePath = tempPath.path
        // From here the staging file is removed by processReceipt on every path except "imported
        // but archive move failed"; this guards the paths that never reach it.
        guard !Task.isCancelled else {
            try? FileManager.default.removeItem(at: tempPath)
            setState(.cancelled, for: id)
            return
        }

        let hash = await Task.detached(priority: .userInitiated) { try? ReceiptPipeline.sha256Hex(ofFileAt: imagePath) }.value
        if let hash { await acquireHash(hash) }
        defer { if let hash { releaseHash(hash) } }
        guard !Task.isCancelled else {
            try? FileManager.default.removeItem(at: tempPath)
            setState(.cancelled, for: id)
            return
        }

        let db = db, env = env, taxonomy = taxonomy, services = services
        let store = self  // @MainActor, hence Sendable; held only for the duration of this job
        let work = Task.detached(priority: .userInitiated) {
            await ReceiptPipeline.processReceipt(
                imagePath: imagePath, db: db, env: env, taxonomy: taxonomy, services: services,
                progress: { stage in
                    Task { @MainActor in
                        store.applyStage(stage, to: id)
                    }
                }
            )
        }
        let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }

        if result.cancelled {
            setState(.cancelled, for: id)
        } else if let dupId = result.duplicateOf {
            setState(.duplicate(receiptId: dupId), for: id)
        } else if result.success, let receiptId = result.receiptId {
            setState(.done(receiptId: receiptId), for: id)
            // Lightweight refresh so the receipt shows up now; the full refresh runs once at the end.
            invalidateStatsCache()
            if let rows = try? await fetchSummaries(deleted: false) { receipts = rows }
            if uploadQueue.count == 1 { await loadReceiptDetail(id: receiptId) }
        } else {
            setState(.failed("\(result.errorMessage ?? "Unknown error"). Try a clearer, flatter photo."), for: id)
        }
    }

    private func applyStage(_ stage: ProcessStage, to id: UUID) {
        // Late progress callbacks must not overwrite a terminal state.
        guard let i = uploadQueue.firstIndex(where: { $0.id == id }), !uploadQueue[i].state.isFinished else { return }
        switch stage {
        case .scanning: uploadQueue[i].state = .scanning
        case .extracting: uploadQueue[i].state = .extracting
        case .categorizing: uploadQueue[i].state = .categorizing
        case .saving: uploadQueue[i].state = .saving
        }
    }

    // MARK: - Mutations

    /// Marks the receipt reviewed, then moves on to the next unreviewed one (the one after it in
    /// the list if any, else the first); stays put when nothing is left to review.
    func confirmReceipt(id: Int) async {
        let before = receipts.firstIndex { $0.id == id } ?? 0
        do {
            try await db.run("UPDATE receipts SET reviewed_at = ? WHERE id = ?", [.text(isoNow()), .from(id)])
        } catch { report("Confirming receipt", error) }
        await refreshList()
        let pending = receipts.enumerated().filter { $0.element.reviewedAt == nil && $0.element.id != id }
        if let next = pending.first(where: { $0.offset > before }) ?? pending.first {
            await loadReceiptDetail(id: next.element.id)
        } else {
            await loadReceiptDetail(id: id)
        }
    }

    func confirmSelectedReceipt() async {
        guard let detail = selectedReceipt, detail.reviewedAt == nil else { return }
        await confirmReceipt(id: detail.id)
    }

    /// Unreviewed receipts without any review reason (what "Confirm all without flags" affects).
    var unflaggedUnreviewedCount: Int { receipts.filter { $0.reviewedAt == nil && !$0.needsReview }.count }

    func confirmAllWithoutFlags() async {
        do {
            try await db.run(
                """
                UPDATE receipts SET reviewed_at = ?
                WHERE reviewed_at IS NULL AND deleted_at IS NULL AND needs_review = 0
                  AND (review_reasons IS NULL OR review_reasons IN ('', '[]'))
                """,
                [.text(isoNow())]
            )
        } catch { report("Confirming receipts", error) }
        await refreshList()
        if let id = selectedReceiptID { await loadReceiptDetail(id: id) }
    }

    /// How many line items (and receipts) share this dictionary entry, i.e. what a category
    /// correction on it will change.
    func dictionaryUsage(itemDictionaryId: Int) async -> (items: Int, receipts: Int) {
        do {
            let row = try await db.queryOne("""
                SELECT COUNT(*), COUNT(DISTINCT li.receipt_id) FROM line_items li
                JOIN receipts r ON r.id = li.receipt_id
                WHERE li.item_dictionary_id = ? AND r.deleted_at IS NULL
                """, [.from(itemDictionaryId)])
            return (row?.int(0) ?? 0, row?.int(1) ?? 0)
        } catch {
            report("Counting affected items", error)
            return (0, 0)
        }
    }

    // MARK: - Re-run extraction / re-categorize

    /// Re-processes the archived image with the current provider and replaces header fields and
    /// line items in one transaction (id kept, reviewed_at cleared).
    func rerunExtraction(id: Int) async {
        guard !busyReceiptIDs.contains(id) else { return }
        // Cloud sync with the photo still on the server: the server re-reads it (its pipeline, no local AI call).
        if sync.isEnabled, let row = try? await db.queryOne("SELECT photo_location FROM receipts WHERE id = ?", [.from(id)]),
           row.string(0) == "server" {
            await retryServerExtraction(id: id)
            return
        }
        busyReceiptIDs.insert(id)
        defer { busyReceiptIDs.remove(id) }
        let db = db, env = env, taxonomy = taxonomy, services = services
        let result = await Task.detached(priority: .userInitiated) {
            await ReceiptPipeline.reprocessReceipt(receiptId: id, db: db, env: env, taxonomy: taxonomy, services: services)
        }.value
        if !result.success && !result.cancelled {
            lastError = "Re-running extraction failed: \(result.errorMessage ?? "unknown error")"
        }
        await refreshList()
        if selectedReceiptID == id { await loadReceiptDetail(id: id) }
    }

    /// Re-runs classification for this receipt's items whose dictionary entry isn't a manual override.
    func recategorizeItems(id: Int) async {
        guard !busyReceiptIDs.contains(id) else { return }
        busyReceiptIDs.insert(id)
        defer { busyReceiptIDs.remove(id) }
        do {
            let rows = try await db.query("SELECT DISTINCT item_dictionary_id FROM line_items WHERE receipt_id = ?", [.from(id)])
            let storeName = selectedReceipt?.id == id ? selectedReceipt?.store : nil
            let db = db, taxonomy = taxonomy, services = services, log = env.classificationLogURL
            let ids = rows.compactMap { $0.int(0) }
            _ = try await Task.detached(priority: .userInitiated) {
                try await ItemCategorizer.reclassifyEntries(
                    db: db, dictionaryIds: ids, taxonomy: taxonomy, storeName: storeName, logURL: log, provider: services.classification
                )
            }.value
        } catch { report("Re-categorizing items", error) }
        await refreshList()
        await loadReceiptDetail(id: id)
    }

    func correctItem(itemDictionaryId: Int, category: String, subcategory: String, itemGroup: String, translationEn: String?, forReceipt receiptId: Int) async {
        do {
            try await db.run(
                """
                UPDATE item_dictionary
                SET category = ?, subcategory = ?, item_group = ?,
                    translation_en = COALESCE(?, translation_en),
                    is_manual_override = 1, needs_review = 0
                WHERE id = ?
                """,
                [.text(category), .text(subcategory), .text(itemGroup), .from(translationEn), .from(itemDictionaryId)]
            )
        } catch { report("Saving category", error) }
        invalidateStatsCache()
        await loadReceiptDetail(id: receiptId)
    }

    func updateLineItem(lineItemId: Int, quantity: Double, unitPrice: Double, receiptId: Int) async {
        let totalPrice = round2(quantity * unitPrice)
        do {
            try await db.run(
                "UPDATE line_items SET quantity = ?, unit_price = ?, total_price = ? WHERE id = ?",
                [.from(quantity), .from(unitPrice), .from(totalPrice), .from(lineItemId)]
            )
            try await ReceiptPipeline.recomputeReceiptTotals(db: db, receiptId: receiptId)
        } catch { report("Updating item", error) }
        await refreshList()
        await loadReceiptDetail(id: receiptId)
    }

    func deleteLineItem(lineItemId: Int, receiptId: Int) async {
        do {
            try await db.run("DELETE FROM line_items WHERE id = ?", [.from(lineItemId)])
            try await ReceiptPipeline.recomputeReceiptTotals(db: db, receiptId: receiptId)
        } catch { report("Deleting item", error) }
        await refreshList()
        await loadReceiptDetail(id: receiptId)
    }

    func addItem(receiptId: Int, name: String, quantity: Double, unitPrice: Double, rawText: String?) async {
        do {
            guard let row = try await db.queryOne("SELECT store FROM receipts WHERE id = ?", [.from(receiptId)]) else { return }
            let store = row.string(0)
            let totalPrice = round2(quantity * unitPrice)
            let entry = try await ItemCategorizer.getOrCreateItem(
                db: db, rawName: name, taxonomy: taxonomy, storeName: store, logURL: env.classificationLogURL,
                provider: services.classification
            )
            try await db.run(
                """
                INSERT INTO line_items
                (receipt_id, item_dictionary_id, raw_text, name_de, quantity, unit_price, total_price, price_normalized)
                VALUES (?, ?, ?, ?, ?, ?, ?, 0)
                """,
                [.from(receiptId), .from(entry.id), .text(rawText ?? name), .text(name), .from(quantity), .from(unitPrice), .from(totalPrice)]
            )
            try await ReceiptPipeline.recomputeReceiptTotals(db: db, receiptId: receiptId)
        } catch { report("Adding item", error) }
        await refreshList()
        await loadReceiptDetail(id: receiptId)
    }

    /// Soft delete: hides the receipt everywhere (lists, stats, duplicate checks) but keeps the
    /// rows and the archived image, so it can be restored from "Recently deleted".
    func deleteReceipt(id: Int) async {
        do {
            try await db.run("UPDATE receipts SET deleted_at = ? WHERE id = ?", [.text(isoNow()), .from(id)])
        } catch { report("Deleting receipt", error) }
        if selectedReceiptID == id { selectedReceipt = nil; selectedReceiptID = nil }
        await refreshList()
    }

    func restoreReceipt(id: Int) async {
        do {
            try await db.run("UPDATE receipts SET deleted_at = NULL WHERE id = ?", [.from(id)])
        } catch { report("Restoring receipt", error) }
        await refreshList()
    }

    /// Irreversible: removes the rows and the archived image file.
    func permanentlyDeleteReceipt(id: Int) async {
        do {
            let sourceImage = try await db.queryOne("SELECT source_image FROM receipts WHERE id = ?", [.from(id)])?.string(0)
            try await db.transaction { conn in
                try conn.run("DELETE FROM line_items WHERE receipt_id = ?", [.from(id)])
                try conn.run("DELETE FROM receipts WHERE id = ?", [.from(id)])
            }
            if let path = env.resolveImagePath(sourceImage) {
                try? FileManager.default.removeItem(atPath: path)
            }
        } catch { report("Permanently deleting receipt", error) }
        if selectedReceiptID == id { selectedReceipt = nil; selectedReceiptID = nil }
        await refreshList()
    }

    /// `date`/`time` are stored as "yyyy-MM-dd" / "HH:mm"; a nil time clears it.
    func updateReceiptDateTime(id: Int, date: String, time: String?) async {
        do {
            try await db.run("UPDATE receipts SET date = ?, time = ? WHERE id = ?", [.text(date), .from(time), .from(id)])
        } catch { report("Saving date/time", error) }
        await refreshList()
        await loadReceiptDetail(id: id)
    }

    func updateReceiptStore(id: Int, store name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await db.run("UPDATE receipts SET store = ? WHERE id = ?", [.text(ReceiptPipeline.canonicalizeStore(trimmed)), .from(id)])
        } catch { report("Saving store", error) }
        await refreshList()
        await loadReceiptDetail(id: id)
    }

    /// Saves the printed total, then re-derives the sum-mismatch review reason (other reasons stay).
    func updateReceiptTotal(id: Int, total: Double?) async {
        do {
            try await db.run("UPDATE receipts SET total = ? WHERE id = ?", [.from(total.map(round2)), .from(id)])
            try await ReceiptPipeline.recomputeReceiptTotals(db: db, receiptId: id)
        } catch { report("Saving total", error) }
        await refreshList()
        await loadReceiptDetail(id: id)
    }

    // MARK: - Stats (GET /stats/summary, GET /stats/item-group)

    func statsItemGroup(category: String, subcategory: String, itemGroup: String, start: String?, end: String?) async -> ItemGroupDetail {
        var query = """
            SELECT r.date, r.store, d.translation_en, li.name_de, li.quantity, li.unit_price,
                   li.total_price, li.receipt_id, d.id
            FROM line_items li
            JOIN item_dictionary d ON li.item_dictionary_id = d.id
            JOIN receipts r ON li.receipt_id = r.id
            WHERE r.deleted_at IS NULL AND d.category = ? AND d.subcategory = ? AND d.item_group = ?
            """
        var params: [SQLiteValue] = [.text(category), .text(subcategory), .text(itemGroup)]
        if let start { query += " AND r.date >= ?"; params.append(.text(start)) }
        if let end { query += " AND r.date <= ?"; params.append(.text(end)) }
        query += " ORDER BY r.date DESC"

        let rows: [SQLRow]
        do { rows = try await db.query(query, params) } catch {
            report("Loading item group", error)
            return ItemGroupDetail(category: category, subcategory: subcategory, itemGroup: itemGroup, total: 0, purchases: [])
        }
        let purchases = rows.map { row in
            PurchaseRow(
                date: row.string(0), store: row.string(1), translationEn: row.string(2), nameDe: row.string(3),
                quantity: row.double(4) ?? 0, unitPrice: row.double(5) ?? 0, totalPrice: row.double(6) ?? 0,
                receiptId: row.int(7) ?? 0, itemDictionaryId: row.int(8) ?? 0
            )
        }
        let total = round2(purchases.reduce(0) { $0 + $1.totalPrice })
        return ItemGroupDetail(category: category, subcategory: subcategory, itemGroup: itemGroup, total: total, purchases: purchases)
    }
}
