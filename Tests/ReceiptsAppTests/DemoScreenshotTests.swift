#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import ReceiptsApp

/// Draws the Mac main window (Review page) with the made-up demo receipts (DemoData) into PNG files, for the README
/// screenshots. Offscreen, on a temp database. Skipped unless `DEMO_SCREENSHOT_DIR` is set.
@MainActor
final class DemoScreenshotTests: XCTestCase {
    func testRenderDemoScreenshots() async throws {
        guard let dir = ProcessInfo.processInfo.environment["DEMO_SCREENSHOT_DIR"] else { throw XCTSkip("set DEMO_SCREENSHOT_DIR") }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let base = try makeTempDir("demo-screens")
        defer { try? FileManager.default.removeItem(at: base) }
        let appEnv = AppEnvironment.make(baseDir: base)
        let db = try Database(path: appEnv.dbPath, dataDir: base)
        try await DemoData.seed(db: db)
        let store = ReceiptStore(env: appEnv, db: db, taxonomy: Taxonomy.load(), reminders: NoReminders())
        await store.refreshList()
        if let first = store.receipts.first { await store.loadReceiptDetail(id: first.id); store.selectedReceiptID = first.id }
        let snacks = SnackCenter()

                let host = NSHostingView(rootView: ContentView().environmentObject(store).environmentObject(snacks))
        host.frame = CGRect(x: 0, y: 0, width: 1100, height: 720)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .aqua)

        func capture(_ name: String) throws {
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(2.5))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent(name))
        }
                store.page = .review
        try capture("mac-review.png")
    }
}
#endif
