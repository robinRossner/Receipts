import XCTest

/// Real taps through "Items without a category" against a local throwaway backend seeded by `Tests/ios-e2e/seed_flagged.py`.
/// Configuration comes from the runner environment like `DesignFlowTests` (`TEST_RUNNER_E2E_URL`, `TEST_RUNNER_E2E_TOKEN`,
/// `TEST_RUNNER_E2E_SHOTS`, `TEST_RUNNER_E2E_SUFFIX`); without it every test is skipped. The tests run in order, each builds
/// on the last; `seed_flagged.py PORT TOKEN verify` afterwards checks what reached the server.
final class FlagFlowTests: XCTestCase {
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

    private func scrollTo(_ element: XCUIElement, swipes: Int = 8) {
        var left = swipes
        while !(element.exists && element.isHittable), left > 0 {
            app.swipeUp(velocity: .slow)
            left -= 1
        }
    }

    private func type(_ value: String, into field: XCUIElement) {
        for _ in 0..<4 where !field.hasKeyboardFocus {
            field.tap()
            sleep(1)
        }
        field.typeText(value)
    }

    /// Puts the cursor at the end (a tap on the right edge) and deletes what is there.
    private func replace(_ field: XCUIElement, with value: String) {
        for _ in 0..<4 where !field.hasKeyboardFocus {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
            sleep(1)
        }
        let existing = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        field.typeText(value)
    }

    private func dismissKeyboard() {
        let done = app.toolbars.buttons["Done"].exists ? app.toolbars.buttons["Done"] : app.buttons["Done"]
        if done.exists { done.tap() }
        sleep(1)
    }

    private func openFlagged(expecting count: Int) {
        tab("Overview")
        let row = app.buttons["flaggedItemsRow"]
        wait(row, "flagged row", timeout: 30)
        wait(button("Items without a category (\(count))"), "count \(count) on the row")
        row.tap()
    }

    /// The card with this suggestion, by its heading.
    private func cardButton(_ identifier: String, under heading: String) -> XCUIElement {
        // Cards keep their order on screen: the first button with this id at or below the heading.
        let top = text(heading)
        wait(top, heading)
        let all = app.buttons.matching(identifier: identifier).allElementsBoundByIndex
        let below = all.first { $0.frame.minY > top.frame.minY }
        return below ?? app.buttons[identifier].firstMatch
    }

    // MARK: Flows

    func test01_ConnectAndSeeTheCount() throws {
        app.launchArguments += ["-resetReceiptsSettings"]
        app.launch()
        wait(text("Connect to your server"), "setup prompt")
        app.buttons["openSettingsButton"].tap()
        let url = app.textFields["serverURLField"]
        wait(url, "settings")
        type(env["E2E_URL"]!, into: url)
        type(env["E2E_TOKEN"]!, into: app.secureTextFields["tokenField"])
        app.buttons["saveSettingsButton"].tap()
        sleep(1)
        tab("Receipts")
        wait(button("Fressnapf"), "seeded receipts arrive", timeout: 40)
        openFlagged(expecting: 5)
        wait(text("Dog Supplies"), "group with the biggest use comes first")
        wait(text("Pedigree Hundefutter"), "item name")
        wait(text("Dog food"), "translation")
        wait(text("2 purchases · €25.98"), "purchase count and spend of an item")
        wait(button("Fressnapf · "), "which receipts")
        shot("f01-flagged")
        scrollTo(text("No suggestion"))
        wait(text("No suggestion"), "the group without a suggestion, last")
        shot("f02-flagged-end")
    }

    func test02_ResolveFromAReceiptRow() throws {
        app.launch()
        openFlagged(expecting: 5)
        // The link goes to the receipt with the item open.
        scrollTo(text("Seltsames Ding"))
        let link = button("Decathlon · ")
        wait(link, "link to the receipt")
        scrollTo(link)
        link.tap()
        let mark = app.staticTexts["flagMark"].firstMatch
        wait(mark, "mark on the flagged row")
        wait(app.buttons["flagSortOutButton"], "resolve is reachable from the row")
        shot("f03-receipt-row")
        XCTAssertTrue(text("Suggested:").exists || text("No good category").exists)
        // Decathlon has two flagged items: the fishing rod (suggestion) and the odd thing (none). Sort out the odd thing.
        let oddRowMark = app.staticTexts.matching(NSPredicate(format: "identifier == 'flagMark' AND label == 'No good category'")).firstMatch
        scrollTo(oddRowMark)
        wait(oddRowMark, "the row without a suggestion")
        let sorts = app.buttons.matching(identifier: "flagSortOutButton").allElementsBoundByIndex
        let sort = sorts.first { abs($0.frame.midY - oddRowMark.frame.midY) < 40 } ?? sorts.last!
        sort.tap()
        wait(text("Item without a category"), "sheet for one item")
        wait(text("Seltsames Ding"), "sheet shows the item")
        shot("f04-sheet")
        let keep = app.buttons["flagKeepButton"]
        wait(keep, "keep button")
        scrollTo(keep)
        keep.tap()
        waitGone(app.buttons["flagKeepButton"], "sheet closes when resolved")
        waitGone(oddRowMark, "the mark is gone")
        shot("f05-receipt-row-after")
    }

    func test03_InvalidNameShowsAMessageThenEditedNameFiles() throws {
        app.launch()
        openFlagged(expecting: 4)
        wait(text("Fishing Gear"), "fishing group")
        let add = cardButton("flagAddButton", under: "Fishing Gear")
        scrollTo(add)
        cardButton("flagEditButton", under: "Fishing Gear").tap()
        let group = app.textFields["flagItemGroupField"].firstMatch
        wait(group, "editor opens")
        shot("f06-edit")
        replace(group, with: "Fish > Gear")
        dismissKeyboard()
        scrollTo(button("Fish > Gear"))
        button("Fish > Gear").tap()
        let message = app.staticTexts["flagResolveMessage"]
        wait(message, "FlagResolution.invalid is visible")
        XCTAssertTrue(message.label.contains("must not contain"), message.label)
        shot("f07-invalid")
        // Parent editable too: Sports > General... becomes Sports > Outdoors > Fishing Gear
        let sub = app.textFields["flagSubcategoryField"].firstMatch
        replace(sub, with: "Outdoors")
        replace(group, with: "Fishing Gear")
        dismissKeyboard()
        let fixed = button("Sports > Outdoors > Fishing Gear")
        wait(fixed, "button follows the edit")
        scrollTo(fixed)
        fixed.tap()
        wait(app.staticTexts.matching(identifier: "flagNotice").firstMatch, "filed notice")
        XCTAssertFalse(text("Fishing Gear").exists && app.buttons["flagEditButton"].exists && text("Suggested under Sports").exists, "group left")
        shot("f08-filed")
    }

    func test04_OneTapAddsTheSuggestion() throws {
        app.launch()
        openFlagged(expecting: 3)
        let add = button("Household > Pets > Dog Supplies")
        wait(add, "one-tap button with the suggested path")
        add.tap()
        wait(text("Filed 2 items under Household > Pets > Dog Supplies"), "filed notice")
        waitGone(text("Pedigree Hundefutter"), "the group left")
        shot("f09-one-tap")
    }

    func test05_ChooseExistingUsesACategoryThatArrivedThroughAPull() throws {
        app.launch()
        openFlagged(expecting: 1)
        wait(text("Modellierknete"), "last item")
        app.buttons["flagChooseButton"].tap()
        wait(text("Choose a category"), "chooser")
        // Taxonomy addition pushed by "another device" before the phone's first pull.
        let category = app.buttons.matching(identifier: "Category").firstMatch
        wait(category, "category menu")
        category.tap()
        wait(app.buttons["Arts | Crafts"], "the synced category is offered")
        shot("f10-chooser")
        app.buttons["Arts | Crafts"].tap()
        sleep(1)
        XCTAssertEqual(app.buttons.matching(identifier: "Subcategory").firstMatch.value as? String, "Knitting")
        app.buttons["flagChooserFile"].tap()
        wait(app.staticTexts["flagEmptyState"], "empty state when nothing is flagged")
        shot("f11-empty")
    }

    func test06_NewCategoriesInPickersAndOverview() throws {
        app.launch()
        tab("Overview")
        waitGone(app.buttons["flaggedItemsRow"], "the row is hidden with nothing to do", timeout: 20)
        // The tree and the chart know the new names, each with a total.
        wait(button("Household"), "tree row")
        wait(text("Arts | Crafts"), "chart legend or tree shows the added name")
        shot("f12-overview")
        let added = button("Sports")
        scrollTo(added)
        wait(added, "category added from the phone in the tree")
        added.tap()
        wait(button("Outdoors"), "new subcategory")
        button("Outdoors").tap()
        wait(button("Fishing Gear"), "new item group")
        button("Fishing Gear").tap()
        let edit = app.buttons["Edit"].firstMatch
        wait(edit, "drilldown")
        scrollTo(edit)
        shot("f13-overview-drilldown")
        edit.tap()
        // In the receipt, the item is filed there and the pickers show it.
        wait(app.textFields["qtyField"].firstMatch, "the item is open")
        let category = app.buttons.matching(identifier: "Category").firstMatch
        scrollTo(category)
        XCTAssertEqual(category.value as? String, "Sports")
        XCTAssertEqual(app.buttons.matching(identifier: "Item group").firstMatch.value as? String, "Fishing Gear")
        category.tap()
        wait(app.buttons["Arts | Crafts"], "every added category in the row's picker")
        XCTAssertTrue(app.buttons["Sports"].exists)
        shot("f14-row-picker")
    }

    /// The push reached the server (checked by `seed_flagged.py verify` afterwards): no local change may stay unsent.
    func test07_EverythingIsPushed() throws {
        app.launch()
        tab("Settings")
        let sync = app.buttons["syncNowButton"]
        wait(sync, "sync button", timeout: 20)
        sync.tap()
        sleep(4)
        XCTAssertFalse(text("Not sent yet").exists, "nothing left to send")
        XCTAssertFalse(text("Refused by the server").exists, "nothing refused")
    }
}

private extension XCUIElement {
    var hasKeyboardFocus: Bool { (value(forKey: "hasKeyboardFocus") as? Bool) ?? false }
}
