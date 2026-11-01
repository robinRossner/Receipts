#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import ReceiptsApp

/// Renders the real Mac screens from a temp database into PNGs, in light and dark, in a window off screen (so it needs no
/// screen recording permission and never disturbs the desktop). Only with `RECEIPTS_MAC_SHOTS=<folder>`:
///
///     RECEIPTS_MAC_SHOTS=/tmp/shots swift test --filter MacScreensTests
@MainActor
final class MacScreensTests: XCTestCase {
    private var dir: URL!
    private var store: ReceiptStore!
    private var snacks: SnackCenter!
    private var shots = ""

    override func setUpWithError() throws {
        let out = ProcessInfo.processInfo.environment["RECEIPTS_MAC_SHOTS"] ?? ""
        try XCTSkipIf(out.isEmpty, "set RECEIPTS_MAC_SHOTS to a folder")
        shots = out
        try FileManager.default.createDirectory(atPath: shots, withIntermediateDirectories: true)
        _ = NSApplication.shared
        dir = try makeTempDir()
        let env = AppEnvironment.make(baseDir: dir)
        let db = try Database(path: env.dbPath, dataDir: dir)
        // Own settings (no real sync or AI settings), no reminders. Sync stays off: nothing leaves this process.
        store = ReceiptStore(env: env, db: db, taxonomy: Taxonomy.load(), settings: .defaults, reminders: NoReminders())
        snacks = SnackCenter()
    }

    override func tearDownWithError() throws { if let dir { try? FileManager.default.removeItem(at: dir) } }

    /// Distinct days inside the current month, whatever today is (the list order and the Overview depend on them).
    private func day(_ back: Int) -> String {
        let cal = Calendar.current
        let first = cal.dateInterval(of: .month, for: Date())!.start
        return ReceiptDateFormat.dateString(from: cal.date(byAdding: .day, value: 10 - back, to: first)!)
    }

    private func seed() async throws {
        let db = store.db
        let last = ReceiptDateFormat.dateString(from: Calendar.current.date(byAdding: .month, value: -1, to: Date())!)
        func entry(_ key: String, _ de: String, _ en: String, _ path: (String, String, String), flag: (String?, String?)? = nil) async throws -> Int {
            Int(try await db.run("""
                INSERT INTO item_dictionary (canonical_name, display_name_de, translation_en, category, subcategory, item_group, created_at, last_seen_at, needs_review, category_flagged, suggested_category, suggested_parent)
                VALUES (?, ?, ?, ?, ?, ?, '2026-10-01', '2026-10-01', ?, ?, ?, ?)
                """, [.text(key), .text(de), .text(en), .text(path.0), .text(path.1), .text(path.2), .from(flag == nil ? 0 : 1), .from(flag == nil ? 0 : 1), .from(flag?.0), .from(flag?.1)]))
        }
        let fallback = ("Other", "Miscellaneous", "General")
        let dog = try await entry("hundefutter", "Pedigree Hundefutter", "Dog food", fallback, flag: ("Dog Supplies", "Household > Pets"))
        let chew = try await entry("kauknochen", "Trixie Kauknochen", "Dog chews", fallback, flag: ("Dog Supplies", "Household > Pets"))
        let rod = try await entry("angelrute", "Angelrute", "Fishing rod", fallback, flag: ("Fishing Gear", "Sports"))
        let odd = try await entry("ding", "Seltsames Ding", "Odd thing", fallback, flag: (nil, nil))
        let milk = try await entry("milch", "Vollmilch 1L", "Whole milk 1L", ("Food", "Dairy & Eggs", "Milk"))
        let bread = try await entry("brot", "Roggenbrot", "Rye bread", ("Food", "Bakery", "Bread"))
        let yarn = try await entry("wolle", "Sockenwolle", "Sock yarn", ("Arts | Crafts", "Knitting", "Yarn"))
        _ = try await db.run("INSERT INTO taxonomy_additions (category, subcategory, item_group, created_at, sync_state) VALUES ('Arts | Crafts', 'Knitting', 'Yarn', '2026-10-01T00:00:00Z', 'synced')")
        func receipt(_ name: String, _ date: String, total: Double?, reasons: [String] = [], reviewed: Bool = false, status: String? = nil, items: [(Int, String, Double)]) async throws {
            let json = "[" + reasons.map { "\"\($0)\"" }.joined(separator: ",") + "]"
            let sum = items.reduce(0) { $0 + $1.2 }
            let id = Int(try await db.run(
                "INSERT INTO receipts (store, date, time, total, computed_sum, needs_review, review_reasons, created_at, reviewed_at, extraction_status) VALUES (?, ?, '18:42', ?, ?, ?, ?, ?, ?, ?)",
                [.text(name), .text(date), .from(total), .from(sum), .from(reasons.isEmpty ? 0 : 1), .text(json), .text(date), .from(reviewed ? "\(date)T19:00:00Z" : nil), .from(status)]))
            for (d, de, p) in items {
                _ = try await db.run("INSERT INTO line_items (receipt_id, item_dictionary_id, raw_text, name_de, quantity, unit_price, total_price) VALUES (?, ?, ?, ?, 1, ?, ?)",
                                     [.from(id), .from(d), .text(de), .text(de), .from(p), .from(p)])
            }
        }
        try await receipt("Fressnapf", day(1), total: 20.00, reasons: ["Item prices sum to 17.49, but printed total is 20.00 (difference: 2.51). Check raw_text per item."], items: [(dog, "Pedigree Hundefutter", 12.99), (chew, "Trixie Kauknochen", 4.50)])
        try await receipt("Decathlon", day(2), total: 42.00, items: [(rod, "Angelrute", 39.00), (odd, "Seltsames Ding", 3.00)])
        try await receipt("Idee", day(3), total: 8.90, items: [(yarn, "Sockenwolle", 8.90)])
        try await receipt("Edeka", day(4), total: 4.48, reviewed: true, items: [(milk, "Vollmilch 1L", 1.19), (bread, "Roggenbrot", 3.29)])
        try await receipt("Kaufland", day(0), total: nil, status: "queued", items: [])
        try await receipt("Lidl", last, total: 6.20, reviewed: true, items: [(bread, "Roggenbrot", 6.20)])
        await store.refreshList()
    }

    private func settle(_ seconds: Double = 0.8) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    private func write(_ view: NSView, _ name: String) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return XCTFail("no bitmap for \(name)") }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return XCTFail("no png for \(name)") }
        try? png.write(to: URL(fileURLWithPath: "\(shots)/\(name).png"))
    }

    /// A window far off screen, so the desktop is not disturbed.
    private func host<V: View>(_ root: V, _ appearance: NSAppearance.Name, size: CGSize = CGSize(width: 1240, height: 820)) -> (NSWindow, NSView) {
        let view = NSHostingView(rootView: root.environmentObject(store).environmentObject(snacks))
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -6000, y: -6000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = view
        window.setFrameOrigin(CGPoint(x: -6000, y: -6000))
        window.orderFrontRegardless()
        return (window, view)
    }

    private func tour(_ appearance: NSAppearance.Name, _ suffix: String) async throws {
        store.page = .review
        store.flaggedPaneOpen = false
        store.clearReceiptFilters()
        store.selectedReceipt = nil
        store.selectedReceiptID = nil
        let (window, view) = host(ContentView(), appearance)
        defer { window.close() }
        await settle()

        write(view, "m01-review-nothing-selected\(suffix)")
        let fressnapf = try XCTUnwrap(store.receipts.first { $0.store == "Fressnapf" })
        await store.loadReceiptDetail(id: fressnapf.id)
        await settle()
        write(view, "m02-review-flagged-receipt\(suffix)")

        let edeka = try XCTUnwrap(store.receipts.first { $0.store == "Edeka" })
        await store.loadReceiptDetail(id: edeka.id)
        await settle()
        write(view, "m03-review-reviewed-collapsed\(suffix)")

        store.flaggedPaneOpen = true
        await settle()
        write(view, "m04-flagged-pane\(suffix)")
        store.flaggedPaneOpen = false

        store.storeFilter = "Lidl"
        store.dateRange = .thisMonth
        await settle()
        write(view, "m05-no-match-tags\(suffix)")
        store.clearReceiptFilters()

        store.page = .overview
        await settle(1.2)
        write(view, "m06-overview\(suffix)")
        store.page = .review
        await settle(0.3)

        let decathlon = try XCTUnwrap(store.receipts.first { $0.store == "Decathlon" })
        await store.loadReceiptDetail(id: decathlon.id)
        snacks.show("Decathlon reviewed") {}
        await settle(0.5)
        write(view, "m07-undo-bar\(suffix)")
    }

    func testRenderScreens() async throws {
        try await seed()
        try await tour(.aqua, "")
        try await tour(.darkAqua, "-dark")

        for (appearance, suffix) in [(NSAppearance.Name.aqua, ""), (.darkAqua, "-dark")] {
            let (w1, chooser) = host(CategoryChooser(initial: Taxonomy.Path("Household", "Cleaning", "x")) { _ in }, appearance, size: CGSize(width: 460, height: 260))
            await settle()
            write(chooser, "m08-chooser\(suffix)")
            w1.close()
            let dog = try unwrapped(await store.flaggedItems().first { $0.name.contains("Hundefutter") })
            let (w2, sheet) = host(FlaggedItemsView(onlyDictionaryId: dog.id, close: {}), appearance, size: CGSize(width: 620, height: 520))
            await settle()
            write(sheet, "m09-item-sheet\(suffix)")
            w2.close()
        }

        // Resolve everything through the store (as the buttons do): the pane shows its empty state, the counts follow.
        let ids = await store.flaggedItems().map(\.id)
        let result = await store.resolveFlaggedItems(ids, to: Taxonomy.fallback)
        XCTAssertEqual(result, .resolved(count: ids.count))
        XCTAssertEqual(store.flaggedItemCount, 0)
        store.flaggedPaneOpen = true
        store.page = .review
        for (appearance, suffix) in [(NSAppearance.Name.aqua, ""), (.darkAqua, "-dark")] {
            let (w, view) = host(ContentView(), appearance)
            await settle()
            write(view, "m10-flagged-empty\(suffix)")
            w.close()
        }
    }

    private final class KeyableWindow: NSWindow { override var canBecomeKey: Bool { true } }

    private func click(_ view: NSView, x: CGFloat, yFromTop: CGFloat) async {
        guard let window = view.window else { return }
        let point = CGPoint(x: x, y: view.bounds.height - yFromTop)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
    }

    /// Real mouse events through the real window content: review, Undo, the flagged pane and its sheet. The coordinates come
    /// from the rendered layout of this window size and seed, so a layout change means updating them.
    func testClicksThroughTheMacScreens() async throws {
        try await seed()
        store.page = .review
        let view = NSHostingView(rootView: ContentView().environmentObject(store).environmentObject(snacks))
        let window = KeyableWindow(contentRect: CGRect(x: -6000, y: -6000, width: 1240, height: 820), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.setFrameOrigin(CGPoint(x: -6000, y: -6000))
        window.orderFrontRegardless()
        window.makeKey()
        defer { window.close() }
        await settle()

        // A list row selects the receipt.
        await click(view, x: 190, yFromTop: 460)
        await settle()
        XCTAssertEqual(store.selectedReceipt?.store, "Fressnapf")

        // Looks good: reviewed, on to the next, and the queued Kaufland is not picked. Undo comes back.
        await click(view, x: 1051, yFromTop: 771)
        await settle()
        let fressnapf = try unwrapped(store.receipts.first { $0.store == "Fressnapf" })
        XCTAssertNotNil(fressnapf.reviewedAt)
        XCTAssertEqual(store.selectedReceipt?.store, "Decathlon")
        write(view, "c01-after-looks-good")
        await click(view, x: 690, yFromTop: 727)
        await settle()
        XCTAssertNil(store.receipts.first { $0.store == "Fressnapf" }?.reviewedAt, "Undo")
        XCTAssertEqual(store.selectedReceipt?.store, "Fressnapf")

        // The sidebar entry opens the pane; the one-tap add files the first group.
        await click(view, x: 118, yFromTop: 298)
        await settle()
        XCTAssertTrue(store.flaggedPaneOpen)
        await click(view, x: 787, yFromTop: 355)
        await settle()
        XCTAssertEqual(store.flaggedItemCount, 2)
        XCTAssertNotNil(store.taxonomy.canonicalPath(matching: Taxonomy.Path("Household", "Pets", "Dog Supplies")))
        write(view, "c02-after-add")

        // FlagResolution.invalid: adding with nothing typed leaves everything as it was and says why.
        await click(view, x: 787, yFromTop: 677)
        await settle()
        XCTAssertEqual(store.flaggedItemCount, 2)
        write(view, "c03-invalid")

        // Choose existing: the sheet opens, "File here" files the fishing rod.
        await click(view, x: 637, yFromTop: 374)
        await settle()
        let sheet = try unwrapped(window.attachedSheet)
        let sheetView = try unwrapped(sheet.contentView)
        write(sheetView, "c04-chooser")
        await click(sheetView, x: sheetView.bounds.width - 60, yFromTop: sheetView.bounds.height - 34)
        await settle()
        XCTAssertNil(window.attachedSheet, "the sheet closed")
        XCTAssertEqual(store.flaggedItemCount, 1)
        write(view, "c05-after-choose")

        // Done, back to a receipt with the last flagged item.
        await click(view, x: 1138, yFromTop: 95)
        await settle()
        XCTAssertFalse(store.flaggedPaneOpen)
        await click(view, x: 190, yFromTop: 529)
        await settle()
        XCTAssertEqual(store.selectedReceipt?.store, "Decathlon")
        XCTAssertTrue(store.selectedReceipt?.items.contains { $0.categoryFlagged } == true)
        write(view, "c06-receipt-with-mark")

        // `Sort out…` on the row opens the one-item sheet.
        await click(view, x: 1146, yFromTop: 327)
        await settle()
        let itemSheet = try unwrapped(window.attachedSheet)
        let itemView = try unwrapped(itemSheet.contentView)
        write(itemView, "c07-item-sheet")
        await click(itemView, x: itemView.bounds.width - 55, yFromTop: 38)
        await settle()
        XCTAssertNil(window.attachedSheet, "Done closes it")

        // Overview's Edit (the same call as its button): back on Review, on that receipt, with the item open.
        await click(view, x: 1170, yFromTop: 28)
        await settle(1)
        XCTAssertEqual(store.page, .overview)
        let idee = try unwrapped(store.receipts.first { $0.store == "Idee" })
        let yarn = try await store.db.queryOne("SELECT id FROM item_dictionary WHERE canonical_name = 'wolle'")?.int(0)
        await store.jumpToItem(receiptId: idee.id, itemDictionaryId: try unwrapped(yarn))
        await settle(0.5)
        XCTAssertEqual(store.page, .review)
        XCTAssertEqual(store.selectedReceipt?.store, "Idee")
        write(view, "c08-edit-opens-the-item")
    }

    private func unwrapped<T>(_ v: T?) throws -> T { try XCTUnwrap(v) }
}
#endif
