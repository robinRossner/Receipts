#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import ReceiptsApp

/// Draws the Mac views to PNG files in-process (an offscreen window, no screen-recording permission needed), for the
/// visual check of screens that otherwise need a human at the Mac: Settings > Cloud sync and the sync banners/status bar
/// of the main window. Skipped unless `MAC_RENDER_DIR` is set. With `MAC_RENDER_SERVER` (the e2e backend URL) and
/// `RECEIPTS_APP_TOKEN` (+ `RECEIPTS_APP_DATA_DIR`, see KeychainStore) the main window renders after a real sync against it.
@MainActor
final class MacRenderTests: XCTestCase {
    private func render<V: View>(_ view: V, size: CGSize, to url: URL) throws {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .aqua)
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))   // let async loads (lists, status) land
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }

    func testRenderCloudSyncSettingsAndMainWindow() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["MAC_RENDER_DIR"] else { throw XCTSkip("set MAC_RENDER_DIR to render the Mac views to PNG files") }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let base = try makeTempDir("mac-render")
        defer { try? FileManager.default.removeItem(at: base) }
        let appEnv = AppEnvironment.make(baseDir: base)
        let db = try Database(path: appEnv.dbPath, dataDir: base)
        let store = ReceiptStore(env: appEnv, db: db, taxonomy: Taxonomy.load(), reminders: NoReminders())

        let d = UserDefaults.standard
        if let server = env["MAC_RENDER_SERVER"] {
            d.set(true, forKey: SyncSettings.Keys.enabled)
            d.set(server, forKey: SyncSettings.Keys.serverURL)
        }
        defer { for k in [SyncSettings.Keys.enabled, SyncSettings.Keys.serverURL, SyncSettings.Keys.enabledSince] { d.removeObject(forKey: k) } }

        try render(CloudSyncSettingsView(sync: store.sync).environmentObject(store), size: CGSize(width: 520, height: 420), to: out.appendingPathComponent("mac-settings-cloud-sync-off.png"))

        if env["MAC_RENDER_SERVER"] != nil {
            store.startSync()
            let end = Date().addingTimeInterval(30)
            while store.sync.serverStatus == nil, Date() < end { try await Task.sleep(nanoseconds: 100_000_000) }
            await store.refreshList()
            try render(CloudSyncSettingsView(sync: store.sync).environmentObject(store), size: CGSize(width: 520, height: 640), to: out.appendingPathComponent("mac-settings-cloud-sync-on.png"))
            try render(ContentView().environmentObject(store), size: CGSize(width: 1000, height: 640), to: out.appendingPathComponent("mac-main-window.png"))
            print("MAC-RENDER banners=\(store.sync.banners.count) status=\(store.sync.statusText) receipts=\(store.receipts.count)")
            store.sync.stop()
        }
    }
}
#endif
