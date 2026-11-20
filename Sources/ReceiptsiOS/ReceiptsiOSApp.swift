import SwiftUI

/// The iPhone app: the cloud front end of the receipts backend. Receipts are photographed here, read by the server and
/// come back through sync; there is no AI on the device and this phone is not the photo archive (the laptop is, see
/// `SyncCapabilities.mobile`). Everything below `Sources/ReceiptsApp` is shared with the Mac app.
@main
struct ReceiptsiOSApp: App {
    @StateObject private var store: ReceiptStore
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        DebugLaunch.applyArguments()
        #endif
        let env = AppEnvironment.bootstrap()   // RECEIPTS_APP_DATA_DIR moves it (tests, e2e runs)
        // swiftlint:disable:next force_try - a broken/unwritable SQLite file here means the app can't function at all.
        let db = try! Database(path: env.dbPath, dataDir: env.appSupportDir)
        let store = ReceiptStore(
            env: env, db: db, taxonomy: Taxonomy.load(),
            capabilities: .mobile, deviceId: DeviceID.current()
        )
        _store = StateObject(wrappedValue: store)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .task {
                    #if DEBUG
                    await DemoData.seedIfRequested(db: store.db)
                    #endif
                    await store.refreshList()
                    store.startSync()   // sync on launch (no-op until the server is set up in Settings)
                }
                .onChange(of: scenePhase) {
                    // Sync when the app comes back to the foreground.
                    if scenePhase == .active { Task { await store.sync.syncIfStale() } }
                }
        }
    }
}

/// A stable name for this phone in sync requests (`device_id`), made up once and kept.
enum DeviceID {
    static let key = "sync.deviceID"

    static func current(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: key), !existing.isEmpty { return existing }
        let made = "iphone-" + LegacyIDs.newUUID().prefix(8)
        defaults.set(made, forKey: key)
        return made
    }
}

#if DEBUG
/// Launch arguments for UI tests and manual runs against a test backend.
enum DebugLaunch {
    /// `-resetReceiptsSettings`: forget the server URL and token and the local data (a fresh install).
    static func applyArguments() {
        guard ProcessInfo.processInfo.arguments.contains("-resetReceiptsSettings") else { return }
        let d = UserDefaults.standard
        for key in [SyncSettings.Keys.enabled, SyncSettings.Keys.serverURL, SyncSettings.Keys.enabledSince] { d.removeObject(forKey: key) }
        KeychainStore.delete(.receiptsAPIToken)
        let base = AppEnvironment.bootstrap().appSupportDir
        for child in (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: child)
        }
    }
}
#endif
