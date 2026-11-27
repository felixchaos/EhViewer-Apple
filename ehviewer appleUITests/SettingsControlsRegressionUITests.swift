import XCTest

final class SettingsControlsRegressionUITests: XCTestCase {
    @MainActor func testAppearancePickerChangesAndPersistsAfterReopening() {
        let app = launch()
        open("外观", in: app)
        let theme = picker("theme", in: app)
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

    @MainActor func testReadingPickerPersistsAfterReopening() {
        let app = launch()
        open("阅读", in: app)
        let scale = picker("page-scaling", in: app)
        XCTAssertTrue(scale.waitForExistence(timeout: 5))
        let original = (scale.value as? String) ?? scale.label
        let option = original.contains("适应宽度") ? "适应高度" : "适应宽度"
        scale.tap()
        choose(option, in: app)
        XCTAssertTrue(reads(scale, as: option))
        back(in: app)
        open("阅读", in: app)
        XCTAssertTrue(reads(scale, as: option))
    }

    @MainActor func testPrivacySwitchChangesImmediatelyAndPersistsAfterReopening() {
        let app = launch()
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

    @MainActor func testReadingScaleAndCenterMatchActualReaderAfterOpening() {
        let app = launch(localReader: true)
        open("阅读", in: app)
        let scale = picker("page-scaling", in: app)
        scale.tap()
        choose("原始大小", in: app)
        XCTAssertTrue(reads(scale, as: "原始大小"))
        let position = picker("start-position", in: app)
        position.tap()
        choose("居中", in: app)
        XCTAssertTrue(reads(position, as: "居中"))
        back(in: app)
        let home = app.buttons["首页"].firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        home.tap()
        let row = app.staticTexts["Synthetic Gallery"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.press(forDuration: 0.8)
        let direct = app.buttons["直接阅读"].firstMatch
        XCTAssertTrue(direct.waitForExistence(timeout: 6))
        direct.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
        let settings = app.buttons["reader-settings"].firstMatch
        if !settings.waitForExistence(timeout: 4) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(settings.waitForExistence(timeout: 6))
        settings.tap()
        let readerScale = app.descendants(matching: .any)["reader-picker-page-scaling"].firstMatch
        let readerPosition = app.descendants(matching: .any)["reader-picker-start-position"].firstMatch
        XCTAssertTrue(readerScale.waitForExistence(timeout: 5))
        XCTAssertTrue(reads(readerScale, as: "原始大小"))
        XCTAssertTrue(reads(readerPosition, as: "居中"))
    }

    @MainActor func testGalleryLayoutPickerChangesActualBrowseGeometry() {
        let app = launch(localReader: true, layoutFixture: true)

        func setLayout(_ title: String) {
            open("列表与缩略图", in: app)
            let layout = picker("gallery-list-mode", in: app)
            XCTAssertTrue(layout.isHittable)
            layout.tap()
            choose(title, in: app)
            XCTAssertTrue(reads(layout, as: title))
            back(in: app)
            let home = app.buttons.matching(NSPredicate(format: "label == %@", "首页"))
                .allElementsBoundByIndex.last { $0.isHittable }
            XCTAssertNotNil(home)
            home?.tap()
        }

        func rowSpacing() -> CGFloat {
            let first = app.staticTexts["Synthetic Gallery"].firstMatch
            let second = app.staticTexts["Second layout fixture"].firstMatch
            XCTAssertTrue(first.waitForExistence(timeout: 8))
            XCTAssertTrue(second.waitForExistence(timeout: 8))
            XCTAssertTrue(first.isHittable)
            XCTAssertTrue(second.isHittable)
            XCTAssertEqual(first.frame.minX, second.frame.minX, accuracy: 8)
            return second.frame.midY - first.frame.midY
        }

        setLayout("列表")
        let normalSpacing = rowSpacing()
        app.buttons["我的"].firstMatch.tap()
        setLayout("紧凑")
        XCTAssertLessThan(rowSpacing(), normalSpacing - 15)

        app.buttons["我的"].firstMatch.tap()
        setLayout("网格")
        let firstCard = app.descendants(matching: .any)["gallery-grid-900010000001"].firstMatch
        let secondCard = app.descendants(matching: .any)["gallery-grid-900010000145"].firstMatch
        XCTAssertTrue(firstCard.waitForExistence(timeout: 8))
        XCTAssertTrue(secondCard.waitForExistence(timeout: 8))
        XCTAssertEqual(firstCard.frame.midY, secondCard.frame.midY, accuracy: 6)
        XCTAssertLessThan(firstCard.frame.maxX, secondCard.frame.minX)

        secondCard.tap()
        let detailRead = app.buttons["gallery-detail-read"].firstMatch
        XCTAssertTrue(detailRead.waitForExistence(timeout: 8))
        let secondTitle = app.staticTexts.matching(NSPredicate(format: "label == %@", "Second layout fixture"))
            .allElementsBoundByIndex.last { $0.isHittable }
        XCTAssertNotNil(secondTitle, "The second card must open its own gallery, not the first card.")
        if app.buttons["gallery-detail-back"].firstMatch.isHittable {
            app.buttons["gallery-detail-back"].firstMatch.tap()
        } else {
            back(in: app)
        }
        XCTAssertTrue(secondCard.waitForExistence(timeout: 6))

        // A card retains the item's existing long-press actions.
        firstCard.press(forDuration: 0.8)
        let read = app.buttons["gallery-row-read-directly"].firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 6))
        read.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
        let close = app.buttons["reader-close"].firstMatch
        if !close.waitForExistence(timeout: 4) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(close.waitForExistence(timeout: 6))
        close.tap()
        XCTAssertTrue(firstCard.waitForExistence(timeout: 6))
        XCTAssertEqual(firstCard.frame.midY, secondCard.frame.midY, accuracy: 6)

        // Keep the shared simulator's settings neutral for other tests.
        app.buttons["我的"].firstMatch.tap()
        setLayout("列表")
    }

    @MainActor func testThumbnailSizePickerPersistsAfterReopening() {
        let app = launch()
        open("列表与缩略图", in: app)
        let size = picker("thumbnail-size", in: app)
        XCTAssertTrue(size.exists)
        let original = (size.value as? String) ?? size.label
        let option = original.contains("大") ? "小" : "大"
        size.tap()
        choose(option, in: app)
        XCTAssertTrue(reads(size, as: option))
        back(in: app)
        open("列表与缩略图", in: app)
        XCTAssertTrue(reads(size, as: option))
    }

    @MainActor func testBrightnessSwitchRevealsWorkingSliderAndPersists() {
        let app = launch()
        open("阅读", in: app)
        let custom = app.switches["自定义亮度"].firstMatch
        for _ in 0..<6 where !custom.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(custom.isHittable)
        if (custom.value as? String) == "1" { custom.tap() }
        let slider = app.sliders["settings-reading-brightness"].firstMatch
        XCTAssertFalse(slider.exists)
        // Move the toggle clear of the navigation bars, then use the
        // settings-label area as well as the switch in the other tests.
        if custom.frame.midY > app.frame.height * 0.78 { app.swipeUp(velocity: .slow) }
        custom.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        XCTAssertEqual(custom.value as? String, "1")
        for _ in 0..<3 where !slider.isHittable { app.swipeUp(velocity: .slow) }
        if !slider.isHittable { print(app.debugDescription) }
        XCTAssertTrue(slider.isHittable, "Slider must become reachable without leaving Settings.")
        slider.adjust(toNormalizedSliderPosition: 0.81)
        let saved = slider.value as? String
        XCTAssertNotNil(saved)
        back(in: app)
        open("阅读", in: app)
        for _ in 0..<6 where !slider.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(slider.isHittable)
        XCTAssertEqual(slider.value as? String, saved)
        custom.tap()
        XCTAssertTrue(slider.waitForNonExistence(timeout: 5))
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

    @MainActor private func launch(localReader: Bool = false, layoutFixture: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EH_OFFLINE_UI_FIXTURE"] = "1"
        if localReader { app.launchEnvironment["EH_FIXTURE_LOCAL_READER"] = "1" }
        if layoutFixture { app.launchEnvironment["EH_FIXTURE_LIST_PRESENTATION"] = "1" }
        app.launch()
        let profile = app.buttons["我的"].firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 8))
        profile.tap()
        return app
    }

    @MainActor private func picker(_ key: String, in app: XCUIApplication) -> XCUIElement {
        let element = app.descendants(matching: .any).matching(identifier: "settings-picker-"+key).firstMatch
        if !element.waitForExistence(timeout: 4) { print(app.debugDescription) }
        return element
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
            if !label.waitForExistence(timeout: 4) { print(app.debugDescription) }
            XCTAssertTrue(label.exists, title + " not available")
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
