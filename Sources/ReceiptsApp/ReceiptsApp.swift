import SwiftUI
import UniformTypeIdentifiers

@main
struct ReceiptsApp: App {
    @StateObject private var store: ReceiptStore

    init() {
        let env = AppEnvironment.bootstrap()
        let taxonomy = Taxonomy.load()
        // swiftlint:disable:next force_try - a broken/unwritable SQLite file here means the app can't function at all.
        let db = try! Database(path: env.dbPath, dataDir: env.appSupportDir)
        _store = StateObject(wrappedValue: ReceiptStore(env: env, db: db, taxonomy: taxonomy))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 600)
                .fileImporter(
                    isPresented: $store.isImporterPresented,
                    allowedContentTypes: [.jpeg, .png, .heic, .heif, .image, .folder],
                    allowsMultipleSelection: true
                ) { result in
                    if case .success(let urls) = result, !urls.isEmpty { store.upload(fileURLs: urls) }
                }
                .task {
                    await store.checkProviderReadiness()
                    await store.refreshList()
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import Receipts…") { store.isImporterPresented = true }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }

        // macOS Settings window (⌘,).
        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}
