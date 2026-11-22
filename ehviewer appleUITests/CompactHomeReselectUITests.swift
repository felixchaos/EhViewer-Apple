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
        // Even a small forward scroll away from the top must leave navigation available.
        let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.48))
        let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.56))
        lower.press(forDuration: 0.05, thenDragTo: upper, withVelocity: .slow, thenHoldForDuration: 0)
        waitUntil(first, isHittable: false)

        // No reversing the scroll to reveal the bar. Browse still owns the selected Home tab.
        waitUntil(app.buttons["收藏"].firstMatch, isHittable: true)
        let homeTab = app.buttons.matching(NSPredicate(format: "label == %@ AND selected == YES", "首页")).firstMatch
        waitUntil(homeTab, isHittable: true)
        homeTab.tap()

        waitUntil(first, isHittable: true)
        XCTAssertEqual(first.label, startingTitle, "The search results should not be refetched.")
        // The previous Browse origin is retained with an empty native text
        // field; assert the visible results editor rather than the first AX match.
        let applied = app.textFields.matching(NSPredicate(format: "value == %@", "offlineretap"))
        XCTAssertTrue(applied.allElementsBoundByIndex.contains(where: \.isHittable))
    }

    @MainActor func testDetailAndReaderStillKeepApplicationTabsOutOfTheWay() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EH_OFFLINE_UI_FIXTURE"] = "1"
        app.launchEnvironment["EH_FIXTURE_LOCAL_READER"] = "1"
        app.launch()
        let gallery = app.staticTexts["Synthetic Gallery"].firstMatch
        XCTAssertTrue(gallery.waitForExistence(timeout: 8))
        if app.descendants(matching: .any)["adaptive-tab-sidebar"].exists {
            throw XCTSkip("This verifies the compact tab bar, not sidebar visibility.")
        }

        // Use a unique top-level button, not 下载/收藏 controls also found inside detail.
        let profileTab = app.buttons["我的"].firstMatch
        waitUntil(profileTab, isHittable: true)
        gallery.tap()
        let read = app.buttons["阅读"].firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 8))
        waitUntil(profileTab, isHittable: false)
        read.tap()

        let close = app.buttons["reader-close"]
        let pages = app.buttons["reader-pages"]
        XCTAssertTrue(close.waitForExistence(timeout: 8))
        waitUntil(pages, isHittable: true)
        waitUntil(profileTab, isHittable: false)
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.tap()
        waitUntil(pages, isHittable: false)
        waitUntil(profileTab, isHittable: false)
        center.tap()
        waitUntil(close, isHittable: true)
        close.tap()
        XCTAssertTrue(read.waitForExistence(timeout: 8))
        waitUntil(profileTab, isHittable: false)

        let labeledBack = app.buttons["返回"].firstMatch
        let back = labeledBack.exists ? labeledBack : app.navigationBars.buttons.firstMatch
        waitUntil(back, isHittable: true)
        back.tap()
        waitUntil(profileTab, isHittable: true)
    }

    @MainActor private func waitUntil(_ element: XCUIElement, isHittable: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let condition = NSPredicate(format: "hittable == %@", NSNumber(value: isHittable))
        let wait = XCTNSPredicateExpectation(predicate: condition, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [wait], timeout: 6), .completed,
                       "Expected hittable=\(isHittable): \(element)", file: file, line: line)
    }
}
