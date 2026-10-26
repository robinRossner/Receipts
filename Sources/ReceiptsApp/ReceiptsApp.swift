import SwiftUI

@main
struct ReceiptsApp: App {
    @StateObject private var store: ReceiptStore

    init() {
        let env = AppEnvironment.bootstrap()
        let taxonomy = Taxonomy.load()
        // swiftlint:disable:next force_try - a broken/unwritable SQLite file here means the app can't function at all.
        let db = try! Database(path: env.dbPath)
        _store = StateObject(wrappedValue: ReceiptStore(env: env, db: db, taxonomy: taxonomy))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    await store.bootstrapOllama()
                    await store.refreshList()
                }
        }
        .windowResizability(.contentSize)
    }
}
