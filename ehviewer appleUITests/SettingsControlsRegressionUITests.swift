import XCTest

final class SettingsControlsRegressionUITests: XCTestCase {
    @MainActor func testAppearancePickerChangesAndPersistsAfterReopening() {
        let app = launch()
        open("外观", in: app)
        let theme = picker("主题", in: app)
        XCTAssertTrue(theme.waitForExistence(timeout: 5))
        let original = (theme.value as? String) ?? theme.label
        let option = original.contains("深色") ? "浅色" : "深色"
        theme.coordinate(withNormalizedOffset: CGVector(dx: 0.16, dy: 0.5)).tap()
        choose(option, in: app)
        XCTAssertTrue(reads(theme, as: option))
        back(in: app)
        open("外观", in: app)
        XCTAssertTrue(reads(theme, as: option))
    }

    @MainActor func testReadingPickerAndPrivacySwitchPersistAfterReopening() {
        let app = launch()
        open("阅读", in: app)
        let scale = picker("页面缩放", in: app)
        XCTAssertTrue(scale.waitForExistence(timeout: 5))
        let original = (scale.value as? String) ?? scale.label
        let option = original.contains("适合宽度") ? "适合高度" : "适合宽度"
        scale.tap()
        choose(option, in: app)
        XCTAssertTrue(reads(scale, as: option))
        back(in: app)
        open("阅读", in: app)
        XCTAssertTrue(reads(scale, as: option))
        back(in: app)
        open("隐私与锁定", in: app)
        let privacy = app.switches["切到后台时隐藏内容"].firstMatch
        XCTAssertTrue(privacy.waitForExistence(timeout: 5))
        let before = privacy.value as? String
        privacy.coordinate(withNormalizedOffset: CGVector(dx: 0.16, dy: 0.5)).tap()
        let after = privacy.value as? String
        XCTAssertNotEqual(before, after)
        back(in: app)
        open("隐私与锁定", in: app)
        XCTAssertEqual(privacy.value as? String, after)
        privacy.tap()
        XCTAssertEqual(privacy.value as? String, before)
    }

    @MainActor func testNetworkSegmentAndTextInputProduceUnappliedDraft() {
        let app = launch()
        open("网络与容灾", in: app)
        let mode = app.buttons["手动 HTTP"].firstMatch
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        mode.tap()
        let address = app.textFields["127.0.0.1"].firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap()
        address.typeText("127.0.0.2")
        XCTAssertTrue((address.value as? String)?.contains("127.0.0.2") == true)
        let apply = app.buttons["应用代理设置"].firstMatch
        XCTAssertTrue(apply.exists && apply.isEnabled)
        // This is only a local draft. Never apply a test proxy.
        back(in: app)
        open("网络与容灾", in: app)
        XCTAssertFalse(address.exists)
        XCTAssertTrue(app.buttons["跟随系统"].firstMatch.isSelected)
    }

    @MainActor private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EH_OFFLINE_UI_FIXTURE"] = "1"
        app.launch()
        let profile = app.buttons["我的"].firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 8))
        profile.tap()
        return app
    }

    @MainActor private func picker(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, title + ",")).firstMatch
    }

    @MainActor private func reads(_ picker: XCUIElement, as name: String) -> Bool {
        if (picker.value as? String)?.contains(name) == true || picker.label.contains(name) { return true }
        return picker.staticTexts[name].exists
    }

    @MainActor private func choose(_ title: String, in app: XCUIApplication) {
        let option = app.buttons.matching(NSPredicate(format: "label == %@", title)).allElementsBoundByIndex.last { $0.isHittable }
        if let option {
            option.tap()
        } else {
            let label = app.staticTexts[title].firstMatch
            XCTAssertTrue(label.waitForExistence(timeout: 4), title + " not available")
            label.tap()
        }
    }

    @MainActor private func open(_ title: String, in app: XCUIApplication) {
        let button = app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
        for _ in 0..<5 where !button.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(button.isHittable, title + " does not open")
        button.tap()
    }

    @MainActor private func back(in app: XCUIApplication) {
        let button = app.navigationBars.firstMatch.buttons.firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
    }
}
