import XCTest

final class ProfileBottomSettingsUITests: XCTestCase {
    @MainActor func testLastSettingsRowScrollsAboveFloatingTabsAndOpens() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EH_OFFLINE_UI_FIXTURE"] = "1"
        app.launchEnvironment["EH_FIXTURE_PUBLIC_UPDATES"] = "1"
        app.launch()
        let profile = app.buttons["我的"].firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 8))
        profile.tap()

        let bar = app.otherElements["workspace-floating-tabs"].firstMatch
        let about = app.buttons["关于与更新"].firstMatch
        let network = app.buttons["网络与容灾"].firstMatch
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        for _ in 0..<5 {
            if about.isHittable && bar.exists && about.frame.maxY < bar.frame.minY { break }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: 0.79))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: 0.33)))
        }
        let screen = XCTAttachment(screenshot: app.screenshot())
        screen.name = "Profile bottom and floating tabs"
        screen.lifetime = .keepAlways
        add(screen)
        XCTAssertTrue(bar.exists)
        XCTAssertTrue(network.isHittable)
        XCTAssertTrue(about.isHittable)
        XCTAssertLessThan(about.frame.maxY, bar.frame.minY,
                          "Last row overlaps the floating tabs: row \(about.frame), tabs \(bar.frame)")
        about.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["about-check-for-updates"].waitForExistence(timeout: 5))
        app.navigationBars.firstMatch.buttons.firstMatch.tap()
        XCTAssertTrue(about.waitForExistence(timeout: 5))
        XCTAssertTrue(about.isHittable)
        network.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["网络与容灾"].waitForExistence(timeout: 5))
    }

    @MainActor func testAppearanceSwitchChangesWhenItsLabelIsTappedAndStaysChangedOnReturn() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EH_OFFLINE_UI_FIXTURE"] = "1"
        app.launch()
        let profile = app.buttons["我的"].firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 8))
        profile.tap()
        let appearance = app.buttons["外观"].firstMatch
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.tap()
        let pages = app.switches["显示画廊页数"].firstMatch
        XCTAssertTrue(pages.waitForExistence(timeout: 5))
        let original = try XCTUnwrap(pages.value as? String)
        let label = pages.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5))
        label.tap()
        let changed = try XCTUnwrap(pages.value as? String)
        XCTAssertNotEqual(changed, original)
        app.navigationBars.firstMatch.buttons.firstMatch.tap()
        appearance.tap()
        XCTAssertEqual(pages.value as? String, changed)
        let indicator = pages.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5))
        indicator.tap()
        XCTAssertEqual(pages.value as? String, original)
    }
}
