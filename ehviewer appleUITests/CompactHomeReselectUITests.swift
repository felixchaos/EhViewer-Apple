import XCTest

final class CompactHomeReselectUITests: XCTestCase {
    @MainActor func testRetappingHomeScrollsTheCurrentSearchWithoutReloading() throws {
        let app = XCUIApplication()
        app.launchEnvironment["EH_OFFLINE_UI_FIXTURE"] = "1"
        app.launchEnvironment["EH_FIXTURE_HOME_RESELECT"] = "1"
        app.launch()
        XCTAssertTrue(app.staticTexts["Synthetic Gallery"].firstMatch.waitForExistence(timeout: 8))
        if app.descendants(matching: .any)["adaptive-tab-sidebar"].exists {
            throw XCTSkip("Reselect belongs to the compact floating tab bar.")
        }

        let search = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "搜索标签或标题")).firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("offlineretap\n")

        let first = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Reselect result 1, request ")).firstMatch
        waitUntil(first, isHittable: true)
        let startingTitle = first.label

        app.swipeUp()
        app.swipeUp()
        waitUntil(first, isHittable: false)
        // The floating bar hides scrolling down. Reveal it with a small reverse scroll
        // while remaining below the first row.
        let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.48))
        let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.56))
        upper.press(forDuration: 0.05, thenDragTo: lower, withVelocity: .slow, thenHoldForDuration: 0)
        waitUntil(first, isHittable: false)

        // The Home container still owns the bottom tab while showing its search source.
        let homeTab = app.buttons.matching(NSPredicate(format: "label == %@ AND selected == YES", "首页")).firstMatch
        waitUntil(homeTab, isHittable: true)
        homeTab.tap()

        waitUntil(first, isHittable: true)
        XCTAssertEqual(first.label, startingTitle, "The search results should not be refetched.")
        XCTAssertEqual(search.value as? String, "offlineretap")
    }

    @MainActor private func waitUntil(_ element: XCUIElement, isHittable: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let condition = NSPredicate(format: "hittable == %@", NSNumber(value: isHittable))
        let wait = XCTNSPredicateExpectation(predicate: condition, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [wait], timeout: 6), .completed,
                       "Expected hittable=\(isHittable): \(element)", file: file, line: line)
    }
}
