import XCTest

final class OfflineImageArchiveUITests: XCTestCase {
    @MainActor func testNativeCBZPickerOpensLocalReaderAndHistoryReturnsToProgress() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["EH_RUN_NATIVE_FILE_SMOKE"] == "1",
                          "Run the real Files picker as a separate native smoke test.")
        continueAfterFailure = false
        let id = UUID().uuidString
        let name = "image-fixture-" + id
        let app = XCUIApplication()
        app.launchEnvironment["EH_OFFLINE_UI_FIXTURE"] = "1"
        app.launchEnvironment["EH_FIXTURE_IMAGE_ARCHIVE"] = id
        app.launch()
        XCTAssertTrue(app.staticTexts["Synthetic Gallery"].firstMatch.waitForExistence(timeout: 8))

        func selectTab(_ title: String) throws {
            let candidates = app.buttons.matching(NSPredicate(format: "label == %@", title))
            try XCTUnwrap(candidates.allElementsBoundByIndex.first(where: \.isHittable)).tap()
        }
        try selectTab("下载")
        let actions = app.buttons["downloads-actions"].firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 6))
        actions.tap()
        let archive = app.buttons["导入 ZIP / CBZ"].firstMatch
        XCTAssertTrue(archive.waitForExistence(timeout: 5))
        archive.tap()
        openLocalAppFolder(app)
        let file = app.cells.matching(NSPredicate(format: "identifier CONTAINS[c] %@ OR label CONTAINS[c] %@",
                                                 name, name)).firstMatch
        tapVisibleFile(file, in: app)

        let gallery = app.staticTexts[name].firstMatch
        let status = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            gallery.exists || app.alerts.firstMatch.exists
        }, object: nil)
        if XCTWaiter.wait(for: [status], timeout: 8) != .completed || !gallery.exists {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Files selection or import outcome"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            let image = XCTAttachment(screenshot: app.screenshot())
            image.name = "Synthetic Files selection outcome"
            image.lifetime = .keepAlways
            add(image)
            XCTFail("The native picker did not produce the synthetic gallery.")
            return
        }
        for _ in 0..<3 where gallery.frame.midY > app.frame.height * 0.82 { app.swipeUp() }
        gallery.tap()
        let pages = app.buttons["reader-pages"]
        XCTAssertTrue(pages.waitForExistence(timeout: 8))
        pages.tap()
        XCTAssertTrue(app.navigationBars["跳转到第 1 页"].waitForExistence(timeout: 5))
        app.buttons["2"].tap()
        revealToolsOnPageTwo(app)
        let close = app.buttons["reader-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()

        try selectTab("历史")
        let historyGallery = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@",
                                                               name, "本地图片")).firstMatch
        XCTAssertTrue(historyGallery.waitForExistence(timeout: 8))
        historyGallery.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.34)).tap()
        revealToolsOnPageTwo(app)
        XCTAssertTrue(pages.waitForExistence(timeout: 5))
        pages.tap()
        XCTAssertTrue(app.navigationBars["跳转到第 2 页"].waitForExistence(timeout: 5))
    }
    @MainActor func testNativeFolderPickerCancelsAndImportsTwoImages() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["EH_RUN_NATIVE_FILE_SMOKE"] == "1")
        continueAfterFailure = false
        let id = UUID().uuidString
        let name = "folder-fixture-" + id
        let app = XCUIApplication()
        app.launchEnvironment["EH_OFFLINE_UI_FIXTURE"] = "1"
        app.launchEnvironment["EH_FIXTURE_IMAGE_FOLDER"] = id
        app.launch()
        try XCTUnwrap(app.buttons.matching(NSPredicate(format: "label == %@", "下载"))
            .allElementsBoundByIndex.first(where: \.isHittable)).tap()
        let actions = app.buttons["downloads-actions"].firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 6))
        func showPicker() {
            actions.tap()
            let importFolder = app.buttons["导入图片文件夹"].firstMatch
            XCTAssertTrue(importFolder.waitForExistence(timeout: 5))
            importFolder.tap()
            XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 8))
        }
        showPicker()
        // Dismiss through the system sheet rather than the remote picker's
        // accessory accessibility element, which can overlap the overflow menu.
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.08))
        let down = app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.60))
        top.press(forDuration: 0.05, thenDragTo: down, withVelocity: .fast, thenHoldForDuration: 0)
        let sheet = app.descendants(matching: .any)["Browse View (Picker)"].firstMatch
        let pickerClosed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                                       object: sheet)
        XCTAssertEqual(XCTWaiter.wait(for: [pickerClosed], timeout: 6), .completed)
        XCTAssertFalse(app.staticTexts[name].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)

        showPicker()
        openLocalAppFolder(app)
        let folder = app.cells.matching(NSPredicate(format: "identifier CONTAINS[c] %@ OR label CONTAINS[c] %@",
                                                   name, name)).firstMatch
        tapVisibleFile(folder, in: app)
        let open = app.buttons["DOCPicker.actionButton"].firstMatch
        if open.waitForExistence(timeout: 3) { open.tap() }

        let gallery = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@",
                                                        name, "已完成")).firstMatch
        if !gallery.waitForExistence(timeout: 8) {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Native folder selection outcome"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            XCTFail("The Files picker did not produce the synthetic folder gallery.")
            return
        }
        gallery.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.35)).tap()
        let pages = app.buttons["reader-pages"]
        XCTAssertTrue(pages.waitForExistence(timeout: 8))
        pages.tap()
        XCTAssertTrue(app.navigationBars["跳转到第 1 页"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["2"].exists)
    }

    @MainActor private func openLocalAppFolder(_ app: XCUIApplication) {
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 8))
        // Recent items do not include a fresh file placed by the neutral fixture.
        // Navigate the actual Files location instead of searching the Recents index.
        let back = app.buttons["DOC.navBarButton.backInHistory"].firstMatch
        let local = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND (label CONTAINS[c] %@ OR label CONTAINS[c] %@)",
            "DOC.sidebar.item.", "iPhone", "iPad")).firstMatch
        let inAppFolder = app.navigationBars.buttons.matching(
            NSPredicate(format: "label BEGINSWITH[c] %@", "EhViewer,")).firstMatch
        for _ in 0..<4 {
            if inAppFolder.exists { return }
            if local.waitForExistence(timeout: 2) { break }
            if back.waitForExistence(timeout: 2), back.isEnabled { back.tap() }
        }
        XCTAssertTrue(local.waitForExistence(timeout: 6))
        local.tap()
        let appFolder = app.cells.matching(NSPredicate(format: "label CONTAINS[c] %@", "EhViewer")).firstMatch
        XCTAssertTrue(appFolder.waitForExistence(timeout: 8))
        appFolder.tap()
    }

    @MainActor private func tapVisibleFile(_ item: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(item.waitForExistence(timeout: 8))
        let frame = app.frame
        let visible = (frame.height * 0.24)...(frame.height * 0.79)
        for _ in 0..<8 {
            let y = item.frame.minY + item.frame.height * 0.27
            if visible.contains(y) { break }
            if y > visible.upperBound { app.swipeUp() } else { app.swipeDown() }
        }
        let y = item.frame.minY + item.frame.height * 0.27
        XCTAssertTrue(visible.contains(y), "The selected tile is not clear of the Files tab bar.")
        item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.27)).tap()
    }

    @MainActor private func revealToolsOnPageTwo(_ app: XCUIApplication) {
        if !app.buttons["reader-pages"].waitForExistence(timeout: 3) {
            XCTAssertTrue(app.staticTexts["2 / 2"].waitForExistence(timeout: 5))
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

}
