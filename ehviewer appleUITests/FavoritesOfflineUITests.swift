#if EH_OFFLINE_UI_FIXTURE && targetEnvironment(simulator)
import XCTest

final class FavoritesOfflineUITests: XCTestCase {
    @MainActor private func launch(cloud: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EH_OFFLINE_UI_FIXTURE"] = "1"
        app.launchEnvironment["EH_FIXTURE_CLOUD"] = cloud
        app.launch()
        return app
    }

    @MainActor private func tab(_ name: String, in app: XCUIApplication) {
        // Both the floating tab bar and the expanded sidebar are actual production controls.
        let button = app.buttons[name].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 8), name)
        button.tap()
    }

    @MainActor private func header(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "favorites-page-header").firstMatch
    }

    @MainActor private func openSynthetic(_ app: XCUIApplication) {
        let item = app.staticTexts["Synthetic Gallery"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 8))
        item.tap()
    }

    @MainActor private func back(_ app: XCUIApplication) {
        let custom = app.buttons["gallery-detail-back"]
        if custom.exists { custom.tap() }
        else {
            let native = app.navigationBars.buttons.firstMatch
            XCTAssertTrue(native.exists)
            native.tap()
        }
    }

    @MainActor private func expectSelection(_ selected: Bool, heart: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == %@", NSNumber(value: selected)), object: heart
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 4), .completed)
    }

    @MainActor private func checkFlow(cloud: String) {
        let app = launch(cloud: cloud)
        tab("收藏", in: app)
        let header = header(app)
        XCTAssertTrue(header.waitForExistence(timeout: 8))
        let emptyY = header.frame.minY
        tab("首页", in: app)
        openSynthetic(app)
        let heart = app.buttons["gallery-detail-favorite"]
        XCTAssertTrue(heart.waitForExistence(timeout: 8))
        expectSelection(false, heart: heart)
        heart.tap()
        expectSelection(true, heart: heart)
        back(app)
        tab("收藏", in: app)
        XCTAssertTrue(app.staticTexts["Synthetic Gallery"].firstMatch.waitForExistence(timeout: 8))
        XCTAssertEqual(header.frame.minY, emptyY, accuracy: 2)
        if cloud == "one" {
            XCTAssertTrue(app.staticTexts["Synthetic Cloud Gallery"].firstMatch.exists)
        }
        openSynthetic(app)
        XCTAssertTrue(heart.waitForExistence(timeout: 8))
        expectSelection(true, heart: heart)
        heart.tap()
        expectSelection(false, heart: heart)
        back(app)
        XCTAssertEqual(header.frame.minY, emptyY, accuracy: 2)
        tab("历史", in: app)
        XCTAssertTrue(app.staticTexts["阅读历史"].waitForExistence(timeout: 6))
        tab("下载", in: app)
        XCTAssertTrue(app.staticTexts["下载"].firstMatch.waitForExistence(timeout: 6))
        tab("收藏", in: app)
        XCTAssertEqual(header.frame.minY, emptyY, accuracy: 2)
    }

    @MainActor func testSuccessfulEmptyCloudAndLocalFavoriteReopen() { checkFlow(cloud: "empty") }
    @MainActor func testCloudFailureStillShowsLocalAndStableHeader() { checkFlow(cloud: "failure") }
    @MainActor func testMixedLocalCloudAndNavigation() { checkFlow(cloud: "one") }
}
#endif
