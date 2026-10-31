import XCTest

/// The iPhone simulator e2e run (Tests/ios-e2e/run.sh drives these phases one by one, with the backend and the Mac
/// "laptop" in between). Configuration comes from the runner environment (`TEST_RUNNER_E2E_URL`,
/// `TEST_RUNNER_E2E_TOKEN` are the temp backend's dummy values; `TEST_RUNNER_E2E_SHOTS` is the screenshot folder and
/// `TEST_RUNNER_E2E_SUFFIX` e.g. `-dark`). Without them every test is skipped.
final class E2EFlowTests: XCTestCase {
    private var app: XCUIApplication!
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(env["E2E_URL"] != nil, "run through Tests/ios-e2e/run.sh")
        app = XCUIApplication()
        // The simulator's appearance setting does not reach the app under test: ask for it explicitly.
        if env["E2E_SUFFIX"] == "-dark" { app.launchArguments += ["-AppleInterfaceStyle", "Dark"] }
    }

    private func shot(_ name: String) {
        let suffix = env["E2E_SUFFIX"] ?? ""
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = env["E2E_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name)\(suffix).png"))
        }
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name + suffix
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func tab(_ name: String) {
        let button = app.tabBars.buttons[name].exists ? app.tabBars.buttons[name] : app.buttons[name]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "tab \(name)")
        button.tap()
    }

    private func clearAndType(_ field: XCUIElement, _ text: String) {
        field.tap()
        if let current = field.value as? String, !current.isEmpty, current != field.placeholderValue {
            field.press(forDuration: 1.0)
            if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
            field.typeText(XCUIKeyboardKey.delete.rawValue)
        }
        field.typeText(text)
    }

    private func pullToRefresh() {
        let list = app.collectionViews["receiptList"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        start.press(forDuration: 0.1, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)))
    }

    private func receiptRow(containing text: String) -> XCUIElement {
        app.buttons.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func waitForRow(_ text: String, timeout: TimeInterval = 40) -> XCUIElement {
        let row = receiptRow(containing: text)
        let end = Date().addingTimeInterval(timeout)
        while !row.exists, Date() < end {
            pullToRefresh()
            _ = row.waitForExistence(timeout: 4)
        }
        XCTAssertTrue(row.exists, "a receipt row containing \(text)")
        return row
    }

    // MARK: Phase 1: set up, add two photos

    func testPhase1ConfigureAndUpload() throws {
        app.launchArguments += ["-resetReceiptsSettings"]
        app.launch()
        shot("01-first-launch")
        tab("Settings")
        let url = app.textFields["serverURLField"]
        XCTAssertTrue(url.waitForExistence(timeout: 10))
        url.tap()
        url.typeText(env["E2E_URL"]!)
        let token = app.secureTextFields["tokenField"]
        token.tap()
        token.typeText(env["E2E_TOKEN"]!)
        shot("02-settings-filled")
        app.buttons["saveSettingsButton"].tap()
        app.buttons["testConnectionButton"].tap()
        let result = app.staticTexts["testConnectionResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 20))
        let ok = NSPredicate(format: "label CONTAINS 'Connected'")
        expectation(for: ok, evaluatedWith: result)
        waitForExpectations(timeout: 20)
        shot("03-settings-connected")

        tab("Receipts")
        app.buttons["photosButton"].tap()
        // the system photo picker: pick the first two photos (the JPEG and the HEIC added with simctl addmedia)
        let pickerUp = app.scrollViews.images.firstMatch.waitForExistence(timeout: 30)
        if !pickerUp { shot("04a-picker-missing") }
        XCTAssertTrue(pickerUp, "photo picker shows photos")
        sleep(3)   // thumbnails load
        shot("04-photo-picker")
        // The picker's tiles are not "hittable" for XCUITest: tap the first two tiles (the two sample receipts) by position.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.17, dy: 0.47)).tap()
        sleep(1)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.47)).tap()
        sleep(1)
        shot("04b-photo-picker-selected")
        let add = app.buttons["Add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        // the receipts show up as waiting / being read
        let reading = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Reading receipt' OR label CONTAINS 'Waiting to upload'")).firstMatch
        XCTAssertTrue(reading.waitForExistence(timeout: 40), "uploaded receipts show as being read")
        sleep(3)
        shot("05-uploaded-reading")
    }

    // MARK: Phase 2: extraction arrived (seeded), edit an item, confirm

    func testPhase2ReviewEditConfirm() throws {
        app.launch()
        let row = waitForRow("Edeka")
        shot("06-list-extracted")
        row.tap()
        let price = app.textFields["priceField"].firstMatch
        XCTAssertTrue(price.waitForExistence(timeout: 15))
        shot("07-detail-items")
        clearAndType(price, "2.59")
        app.buttons["saveItemButton"].firstMatch.tap()
        sleep(1)
        shot("08-detail-edited")
        app.buttons["Photo"].tap()
        sleep(1)
        shot("09-detail-photo")
        app.buttons["Items"].tap()
        let confirm = app.buttons["Looks good"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        sleep(2)
        shot("10-after-confirm-next")
        // the edit goes out shortly (debounced); wait for the sync before the script checks the server
        sleep(8)
    }

    // MARK: Phase 3: the Mac archived the photos, the phone's cached copies are cleared

    func testPhase3PhotoOnTheLaptop() throws {
        app.launch()
        _ = waitForRow("Edeka")
        tab("Settings")
        XCTAssertTrue(app.buttons["clearCacheButton"].waitForExistence(timeout: 10))
        app.swipeUp()
        sleep(1)
        shot("11-settings-cache")
        app.buttons["clearCacheButton"].tap()
        sleep(1)
        shot("11b-clear-cache-dialog")
        // the confirmation is a popover: its button sits at the centre of the card shown above the list row
        let inPopover = app.popovers.buttons["Clear cached photos"]
        if inPopover.waitForExistence(timeout: 3) {
            inPopover.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.38)).tap()
        }
        sleep(2)
        shot("11c-cache-cleared")
        tab("Receipts")
        let row = waitForRow("Edeka")
        row.tap()
        XCTAssertTrue(app.buttons["Photo"].waitForExistence(timeout: 10))
        app.buttons["Photo"].tap()
        let note = app.staticTexts["This photo is on your laptop."]
        let found = note.waitForExistence(timeout: 20)
        shot("12-photo-on-laptop")
        XCTAssertTrue(found, "the 'on your laptop' state")
    }

    // MARK: Banners (server started with the archive-overdue and disk-warning thresholds forced on)

    func testBannersFromTheStatusEndpoint() throws {
        app.launch()
        let banner = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'wait on the server'")).firstMatch
        let end = Date().addingTimeInterval(40)
        while !banner.exists, Date() < end { pullToRefresh(); _ = banner.waitForExistence(timeout: 4) }
        XCTAssertTrue(banner.exists, "archive_overdue banner")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'low on disk space'")).firstMatch.exists, "disk_warning banner")
        shot("30-banners")
        receiptRow(containing: "Edeka").tap()
        _ = app.buttons["Looks good"].waitForExistence(timeout: 10)
        shot("31-banners-detail")
    }

    // MARK: Screens, for the light/dark layout check

    func testScreenTour() throws {
        app.launch()
        _ = waitForRow("Edeka")
        shot("20-list")
        receiptRow(containing: "Edeka").tap()
        _ = app.buttons["Looks good"].waitForExistence(timeout: 10)
        shot("21-detail")
        app.swipeUp()
        shot("22-detail-scrolled")
        app.buttons["Photo"].tap()
        sleep(1)
        shot("23-photo")
        app.navigationBars.buttons.firstMatch.tap()
        tab("Overview")
        app.buttons["All time"].tap()
        sleep(3)
        shot("24-overview")
        app.swipeUp()
        shot("25-overview-scrolled")
        tab("Settings")
        shot("26-settings")
        app.swipeUp()
        shot("27-settings-scrolled")
    }
}
