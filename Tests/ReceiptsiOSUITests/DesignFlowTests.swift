import XCTest

/// Real taps through the iPhone screens against a local throwaway backend with seeded data. Configuration comes from the
/// runner environment like `E2EFlowTests` (`TEST_RUNNER_E2E_URL`, `TEST_RUNNER_E2E_TOKEN`, `TEST_RUNNER_E2E_SHOTS`,
/// `TEST_RUNNER_E2E_SUFFIX`); without it every test is skipped. The tests run in order, each builds on the last.
final class DesignFlowTests: XCTestCase {
    private var app: XCUIApplication!
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(env["E2E_URL"] != nil, "needs a local test backend")
        app = XCUIApplication()
        if env["E2E_SUFFIX"] == "-dark" { app.launchArguments += ["-AppleInterfaceStyle", "Dark"] }
    }

    private func shot(_ name: String) {
        let suffix = env["E2E_SUFFIX"] ?? ""
        guard let dir = env["E2E_SHOTS"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/\(name)\(suffix).png"))
    }

    private func tab(_ name: String) {
        let button = app.tabBars.buttons[name].exists ? app.tabBars.buttons[name] : app.buttons[name]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "tab \(name)")
        button.tap()
    }

    private func text(_ contains: String) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", contains)).firstMatch
    }

    private func button(_ contains: String) -> XCUIElement {
        app.buttons.containing(NSPredicate(format: "label CONTAINS %@", contains)).firstMatch
    }

    private func wait(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 15) {
        let found = element.waitForExistence(timeout: timeout)
        if !found { shot("fail-" + what.replacingOccurrences(of: " ", with: "-")) }
        XCTAssertTrue(found, what)
    }

    private func waitGone(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 10) {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: timeout), .completed, what)
    }

    private func replace(_ field: XCUIElement, with value: String) {
        field.tap()
        sleep(1)
        field.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        field.typeText(value)
    }

    /// Taps until the keyboard has the field (a tap right after a tab switch can land before the field is ready).
    private func type(_ value: String, into field: XCUIElement) {
        for _ in 0..<4 where !field.hasKeyboardFocus {
            field.tap()
            sleep(1)
        }
        field.typeText(value)
    }

    private func keyboardDone() {
        let done = app.toolbars.buttons["Done"].exists ? app.toolbars.buttons["Done"] : app.buttons["Done"]
        if done.exists { done.tap() }
    }

    /// Scrolls until the element is on screen, within the given number of swipes.
    private func scrollTo(_ element: XCUIElement, up: Bool = true, swipes: Int = 8) {
        var left = swipes
        while !(element.exists && element.isHittable), left > 0 {
            if up { app.swipeUp(velocity: .slow) } else { app.swipeDown(velocity: .slow) }
            left -= 1
        }
    }

    /// Leaves the active search field (the toolbar comes back). The button is `Close` on iOS 26, `Cancel` before.
    private func closeSearch() {
        for name in ["Close", "Cancel"] where app.buttons[name].exists {
            app.buttons[name].firstMatch.tap()
            break
        }
        sleep(1)
    }

    /// A confirmation dialog on iOS 26 is a popover with no Cancel button: a tap outside cancels it.
    private func cancelDialog() {
        let outside = app.otherElements["PopoverDismissRegion"].firstMatch
        if app.buttons["Cancel"].exists {
            app.buttons["Cancel"].firstMatch.tap()
        } else if outside.exists {
            outside.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
        }
        sleep(2)
    }

    private func launchToList() {
        app.launch()
        wait(button("ALDI").exists ? button("ALDI") : button("Edeka"), "list loaded", timeout: 30)
    }

    // MARK: Setup

    func test01_SetupInvalidURLConnectAndTest() throws {
        app.launchArguments += ["-resetReceiptsSettings"]
        app.launch()
        wait(text("Connect to your server"), "setup prompt")
        shot("a01-setup")
        app.buttons["openSettingsButton"].tap()
        let url = app.textFields["serverURLField"]
        wait(url, "settings")
        shot("a02-settings-empty")
        XCTAssertFalse(app.buttons["saveSettingsButton"].isEnabled, "nothing to save yet")
        type("not a url", into: url)
        wait(text("Not a valid address"), "invalid url note")
        shot("a03-settings-invalid")
        replace(url, with: env["E2E_URL"]!)
        let token = app.secureTextFields["tokenField"]
        type(env["E2E_TOKEN"]!, into: token)
        app.buttons["saveSettingsButton"].tap()
        sleep(1)
        shot("a04-settings-saved")
        let test = app.buttons["testConnectionButton"]
        wait(test, "test button")
        test.tap()
        let result = app.staticTexts["testConnectionResult"]
        wait(result, "test result", timeout: 20)
        let connected = expectation(for: NSPredicate(format: "label CONTAINS 'Connected'"), evaluatedWith: result)
        wait(for: [connected], timeout: 20)
        shot("a05-settings-connected")
        app.swipeUp()
        sleep(1)
        shot("a06-settings-sync-photos")
        tab("Receipts")
        wait(button("REWE"), "seeded receipts arrive", timeout: 40)
        sleep(2)
        shot("a07-list")
    }

    // MARK: List

    func test02_ListStatesSearchAndFilters() throws {
        launchToList()
        // Inline reason, badge, processing rows
        wait(text("Item prices sum to"), "first review reason inline")
        wait(text("Could not read this receipt"), "failed row")
        let badge = app.tabBars.buttons["Receipts"]
        if badge.exists { XCTAssertNotNil(badge.value) }
        shot("b01-list")

        // Search
        let search = app.searchFields.firstMatch
        wait(search, "search is always visible")
        search.tap()
        search.typeText("Dish soap")
        wait(button("“Dish soap”"), "search tag")
        sleep(1)
        XCTAssertTrue(button("REWE").exists, "translation search finds REWE")
        XCTAssertFalse(button("ALDI").exists, "ALDI has no dish soap")
        shot("b02-search")
        search.typeText("zzzz")
        wait(text("No receipts match."), "no match state")
        shot("b03-no-match")
        button("Clear filters").tap()
        wait(button("ALDI"), "all back")
        closeSearch()

        // Filter sheet: chips, live count, tags
        app.buttons["filtersMenu"].tap()
        let count = app.staticTexts["filterResultCount"]
        wait(count, "filter panel")
        shot("b04-filters")
        let unfiltered = count.label
        button("Lidl").tap()
        sleep(1)
        XCTAssertNotEqual(count.label, unfiltered, "count is live")
        XCTAssertEqual(count.label, "2 receipts")
        shot("b05-filters-store")
        button("This month").tap()
        sleep(1)
        XCTAssertEqual(count.label, "0 receipts")
        button("All time").tap()
        app.buttons["Done"].tap()
        wait(button("Lidl"), "filtered row")
        XCTAssertFalse(button("ALDI").exists)
        shot("b06-filtered-tags")
        // The tag removes the filter
        let tag = app.buttons["Lidl"].firstMatch
        wait(tag, "store tag")
        tag.tap()
        wait(button("ALDI"), "tag removed")

        // Confirm all without flags opens from the panel; cancel it
        app.buttons["filtersMenu"].tap()
        wait(button("Confirm all without flags"), "bulk confirm")
        button("Confirm all without flags").tap()
        wait(app.buttons["Confirm all"], "dialog after the panel closed")
        shot("b07-confirm-all")
        cancelDialog()
    }

    // MARK: Detail

    func test03_DetailEditSaveAddDeleteUndo() throws {
        launchToList()
        button("REWE").tap()
        wait(app.staticTexts["nextToReviewHint"], "hint")
        XCTAssertTrue(app.staticTexts["nextToReviewHint"].label.contains("more to review · next:"), app.staticTexts["nextToReviewHint"].label)
        sleep(1)
        shot("c01-detail-top")
        wait(text("Difference:"), "difference line (sum mismatch)")
        XCTAssertTrue(app.buttons["Looks good"].isEnabled)

        // The flagged item starts open; the others are compact.
        let price = app.textFields["priceField"]
        XCTAssertEqual(app.textFields.matching(identifier: "priceField").count, 1, "only the flagged item is open")
        scrollTo(price)
        shot("c02-flagged-open")

        // Expand a compact row and edit it, with a German comma.
        let row = button("Roggenbrot")
        scrollTo(row, up: false)
        row.tap()
        sleep(1)
        XCTAssertEqual(app.textFields.matching(identifier: "priceField").count, 2, "the tapped row opened")
        shot("c03-expanded")
        let rowPrice = app.textFields.matching(identifier: "priceField").firstMatch
        scrollTo(rowPrice)
        replace(rowPrice, with: "3,49")
        keyboardDone()
        sleep(1)
        let save = app.buttons.matching(identifier: "saveItemButton").firstMatch
        scrollTo(save)
        save.tap()
        sleep(2)
        shot("c04-saved")
        XCTAssertTrue(text("€3.49").waitForExistence(timeout: 5), "new price shown")

        // Bad number
        replace(rowPrice, with: "x")
        keyboardDone()
        scrollTo(save)
        save.tap()
        wait(app.buttons["Bad qty/price"], "bad number state")
        shot("c05-bad-number")
        replace(rowPrice, with: "3.49")
        keyboardDone()

        // Category change shows the shared dictionary note
        let categoryPicker = app.buttons.matching(identifier: "Category").firstMatch
        scrollTo(categoryPicker)
        categoryPicker.tap()
        sleep(1)
        wait(app.buttons["Household"], "category menu")
        app.buttons["Household"].tap()
        sleep(1)
        wait(text("Saving updates the dictionary entry"), "shared dictionary note")
        shot("c06-category-note")

        // Add form is open on a sum mismatch: empty add is refused, then a real add
        let add = app.buttons["Add"]
        scrollTo(add)
        wait(add, "add form starts open on a mismatch")
        add.tap()
        wait(text("Enter an item name and a price."), "add validation")
        shot("c07-add-error")
        app.textFields["Item name"].tap()
        app.textFields["Item name"].typeText("Kaugummi")
        app.textFields["Price €"].tap()
        app.textFields["Price €"].typeText("1,20")
        keyboardDone()
        add.tap()
        wait(button("Kaugummi"), "added item shows", timeout: 20)
        shot("c08-added")

        // Delete the added item (flagged by the fallback category, so it starts open), then undo
        let added = button("Kaugummi")
        let trash = app.buttons.matching(NSPredicate(format: "label == 'Delete item'")).allElementsBoundByIndex.last(where: { $0.exists })
        let deleteItem = try XCTUnwrap(trash)
        scrollTo(deleteItem)
        deleteItem.tap()
        wait(app.buttons["undoButton"], "item delete offers undo", timeout: 8)
        shot("c09-item-deleted-undo")
        waitGone(added, "item gone")
        app.buttons["undoButton"].tap()
        wait(button("Kaugummi"), "undo restored the item", timeout: 8)
        shot("c10-item-restored")

        // Photo tab
        app.buttons["Photo"].tap()
        wait(text("This receipt has no photo."), "no photo note")
        shot("c11-photo-missing")
        app.buttons["Items"].tap()
        sleep(1)

        // Delete dialog uses a trash icon
        wait(app.buttons["Delete receipt"], "trash icon in the header")
        scrollTo(app.buttons["Delete receipt"], up: false)
        app.buttons["Delete receipt"].tap()
        wait(text("Delete this receipt?"), "delete dialog")
        shot("c12-delete-dialog")
        cancelDialog()
        sleep(1)

        // More menu
        app.buttons["More"].tap()
        wait(button("Delete receipt…"), "menu has delete")
        sleep(1)
        shot("c13-more-menu")
        XCTAssertFalse(button("Re-run extraction").exists, "no server photo: no re-run")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()   // outside the menu
        sleep(2)

        // Looks good moves on in place
        let hint = app.staticTexts["nextToReviewHint"].label
        let next = hint.components(separatedBy: "next: ").last ?? ""
        app.buttons["Looks good"].tap()
        wait(app.staticTexts[next], "moved on to \(next)", timeout: 10)
        sleep(1)
        shot("c14-next")
        app.navigationBars.buttons.firstMatch.tap()
        wait(button("REWE"), "back on the list")
    }

    func test04_ProcessingStatesAndPhoto() throws {
        launchToList()
        // Failed extraction
        button("Could not read this receipt").tap()
        wait(button("Retry extraction"), "retry button")
        sleep(1)
        shot("d01-detail-failed")
        app.buttons["Looks good"].firstMatch.tap()   // allowed: filled in by hand. Next receipt loads.
        sleep(2)
        shot("d01b-after-looks-good")
        app.navigationBars.buttons.firstMatch.tap()
        // It reaches the server (debounce, then the push), and stays confirmed.
        sleep(8)
        let receipts = try XCTUnwrap(try serverRecords()["receipts"] as? [[String: Any]])
        let failedOne = try XCTUnwrap(receipts.first { $0["extraction_status"] as? String == "failed" })
        XCTAssertFalse(failedOne["reviewed_at"] is NSNull, "confirmed on the server")
        // Still being read: Looks good is disabled
        let reading = button("Reading receipt on the server")
        wait(reading, "queued row", timeout: 10)
        reading.tap()
        wait(text("The server reads the photo"), "processing panel")
        XCTAssertFalse(app.buttons["Looks good"].isEnabled, "disabled while it is being read")
        shot("d02-detail-processing")
        app.navigationBars.buttons.firstMatch.tap()
        // A photo the server holds: downloaded, zoom bar, re-run offered
        let kaufland = button("Kaufland")
        wait(kaufland, "extracted receipt")
        kaufland.tap()
        wait(app.buttons["Photo"], "detail")
        app.buttons["More"].tap()
        wait(button("Re-run extraction"), "server photo: re-run offered")
        button("Re-run extraction").tap()
        wait(text("Re-run extraction?"), "re-run dialog")
        shot("d03-rerun-dialog")
        cancelDialog()
        sleep(1)
        app.buttons["Photo"].tap()
        wait(app.images.firstMatch, "the photo", timeout: 20)
        sleep(2)
        shot("d04-photo")
        app.buttons["Zoom in"].tap()
        sleep(1)
        app.buttons["100%"].tap()
        sleep(1)
        shot("d05-photo-100")
        app.buttons["Fit"].tap()
        app.navigationBars.buttons.firstMatch.tap()
    }

    // MARK: Swipes and undo

    func test05_SwipeConfirmDeleteUndoRestorePermanentDelete() throws {
        launchToList()
        let row = button("Edeka")
        wait(row, "Edeka row")

        // Swipe right: Looks good, then undo.
        let aldi = button("dm")
        wait(aldi, "dm row")
        aldi.swipeRight()
        let confirm = app.buttons["Looks good"].firstMatch
        wait(confirm, "swipe action")
        shot("e01-swipe-right")
        confirm.tap()
        wait(app.buttons["undoButton"], "confirm offers undo", timeout: 8)
        XCTAssertTrue(text("dm reviewed").exists, "snack text")
        shot("e02-reviewed-undo")
        app.buttons["undoButton"].tap()
        wait(text("No total found on receipt"), "undo put the warning line back", timeout: 8)
        shot("e03-after-undo")

        // Swipe left: Delete, then undo.
        aldi.swipeLeft()
        let delete = app.buttons["Delete"].firstMatch
        wait(delete, "swipe delete")
        shot("e04-swipe-left")
        delete.tap()
        wait(app.buttons["undoButton"], "delete offers undo", timeout: 8)
        wait(text("Moved to Recently deleted"), "snack text")
        shot("e05-deleted-undo")
        app.buttons["undoButton"].tap()   // right away: the bar only stays 5 seconds; "row left" is checked below
        wait(button("dm"), "undo restored the row", timeout: 8)

        // Delete again, let the undo window pass, restore from Recently deleted.
        button("dm").swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        waitGone(button("dm"), "row left")
        sleep(6)
        XCTAssertFalse(app.buttons["undoButton"].exists, "the snack times out")
        let deletedHeader = button("RECENTLY DELETED")
        scrollTo(deletedHeader)
        wait(deletedHeader, "recently deleted")
        deletedHeader.tap()
        sleep(1)
        scrollTo(app.buttons["Restore"].firstMatch)
        shot("e06-recently-deleted-open")
        let restore = app.buttons["Restore"].firstMatch
        wait(restore, "restore")
        restore.tap()
        sleep(2)
        shot("e07-restored")
        // Permanent delete: dialog, cancel, then for real (the seeded Netto receipt).
        let permanent = app.buttons["Delete"].firstMatch
        scrollTo(permanent)
        app.swipeUp()
        sleep(1)
        wait(permanent, "permanent delete button")
        permanent.tap()
        wait(text("Permanently delete this receipt?"), "permanent dialog")
        shot("e08-permanent-dialog")
        cancelDialog()
        sleep(1)
        permanent.tap()
        app.buttons["Delete permanently"].tap()
        waitGone(deletedHeader, "nothing left in recently deleted")
        sleep(1)
        shot("e09-after-permanent")
    }

    // MARK: Undo after the change reached the server

    /// The server's copy of everything (the local test backend; the token is the e2e dummy).
    private func serverRecords() throws -> [String: Any] {
        var request = URLRequest(url: try XCTUnwrap(URL(string: env["E2E_URL"]! + "/api/v1/receipts/sync/pull?since=")))
        request.setValue("Bearer \(env["E2E_TOKEN"]!)", forHTTPHeaderField: "Authorization")
        let done = expectation(description: "pull")
        var out: [String: Any] = [:]
        URLSession.shared.dataTask(with: request) { data, _, _ in
            out = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        return out
    }

    private func serverReceipt(_ store: String) throws -> [String: Any] {
        let receipts = try XCTUnwrap(try serverRecords()["receipts"] as? [[String: Any]])
        return try XCTUnwrap(receipts.first { $0["store"] as? String == store })
    }

    private func serverLine(_ name: String) throws -> [String: Any] {
        let lines = try XCTUnwrap(try serverRecords()["line_items"] as? [[String: Any]])
        return try XCTUnwrap(lines.first { $0["name_de"] as? String == name })
    }

    /// Polls until the condition holds or the snack's 5 seconds are nearly over.
    private func untilPushed(_ condition: () throws -> Bool) throws -> Bool {
        let end = Date().addingTimeInterval(4.8)
        while Date() < end {
            if try condition() { return true }
            usleep(100_000)
        }
        return false
    }

    func test05b_UndoAfterTheChangeWasPushed() throws {
        launchToList()
        // Confirm by swipe, wait until the server has it, undo: the server goes back to unreviewed.
        let aldi = button("ALDI")
        wait(aldi, "ALDI row")
        aldi.swipeRight()
        app.buttons["Looks good"].firstMatch.tap()
        wait(app.buttons["undoButton"], "undo offered", timeout: 8)
        let reviewedPushed = try untilPushed { !(try serverReceipt("ALDI SÜD")["reviewed_at"] is NSNull) }
        XCTAssertTrue(reviewedPushed, "the confirmation reached the server before the snack ended")
        app.buttons["undoButton"].tap()
        sleep(7)   // debounce and push
        XCTAssertTrue(try serverReceipt("ALDI SÜD")["reviewed_at"] is NSNull, "the undo reached the server")
        wait(button("ALDI"), "ALDI row is back in Needs review")

        // Delete by swipe, same.
        button("ALDI").swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        wait(app.buttons["undoButton"], "undo offered", timeout: 8)
        let deletePushed = try untilPushed { !(try serverReceipt("ALDI SÜD")["deleted_at"] is NSNull) }
        XCTAssertTrue(deletePushed, "the delete reached the server before the snack ended")
        app.buttons["undoButton"].tap()
        sleep(7)
        XCTAssertTrue(try serverReceipt("ALDI SÜD")["deleted_at"] is NSNull, "the server undeleted it")
        wait(button("ALDI"), "ALDI row is back")

        // Delete an item, same: the same record comes back.
        button("ALDI").tap()
        wait(button("Apfelsaft"), "items")
        let id = try XCTUnwrap(try serverLine("Apfelsaft")["id"] as? String)
        button("Tomaten").tap()   // keeps Apfelsaft compact, opens this row's editor
        sleep(1)
        let lineBefore = try XCTUnwrap(try serverRecords()["line_items"] as? [[String: Any]])
        XCTAssertTrue(lineBefore.contains { $0["id"] as? String == id })
        app.buttons["Delete item"].firstMatch.tap()
        wait(app.buttons["undoButton"], "undo offered", timeout: 8)
        waitGone(button("Tomaten"), "item left")
        func tomatoDeleted() throws -> Bool {
            let lines = try XCTUnwrap(try serverRecords()["line_items"] as? [[String: Any]])
            let receipt = try serverReceipt("ALDI SÜD")["id"] as? String
            return lines.contains { $0["receipt_id"] as? String == receipt && $0["name_de"] as? String == "Tomaten" && !($0["deleted_at"] is NSNull) }
        }
        XCTAssertTrue(try untilPushed { try tomatoDeleted() }, "the item delete reached the server before the snack ended")
        app.buttons["undoButton"].tap()
        wait(button("Tomaten"), "item back on screen", timeout: 8)
        sleep(7)
        XCTAssertFalse(try tomatoDeleted(), "the server has the same item undeleted")
        app.navigationBars.buttons.firstMatch.tap()
    }

    // MARK: Overview

    func test06_OverviewRangesDrilldownEdit() throws {
        launchToList()
        tab("Overview")
        wait(app.staticTexts["overviewTotal"], "overview")
        sleep(2)
        shot("f01-month")
        XCTAssertFalse(app.buttons["Next"].isEnabled, "next disabled on the current month")
        let monthTotal = app.staticTexts["overviewTotal"].label
        app.buttons["Previous"].tap()
        sleep(2)
        XCTAssertNotEqual(app.staticTexts["overviewTotal"].label, monthTotal, "previous month has another total")
        XCTAssertTrue(app.buttons["Next"].isEnabled)
        shot("f02-prev-month")
        app.buttons["Next"].tap()
        sleep(1)
        app.swipeUp()
        sleep(1)
        shot("f03-month-scrolled")
        app.swipeDown()
        sleep(1)

        app.buttons["Year"].tap()
        sleep(2)
        shot("f04-year")
        app.buttons["Custom"].tap()
        sleep(2)
        shot("f05-custom")
        app.buttons["All time"].firstMatch.tap()
        sleep(2)
        shot("f06-all")

        // Drilldown to purchases, then Edit opens the receipt with that item open.
        let food = button("Food")
        scrollTo(food)
        food.tap()
        sleep(1)
        let dairy = button("Dairy & Eggs")
        scrollTo(dairy)
        dairy.tap()
        sleep(1)
        let milk = button("Milk")
        scrollTo(milk)
        milk.tap()
        sleep(2)
        let edit = app.buttons["Edit"].firstMatch
        scrollTo(edit)
        wait(edit, "purchases")
        shot("f07-drilldown")
        scrollTo(text("PRICE HISTORY"), up: false)
        shot("f08-price-history")
        scrollTo(edit)
        edit.tap()
        wait(app.buttons["Photo"], "the receipt opened", timeout: 10)
        wait(app.textFields["priceField"], "with the item open")
        sleep(2)
        shot("f09-edit-opens-item")
        app.navigationBars.buttons.firstMatch.tap()
        wait(app.staticTexts["overviewTotal"], "back on the overview")
        tab("Receipts")
    }

    // MARK: Settings

    func test07_SettingsSyncCacheDisconnectReconnect() throws {
        launchToList()
        tab("Settings")
        wait(app.buttons["testConnectionButton"], "settings")
        app.buttons["testConnectionButton"].tap()
        wait(app.staticTexts["testConnectionResult"], "result", timeout: 20)
        shot("g01-test-result")
        app.swipeUp()
        wait(app.buttons["syncNowButton"], "sync section")
        app.buttons["syncNowButton"].tap()
        sleep(2)
        XCTAssertNotEqual(app.staticTexts["lastSyncValue"].label, "Never")
        shot("g02-synced")
        let clear = app.buttons["clearCacheButton"]
        scrollTo(clear)
        clear.tap()
        wait(text("Clear cached photos?"), "dialog")
        shot("g03-clear-dialog")
        let confirm = app.popovers.buttons["Clear cached photos"].exists ? app.popovers.buttons["Clear cached photos"] : app.sheets.buttons["Clear cached photos"]
        if confirm.exists { confirm.tap() } else { app.buttons.matching(identifier: "Clear cached photos").firstMatch.tap() }
        sleep(1)
        shot("g04-cleared")
        app.swipeDown()
        app.swipeDown()
        sleep(1)
        app.buttons["disconnectButton"].tap()
        sleep(1)
        wait(app.secureTextFields["tokenField"], "token field")
        XCTAssertFalse(app.buttons["disconnectButton"].exists, "no disconnect without a token")
        shot("g05-disconnected")
        // Receipts stay on the phone while disconnected.
        tab("Receipts")
        wait(button("REWE"), "local data stays")
        XCTAssertFalse(text("Synced").exists, "sync row hidden")
        shot("g06-list-disconnected")
        tab("Settings")
        let token = app.secureTextFields["tokenField"]
        type(env["E2E_TOKEN"]!, into: token)
        app.buttons["saveSettingsButton"].tap()
        sleep(3)
        shot("g07-reconnected")
        tab("Receipts")
        wait(text("Synced"), "sync back on", timeout: 20)
    }

    // MARK: Uploads

    func test08_UploadQueueFromThePhotoPicker() throws {
        launchToList()
        app.buttons["photosButton"].tap()
        XCTAssertTrue(app.scrollViews.images.firstMatch.waitForExistence(timeout: 30), "photo picker")
        sleep(3)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.17, dy: 0.47)).tap()
        sleep(1)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.47)).tap()
        sleep(1)
        shot("h01-picker")
        app.buttons["Add"].tap()
        wait(text("UPLOADS"), "upload panel", timeout: 20)
        shot("h02-upload-running")
        wait(button("Clear finished"), "panel actions")
        sleep(6)
        shot("h03-upload-finished")
        let finished = text("the server is reading it")
        if finished.waitForExistence(timeout: 20) {
            finished.tap()
            wait(text("The server reads the photo"), "a finished row opens its receipt", timeout: 10)
            shot("h04-opened-from-queue")
            app.navigationBars.buttons.firstMatch.tap()
        }
        // A job that lost the race with a running sync says "Upload failed" and stays until retried; the others go.
        button("Clear finished").tap()
        if !button("Retry failed").exists { waitGone(text("UPLOADS"), "panel cleared", timeout: 5) }
    }

    // MARK: Confirm all, the last one to review, the reviewed status

    func test08b_ConfirmAllThenLastOneGoesBack() throws {
        launchToList()
        app.buttons["filtersMenu"].tap()
        wait(button("Confirm all without flags"), "bulk confirm")
        button("Confirm all without flags").tap()
        wait(app.buttons["Confirm all"], "dialog")
        app.buttons["Confirm all"].tap()
        sleep(2)
        shot("j01-after-confirm-all")
        // Only flagged ones are left (dm, and REWE unless an earlier test confirmed it): work through them.
        button("dm").tap()
        let hint = app.staticTexts["nextToReviewHint"]
        wait(hint, "hint")
        if hint.label.hasPrefix("1 more to review") {
            XCTAssertEqual(hint.label, "1 more to review · next: REWE")
            app.buttons["Looks good"].tap()
            sleep(2)
        }
        XCTAssertEqual(hint.label, "Last one to review")
        shot("j02-last-one")
        app.buttons["Looks good"].tap()
        wait(app.buttons["filtersMenu"], "nothing left: back on the list", timeout: 10)
        sleep(1)
        shot("j03-all-reviewed")
        button("dm").tap()
        wait(app.staticTexts["Reviewed ✓"], "the reviewed status")
        XCTAssertFalse(app.buttons["Looks good"].exists)
        sleep(1)
        shot("j04-reviewed-status")
        app.navigationBars.buttons.firstMatch.tap()
    }

    // MARK: Server unreachable (run with the backend stopped)

    func test10_OfflineSyncFailedErrorBarWaitingToUpload() throws {
        app.launch()
        wait(button("REWE"), "local data")
        wait(text("Sync failed"), "sync row says so", timeout: 40)
        sleep(1)
        shot("k01-sync-failed")
        // A failed extraction cannot be retried without the server: the error bar.
        let failed = button("Could not read this receipt")
        scrollTo(failed)
        failed.tap()
        wait(button("Retry extraction"), "panel")
        button("Retry extraction").tap()
        wait(text("Retrying the extraction failed"), "error bar", timeout: 30)
        sleep(1)
        shot("k02-error-bar")
        app.buttons["Dismiss"].tap()
        waitGone(text("Retrying the extraction failed"), "dismissed")
        app.navigationBars.buttons.firstMatch.tap()
        // A new photo waits in the outbox.
        app.buttons["photosButton"].tap()
        XCTAssertTrue(app.scrollViews.images.firstMatch.waitForExistence(timeout: 30), "photo picker")
        sleep(3)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.17, dy: 0.47)).tap()
        sleep(1)
        app.buttons["Add"].tap()
        let waiting = button("Waiting to upload")
        wait(waiting, "row waits", timeout: 30)
        sleep(1)
        shot("k03-upload-offline")
        waiting.tap()
        wait(text("saved on this iPhone"), "this iPhone, not this Mac", timeout: 10)
        sleep(1)
        shot("k04-waiting-panel")
        app.navigationBars.buttons.firstMatch.tap()
    }

    /// Run after setting that receipt to `upload_failed` in the simulator's throwaway database.
    func test11_UploadFailedPanel() throws {
        app.launch()
        let failed = button("Upload failed")
        wait(failed, "row", timeout: 20)
        shot("k05-upload-failed-row")
        failed.tap()
        wait(button("Retry upload"), "retry")
        wait(button("Remove receipt"), "remove")
        sleep(1)
        shot("k06-upload-failed-panel")
        button("Remove receipt").tap()
        waitGone(button("Upload failed"), "gone from the list")
    }

    // MARK: Banners (backend started with the archive and disk thresholds forced on)

    func test12_Banners() throws {
        launchToList()
        let banner = text("wait on the server")
        wait(banner, "archive banner", timeout: 40)
        wait(text("low on disk space"), "disk banner")
        sleep(1)
        shot("l01-banners")
        tab("Overview")
        sleep(2)
        XCTAssertTrue(banner.exists, "banners stay above every tab")
        shot("l02-banners-overview")
        tab("Receipts")
    }

    // MARK: Empty state (run against a second, empty backend)

    func test09_EmptyServer() throws {
        app.launchArguments += ["-resetReceiptsSettings"]
        app.launch()
        app.buttons["openSettingsButton"].tap()
        let url = app.textFields["serverURLField"]
        wait(url, "settings")
        type(env["E2E_URL"]!, into: url)
        let token = app.secureTextFields["tokenField"]
        type(env["E2E_TOKEN"]!, into: token)
        app.buttons["saveSettingsButton"].tap()
        sleep(2)
        tab("Receipts")
        wait(text("No receipts yet."), "empty state", timeout: 20)
        wait(button("Scan receipt"), "scan")
        shot("i01-empty")
        button("Scan receipt").tap()
        // Depending on the simulator: the alert, or the real document camera (asks for the camera first).
        sleep(2)
        shot("i02-scan")
        if app.buttons["OK"].exists { app.buttons["OK"].tap() }
    }
}

private extension XCUIElement {
    var hasKeyboardFocus: Bool { (value(forKey: "hasKeyboardFocus") as? Bool) ?? false }
}
