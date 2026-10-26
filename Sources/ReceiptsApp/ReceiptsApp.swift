import SwiftUI
import AppKit
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
                    await store.runAutoBackupIfDue()
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
                Divider()
            }

            CommandMenu("Receipt") {
                Button("Confirm") { Task { await store.confirmSelectedReceipt() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(store.page != .review || store.selectedReceipt == nil || store.selectedReceipt?.reviewedAt != nil)
                Button("Delete…") {
                    // While editing text, ⌘⌫ keeps its text meaning (delete to line start) instead of deleting the receipt.
                    if NSApp.keyWindow?.firstResponder is NSText {
                        NSApp.sendAction(#selector(NSResponder.deleteToBeginningOfLine(_:)), to: nil, from: nil)
                    } else {
                        store.deleteConfirmationPresented = true
                    }
                }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(store.page != .review || store.selectedReceipt == nil)
                Divider()
                Button("Previous Receipt") { Task { await store.selectAdjacentReceipt(offset: -1) } }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("Next Receipt") { Task { await store.selectAdjacentReceipt(offset: 1) } }
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
