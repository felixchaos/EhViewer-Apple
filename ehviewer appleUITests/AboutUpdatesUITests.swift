import XCTest

final class AboutUpdatesUITests: XCTestCase {
    @MainActor func testShowsInstalledHighlightsAndChecksNewerRelease() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EH_OFFLINE_UI_FIXTURE"] = "1"
        app.launchEnvironment["EH_FIXTURE_PUBLIC_UPDATES"] = "1"
        app.launch()
        let profile = app.buttons["我的"].firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 8))
        profile.tap()
        let about = app.buttons["关于与更新"].firstMatch
        for _ in 0..<4 {
            if about.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(about.isHittable)
        about.tap()

        let highlights = app.buttons["about-whats-new"]
        XCTAssertTrue(highlights.waitForExistence(timeout: 8))
        highlights.tap()
        XCTAssertTrue(app.staticTexts["Synthetic installed-release highlights"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["Synthetic next release"].exists)
        app.navigationBars.firstMatch.buttons.firstMatch.tap()

        let check = app.buttons["about-check-for-updates"]
        XCTAssertTrue(check.waitForExistence(timeout: 8))
        check.tap()
        XCTAssertTrue(app.staticTexts["可更新至 v99.0.0"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["查看发行说明"].exists)
    }
}
