import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct ReceiptsApp: App {
    @StateObject private var store: ReceiptStore
    @StateObject private var snacks = SnackCenter()

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
                .environmentObject(snacks)
                .frame(minWidth: 900, minHeight: 600)
                .fileImporter(
                    isPresented: $store.isImporterPresented,
                    allowedContentTypes: [.jpeg, .png, .heic, .heif, .image, .folder],
                    allowsMultipleSelection: true
                ) { result in
                    if case .success(let urls) = result, !urls.isEmpty { store.upload(fileURLs: urls) }
                }
                .task {
                    #if DEBUG
                    await DemoData.seedIfRequested(db: store.db)
                    #endif
                    await store.checkProviderReadiness()
                    await store.refreshList()
                    await store.runAutoBackupIfDue()
                    store.startSync()   // no-op unless cloud sync is switched on in Settings
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import Receipts…") { store.isImporterPresented = true }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Export…") { store.exportSheetPresented = true }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Back Up Data…") { Task { await store.backUpNow() } }
                Button("Sync Now") { store.syncNow() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }

            CommandGroup(after: .textEditing) {
                Button("Find Receipts") {
                    store.page = .review
                    store.searchFocusToken = UUID()
                }
                .keyboardShortcut("f", modifiers: .command)
            }

            CommandGroup(before: .toolbar) {
                Button("Review") { store.page = .review }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Overview") { store.page = .overview }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Items Without a Category") {
                    store.page = .review
                    store.flaggedPaneOpen = true
                }
                .keyboardShortcut("3", modifiers: .command)
                Divider()
            }

            CommandMenu("Receipt") {
                Button("Confirm") {
                    // One still being read must stay unconfirmed: the server would treat that as the user's version.
                    guard let detail = store.selectedReceipt, detail.reviewedAt == nil, detail.processing?.isActive != true else { return }
                    Task { await store.confirmWithUndo(id: detail.id, name: detail.store, snacks: snacks) }
                }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(store.page != .review || store.flaggedPaneOpen || store.selectedReceipt == nil || store.selectedReceipt?.reviewedAt != nil || store.selectedReceipt?.processing?.isActive == true)
                Button("Delete…") {
                    // While editing text, ⌘⌫ keeps its text meaning (delete to line start) instead of deleting the receipt.
                    if NSApp.keyWindow?.firstResponder is NSText {
                        NSApp.sendAction(#selector(NSResponder.deleteToBeginningOfLine(_:)), to: nil, from: nil)
                    } else {
                        store.deleteConfirmationPresented = true
                    }
                }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(store.page != .review || store.flaggedPaneOpen || store.selectedReceipt == nil)
                Divider()
                Button("Previous Receipt") { store.flaggedPaneOpen = false; Task { await store.selectAdjacentReceipt(offset: -1) } }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("Next Receipt") { store.flaggedPaneOpen = false; Task { await store.selectAdjacentReceipt(offset: 1) } }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            }
        }

        // macOS Settings window (⌘,).
        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}
