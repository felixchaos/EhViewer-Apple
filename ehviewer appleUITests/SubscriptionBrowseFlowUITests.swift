import XCTest

final class SubscriptionBrowseFlowUITests: XCTestCase {
    @MainActor func testWatchedCursorRatingClearAndSourceScrollAnchor() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EH_OFFLINE_UI_FIXTURE"] = "1"
        app.launchEnvironment["EH_FIXTURE_SUBSCRIPTION_FLOW"] = "1"
        app.launch()
        XCTAssertTrue(app.staticTexts["Synthetic Gallery"].firstMatch.waitForExistence(timeout: 8))

        func selectSubscriptions() throws {
            let candidates = app.buttons.matching(NSPredicate(format: "label == %@", "订阅"))
            let button = try XCTUnwrap(candidates.allElementsBoundByIndex.first(where: \.isHittable))
            button.tap()
        }
        func focusWatchedField(applied: String? = nil) throws -> XCUIElement {
            let condition = applied.map { NSPredicate(format: "value == %@", $0) }
                ?? NSPredicate(format: "placeholderValue == %@", "搜索订阅")
            let candidates = app.textFields.matching(condition)
            let visible = try XCTUnwrap(candidates.allElementsBoundByIndex.first(where: \.isHittable))
            visible.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
            let focused = app.textFields.matching(NSPredicate(format: "hasKeyboardFocus == YES")).firstMatch
            XCTAssertTrue(focused.waitForExistence(timeout: 5))
            return focused
        }

        try selectSubscriptions()
        let firstOrigin = app.staticTexts["Watched origin row 1"]
        XCTAssertTrue(firstOrigin.waitForExistence(timeout: 8))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.57, dy: 0.73))
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.57, dy: 0.36))
        bottom.press(forDuration: 0.08, thenDragTo: top, withVelocity: .slow, thenHoldForDuration: 0)
        let visible = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Watched origin row "))
        let anchor = try XCTUnwrap(visible.allElementsBoundByIndex.first {
            $0.isHittable && $0.frame.midY > app.frame.height * 0.38 && $0.frame.midY < app.frame.height * 0.66
                && $0.label != "Watched origin row 1"
        })
        let anchorLabel = anchor.label
        let anchorY = anchor.frame.midY

        try focusWatchedField().typeText("fixtureflow\n")
        let first = app.staticTexts["Watched flow first result"]
        let cursor = app.staticTexts["Watched flow cursor result"]
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        XCTAssertTrue(cursor.waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["Unexpected global flow result"].exists)

        _ = try focusWatchedField(applied: "fixtureflow")
        let advanced = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "高级搜索")).firstMatch
        XCTAssertTrue(advanced.waitForExistence(timeout: 5))
        if !advanced.isHittable { app.swipeUp() }
        advanced.tap()
        app.switches["Enable advance options"].firstMatch.tap()
        let rating = app.buttons["Minimum Rating:"].firstMatch
        if !rating.isHittable { app.swipeUp() }
        XCTAssertTrue(rating.waitForExistence(timeout: 5))
        rating.tap()
        let stars = app.buttons["2 stars"].firstMatch
        if !stars.isHittable { app.swipeUp() }
        stars.tap()
        app.buttons["4 stars"].firstMatch.tap()
        app.buttons["应用"].firstMatch.tap()
        let relax = app.buttons["清除筛选条件"].firstMatch
        XCTAssertTrue(relax.waitForExistence(timeout: 8))
        relax.tap()
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        XCTAssertTrue(cursor.waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["Unexpected global flow result"].exists)

        try selectSubscriptions()
        let restored = app.staticTexts[anchorLabel].firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 8))
        XCTAssertTrue(restored.isHittable)
        XCTAssertEqual(restored.frame.midY, anchorY, accuracy: 2)
    }
}
