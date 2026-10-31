import Combine
import Foundation

/// Runs the sync engine on a schedule and publishes what the UI shows: on launch, shortly after local edits
/// (debounced), every `interval`, quickly while the server is still extracting something, and on "Sync now".
/// Failures are retried with a growing delay; they are shown as a small status, never as a blocking alert.
@MainActor
final class SyncCoordinator: ObservableObject {
    enum Phase: Equatable { case off, idle, syncing }

    struct ConnectionTest: Equatable {
        var ok: Bool
        var message: String
    }

    @Published private(set) var phase: Phase = .off
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var serverStatus: ServerStatus?
    @Published private(set) var unsentChanges = 0
    @Published private(set) var nextRetryAt: Date?
    /// Set when this Mac has not synced for 30 days while sync is on.
    @Published private(set) var staleSyncWarning: String?
    @Published private(set) var lastReport: SyncReport?
    /// Records the server refused (shown in Settings; editing such a record sends it again).
    @Published private(set) var rejectedRecords = 0

    let store: SyncStore
    private let defaults: UserDefaults
    private let makeAPI: (URL, String) -> ReceiptsAPI
    private let tokenProvider: () -> String?
    private let reminders: ReminderScheduling
    private let fileSystem: ArchiveFileSystem
    /// Called after a run changed local data, so lists reload.
    var onDataChanged: (() async -> Void)?

    private var settings: SyncSettings
    private var engine: SyncEngine?
    private var debounceTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var failures = 0
    private var pollingUntil: Date?

    static let interval: TimeInterval = 15 * 60
    static let debounce: TimeInterval = 4
    static let pollInterval: TimeInterval = 6
    static let pollWindow: TimeInterval = 180
    static let maxBackoff: TimeInterval = 15 * 60

    init(store: SyncStore, defaults: UserDefaults = .standard, fileSystem: ArchiveFileSystem = DiskFileSystem(),
         reminders: ReminderScheduling = NoReminders(),
         tokenProvider: @escaping () -> String? = { KeychainStore.read(.receiptsAPIToken) },
         makeAPI: @escaping (URL, String) -> ReceiptsAPI = { URLSessionReceiptsAPI(baseURL: $0, token: $1) }) {
        self.store = store
        self.defaults = defaults
        self.fileSystem = fileSystem
        self.reminders = reminders
        self.makeAPI = makeAPI
        self.tokenProvider = tokenProvider
        self.settings = SyncSettings.load(from: defaults, token: tokenProvider())
    }

    var isEnabled: Bool { settings.enabled }

    /// Compact line for the toolbar: what the user should know at a glance.
    var statusText: String {
        switch phase {
        case .off: return ""
        case .syncing: return "Syncing…"
        case .idle:
            if lastError != nil { return nextRetryAt != nil ? "Sync failed, retrying" : "Sync failed" }
            if let lastSyncAt { return "Synced " + lastSyncAt.formatted(.relative(presentation: .named)) }
            return "Not synced yet"
        }
    }

    /// Banner texts: the server's archive/disk flags and the 30 day reminder.
    var banners: [String] {
        var out: [String] = []
        if let s = serverStatus {
            if s.archiveOverdue {
                let mb = max(1, s.unarchivedBytes / 1_000_000)
                out.append("\(s.unarchivedCount) receipt photo(s) (\(mb) MB) wait on the server and have not been archived for over \(s.archiveReminderDays ?? 30) days. Sync archives them on this Mac.")
            }
            if s.diskWarning {
                let free = s.diskFreeBytes.map { String(format: "%.1f GB", Double($0) / 1e9) } ?? "little"
                out.append("The server is low on disk space (\(free) free). Archive its photos with Sync now.")
            }
        }
        if let staleSyncWarning { out.append(staleSyncWarning) }
        return out
    }

    // MARK: - Lifecycle

    /// Reads the settings and (re)starts or stops everything. Call at launch and after the settings changed.
    func configure() {
        let new = SyncSettings.load(from: defaults, token: tokenProvider())
        let changed = new != settings || engine == nil
        settings = new
        guard new.enabled else {
            stop()
            return
        }
        if defaults.double(forKey: SyncSettings.Keys.enabledSince) == 0 {
            defaults.set(Date().timeIntervalSince1970, forKey: SyncSettings.Keys.enabledSince)
        }
        guard let base = new.apiBase, let token = new.token, !token.isEmpty else {
            engine = nil
            phase = .idle
            lastError = "Cloud sync is on, but the server URL or token is missing (Settings > Cloud sync)."
            return
        }
        if changed || engine == nil {
            let config = SyncConfig(cursorKey: ServerURL.cursorKey(apiBase: base))
            engine = SyncEngine(api: makeAPI(base, token), store: store, config: config, fileSystem: fileSystem)
            failures = 0
        }
        if phase == .off { phase = .idle }
        lastError = nil
        Task { await loadLastSync(); refreshStaleness(); scheduleReminder(); scheduleTimer(); await syncNow() }
    }

    func stop() {
        debounceTask?.cancel(); timerTask?.cancel()
        engine = nil
        phase = .off
        lastError = nil
        nextRetryAt = nil
        serverStatus = nil
        staleSyncWarning = nil
        reminders.cancel()
    }

    // MARK: - Triggers

    /// A local edit happened: sync soon (several edits in a row become one sync).
    func noteLocalChange() {
        guard settings.enabled, engine != nil else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.debounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    /// Cheap check used after a list reload: sync if there are unsent edits.
    func syncIfLocalChangesPending() async {
        guard settings.enabled, engine != nil else { return }
        let pending = (try? await store.unsentChangeCount()) ?? 0
        unsentChanges = pending
        if pending > 0 { noteLocalChange() }
    }

    func syncNow() async {
        guard settings.enabled, let engine, phase != .syncing else { return }
        phase = .syncing
        let report = await engine.syncNow()
        phase = .idle
        lastReport = report
        if let status = report.status { serverStatus = status }
        unsentChanges = (try? await store.unsentChangeCount()) ?? 0
        rejectedRecords = (try? await store.rejectedCount()) ?? 0
        if report.succeeded || !report.connectionProblem {
            await loadLastSync()
            refreshStaleness()
            scheduleReminder()
        }
        if report.succeeded {
            failures = 0; lastError = nil; nextRetryAt = nil
        } else {
            lastError = report.errors.first
            failures += 1
        }
        if report.changedLocalData { await onDataChanged?() }
        scheduleTimer(after: report)
    }

    /// Next automatic run: soon while the server still works on receipts, with backoff after a failure, else the interval.
    private func scheduleTimer(after report: SyncReport? = nil) {
        timerTask?.cancel()
        guard settings.enabled, engine != nil else { return }
        var delay = Self.interval
        nextRetryAt = nil
        if let report, !report.succeeded, report.connectionProblem || report.errors.contains(where: { !$0.hasPrefix("Push: ") }) {
            delay = min(30 * pow(2, Double(max(failures - 1, 0))), Self.maxBackoff)
            nextRetryAt = Date().addingTimeInterval(delay)
        } else if let status = report?.status ?? serverStatus, let q = status.queue, q.queued + q.processing > 0 {
            if pollingUntil == nil { pollingUntil = Date().addingTimeInterval(Self.pollWindow) }
            if let until = pollingUntil, Date() < until { delay = Self.pollInterval }
        } else {
            pollingUntil = nil
        }
        timerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
            self?.refreshStaleness()
        }
    }

    /// After starting an upload the server needs a few seconds: poll quickly for a while.
    func expectServerWork() {
        pollingUntil = Date().addingTimeInterval(Self.pollWindow)
        noteLocalChange()
    }

    // MARK: - Actions the UI offers

    func retryExtraction(uuid: String) async throws {
        guard let engine else { throw ReceiptsAPIError.notConfigured("Cloud sync is off.") }
        try await engine.retryExtraction(uuid: uuid)
        expectServerWork()
    }

    /// The user gave up on a failed receipt: its photo may be archived (and then leaves the server).
    func acceptFailedAndArchive(localID: Int) async {
        try? await store.setAcceptFailed(localID: localID, true)
        await syncNow()
    }

    /// Photo of a freshly prepared upload goes to the server now (not waiting for the interval).
    func upload(uuid: String) async -> SyncReport? {
        guard let engine else { return nil }
        let report = await engine.uploadOne(uuid: uuid)
        if report.uploaded > 0 { expectServerWork() }
        return report
    }

    /// Settings > "Test connection": `/health` (is it a server at all) then `/status` (does it accept the token).
    func testConnection(serverURL: String, token: String?) async -> ConnectionTest {
        guard let base = ServerURL.apiBase(from: serverURL) else { return .init(ok: false, message: "That is not a valid server URL.") }
        guard let token, !token.isEmpty else { return .init(ok: false, message: "Save the receipts token first.") }
        let api = makeAPI(base, token)
        do {
            try await api.health()
            let status = try await api.status()
            let llm = status.llm?.provider ?? "none"
            return .init(ok: true, message: "Connected. \(status.unarchivedCount) photo(s) on the server, extraction provider: \(llm).")
        } catch {
            return .init(ok: false, message: error.localizedDescription)
        }
    }

    // MARK: - Last sync, reminder

    private func loadLastSync() async {
        if let text = try? await store.meta("last_sync_at"), let date = SyncDate.parse(text) { lastSyncAt = date }
    }

    private func refreshStaleness() {
        guard settings.enabled else { staleSyncWarning = nil; return }
        if SyncReminder.isOverdue(lastSync: lastSyncAt, enabledSince: SyncSettings.enabledSince(in: defaults)) {
            staleSyncWarning = "This Mac has not synced for \(SyncReminder.days) days. Receipt photos pile up on the server until it does."
        } else {
            staleSyncWarning = nil
        }
    }

    private func scheduleReminder() {
        guard settings.enabled, let due = SyncReminder.dueDate(lastSync: lastSyncAt, enabledSince: SyncSettings.enabledSince(in: defaults)) else {
            reminders.cancel()
            return
        }
        reminders.schedule(at: due, title: "Receipts: sync this Mac",
                           body: "It has been \(SyncReminder.days) days since this Mac synced. Open Receipts to archive the receipt photos waiting on the server.")
    }
}
