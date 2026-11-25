import XCTest

final class StandaloneGalleryOptionsUITests: XCTestCase {
    @MainActor func testPushedListOnlyStagesOptionsOnApply() {
        let app = openPushedList()
        let original = app.staticTexts["Synthetic Gallery"].firstMatch
        let four = app.staticTexts["Synthetic rating 4"].firstMatch
        let five = app.staticTexts["Synthetic rating 5"].firstMatch
        let sheet = app.navigationBars["搜索选项"]

        openOptions(in: app)
        app.switches["Enable advance options"].firstMatch.tap()
        let minimumRating = app.buttons["Minimum Rating:"].firstMatch
        reveal(minimumRating, in: app)
        minimumRating.tap()
        chooseRating("2 stars", next: "4 stars", in: app)
        sheet.buttons["应用"].tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        leaveSearchFocus(in: app)
        XCTAssertTrue(original.isHittable, "Apply on a standalone list must not submit a request.")
        XCTAssertFalse(four.exists)
        submit(in: app)
        XCTAssertTrue(four.waitForExistence(timeout: 8))

        openOptions(in: app)
        chooseRating("4 stars", next: "5 stars", in: app)
        sheet.buttons["取消"].tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        submit(in: app)
        XCTAssertTrue(four.waitForExistence(timeout: 8))
        XCTAssertFalse(five.exists)

        openOptions(in: app)
        chooseRating("4 stars", next: "5 stars", in: app)
        let grabberArea = sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.10))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.92))
        grabberArea.press(forDuration: 0.05, thenDragTo: bottom)
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        submit(in: app)
        XCTAssertTrue(four.waitForExistence(timeout: 8))
        XCTAssertFalse(five.exists, "Swipe dismissal must not retain the draft.")
        openOptions(in: app)
        reveal(app.buttons["4 stars"].firstMatch, in: app)
        XCTAssertFalse(app.buttons["5 stars"].firstMatch.exists)
        sheet.buttons["取消"].tap()
    }

    @MainActor func testPushedListUsesSharedDownloadAndFavoritePickers() {
        let app = openPushedList()
        let row = app.staticTexts["Synthetic Gallery"].firstMatch
        let downloadPicker = app.navigationBars["下载到"]
        let favoritePicker = app.navigationBars["选择收藏夹"]

        row.press(forDuration: 0.8)
        app.buttons["gallery-row-download"].firstMatch.tap()
        XCTAssertTrue(downloadPicker.waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["Fixture download label"].firstMatch.exists)
        downloadPicker.buttons["取消"].tap()
        XCTAssertTrue(downloadPicker.waitForNonExistence(timeout: 5))

        row.press(forDuration: 0.8)
        app.buttons["gallery-row-favorite"].firstMatch.tap()
        XCTAssertTrue(favoritePicker.waitForExistence(timeout: 6))
        favoritePicker.buttons["取消"].tap()
        XCTAssertTrue(favoritePicker.waitForNonExistence(timeout: 5))

        row.press(forDuration: 0.8)
        app.buttons["gallery-row-favorite"].firstMatch.tap()
        XCTAssertTrue(favoritePicker.waitForExistence(timeout: 6), "Cancel must not add the gallery or change the default.")
        app.buttons["本地收藏"].firstMatch.tap()
        XCTAssertTrue(favoritePicker.waitForNonExistence(timeout: 5))
        row.press(forDuration: 0.8)
        let removeFavorite = app.buttons["gallery-row-favorite"].firstMatch
        XCTAssertTrue(removeFavorite.waitForExistence(timeout: 5))
        XCTAssertEqual(removeFavorite.label, "取消收藏")
    }

    @MainActor private func openPushedList() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EH_OFFLINE_UI_FIXTURE"] = "1"
        app.launchEnvironment["EH_FIXTURE_ADVANCED_SEARCH"] = "1"
        app.launchEnvironment["EH_FIXTURE_STANDALONE_LIST"] = "1"
        app.launch()
        let entry = app.buttons["Fixture standalone list"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 8))
        entry.tap()
        XCTAssertTrue(app.staticTexts["Synthetic Gallery"].firstMatch.waitForExistence(timeout: 8))
        return app
    }

    @MainActor private func openOptions(in app: XCUIApplication) {
        let options = app.buttons["gallery-advanced-options"].firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        XCTAssertTrue(options.isHittable)
        options.tap()
        XCTAssertTrue(app.navigationBars["搜索选项"].waitForExistence(timeout: 6))
    }

    @MainActor private func chooseRating(_ current: String, next: String, in app: XCUIApplication) {
        let rating = app.buttons[current].firstMatch
        reveal(rating, in: app)
        rating.tap()
        app.buttons[next].firstMatch.tap()
    }

    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        if !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.waitForExistence(timeout: 5))
    }

    @MainActor private func searchField(in app: XCUIApplication) -> XCUIElement {
        let fields = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "搜索标签或标题"))
        let visible = fields.allElementsBoundByIndex.first(where: \.isHittable)
        XCTAssertNotNil(visible)
        return visible ?? fields.firstMatch
    }

    @MainActor private func leaveSearchFocus(in app: XCUIApplication) {
        let cancel = app.buttons["取消"].firstMatch
        if cancel.isHittable { cancel.tap() }
    }

    @MainActor private func submit(in app: XCUIApplication) {
        let field = searchField(in: app)
        field.tap()
        let focused = app.textFields.matching(NSPredicate(format: "hasKeyboardFocus == YES")).firstMatch
        if !focused.waitForExistence(timeout: 2) {
            field.tap()
        }
        XCTAssertTrue(focused.waitForExistence(timeout: 4))
        focused.typeText("\n")
    }
}
