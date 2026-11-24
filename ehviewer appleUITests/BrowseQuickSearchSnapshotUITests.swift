import XCTest

final class BrowseQuickSearchSnapshotUITests: XCTestCase {
    @MainActor func testSaveAppliedSubscriptionSearchThenReplayFromHomeAfterRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EH_OFFLINE_UI_FIXTURE"] = "1"
        app.launchEnvironment["EH_FIXTURE_SEARCH_SCOPE"] = "1"
        app.launch()
        XCTAssertTrue(app.staticTexts["Synthetic Gallery"].firstMatch.waitForExistence(timeout: 8))
        app.buttons["订阅"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Synthetic subscription origin"].waitForExistence(timeout: 8))

        let visibleField = app.textFields.allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(visibleField)
        visibleField?.tap()
        let field = app.textFields.matching(NSPredicate(format: "hasKeyboardFocus == YES")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("offlineparity\n")
        XCTAssertTrue(app.staticTexts["Scoped fixture result"].waitForExistence(timeout: 8))

        openDrawer(in: app)
        let save = app.buttons["quick-search-save-current"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 6))
        XCTAssertTrue(save.isEnabled)
        save.tap()
        let firstSaved = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "offlineparity", "订阅")).firstMatch
        XCTAssertTrue(firstSaved.waitForExistence(timeout: 6))

        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Synthetic Gallery"].firstMatch.waitForExistence(timeout: 8))
        openDrawer(in: app)
        let reopened = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "offlineparity", "订阅")).firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 6))
        reopened.tap()
        XCTAssertTrue(app.staticTexts["Scoped fixture result"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["Global fixture result"].exists)
    }

    @MainActor private func openDrawer(in app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.984, dy: 0.58))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.58))
        start.press(forDuration: 0.06, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0.15)
        XCTAssertTrue(app.staticTexts["快速搜索"].firstMatch.waitForExistence(timeout: 6))
    }
}
