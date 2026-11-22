#if EH_OFFLINE_UI_FIXTURE && targetEnvironment(simulator)
import CoreGraphics
import XCTest

final class FavoritesOfflineUITests: XCTestCase {
    @MainActor private func launch(cloud: String, importing: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EH_OFFLINE_UI_FIXTURE"] = "1"
        app.launchEnvironment["EH_FIXTURE_CLOUD"] = cloud
        if importing { app.launchEnvironment["EH_FIXTURE_IMPORT"] = "1" }
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

    @MainActor func testRealFilesImportRefreshesMountedTabsAndKeepsHomeResume() {
        let app = launch(cloud: "empty", importing: true)
        XCTAssertTrue(app.staticTexts["Apple resume fixture"].firstMatch.waitForExistence(timeout: 8))
        tab("收藏", in: app)
        XCTAssertTrue(header(app).waitForExistence(timeout: 8))
        tab("历史", in: app)
        XCTAssertTrue(app.staticTexts["Apple resume fixture"].firstMatch.waitForExistence(timeout: 8))
        tab("我的", in: app)

        let entry = app.staticTexts["收藏"].firstMatch
        for _ in 0..<3 where !entry.isHittable { app.swipeUp() }
        XCTAssertTrue(entry.isHittable)
        entry.tap()
        let importButton = app.buttons.containing(.staticText, identifier: "从安卓导入收藏与历史").firstMatch
        XCTAssertTrue(importButton.waitForExistence(timeout: 8))
        importButton.tap()

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 6))
        searchField.tap()
        searchField.typeText("offline-regression-fixture")
        let file = app.cells.matching(NSPredicate(format: "identifier CONTAINS %@ OR label CONTAINS %@",
                                                 "offline-regression-fixture", "offline-regression-fixture")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 8))
        file.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()

        XCTAssertTrue(app.staticTexts["导入预览"].waitForExistence(timeout: 8))
        app.buttons["导入"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 8))
        app.alerts.firstMatch.buttons["好"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        tab("收藏", in: app)
        XCTAssertTrue(app.staticTexts["Imported favorite fixture"].firstMatch.waitForExistence(timeout: 8))
        tab("历史", in: app)
        XCTAssertTrue(app.staticTexts["Imported reading 54"].firstMatch.waitForExistence(timeout: 8))
        tab("首页", in: app)
        XCTAssertTrue(app.staticTexts["Apple resume fixture"].firstMatch.waitForExistence(timeout: 8))
    }

    @MainActor func testSuccessfulEmptyCloudAndLocalFavoriteReopen() { checkFlow(cloud: "empty") }
    @MainActor func testCloudFailureStillShowsLocalAndStableHeader() { checkFlow(cloud: "failure") }
    @MainActor func testMixedLocalCloudAndNavigation() { checkFlow(cloud: "one") }
}
#endif
