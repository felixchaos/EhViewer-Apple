import XCTest

final class ReaderNativeFileExportUITests: XCTestCase {
    @MainActor func testJPEGPageFilePickerCancelsThenSavesOriginal() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["EH_RUN_NATIVE_FILE_SMOKE"] == "1",
                          "Run native Files export explicitly with synthetic offline data.")
        continueAfterFailure = false
        let id = try XCTUnwrap(ProcessInfo.processInfo.environment["EH_FIXTURE_EXPORT_DESTINATION"])
        XCTAssertNotNil(UUID(uuidString: id))
        let app = XCUIApplication()
        app.launchEnvironment["EH_OFFLINE_UI_FIXTURE"] = "1"
        app.launchEnvironment["EH_FIXTURE_LOCAL_READER"] = "1"
        app.launchEnvironment["EH_FIXTURE_ENCODED_EXPORT"] = "1"
        app.launchEnvironment["EH_FIXTURE_EXPORT_DESTINATION"] = id
        app.launch()
        let row = app.staticTexts["Synthetic Gallery"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
        let read = app.buttons["阅读"].firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 8))
        read.tap()
        let close = app.buttons["reader-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 8))

        func showPicker() {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5)).press(forDuration: 0.85)
            let save = app.buttons["存储到文件"].firstMatch
            XCTAssertTrue(save.waitForExistence(timeout: 6))
            save.tap()
            let filename = app.descendants(matching: .any).matching(NSPredicate(
                format: "value CONTAINS %@ OR label CONTAINS %@", "900010000031-1", "900010000031-1"
            )).firstMatch
            XCTAssertTrue(filename.waitForExistence(timeout: 8))
        }

        showPicker()
        let picker = app.descendants(matching: .any)["Browse View (Picker)"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.08))
        let down = app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.60))
        top.press(forDuration: 0.05, thenDragTo: down, withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(picker.waitForNonExistence(timeout: 6))
        XCTAssertTrue(close.isHittable)
        showPicker()

        let back = app.buttons["BackButton"].firstMatch
        let historyBack = app.buttons["DOC.navBarButton.backInHistory"].firstMatch
        let local = app.cells.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (label CONTAINS[c] %@ OR label CONTAINS[c] %@)",
            "DOC.sidebar.item.", "iPhone", "iPad")).firstMatch
        let inAppFolder = app.navigationBars.buttons.matching(
            NSPredicate(format: "label BEGINSWITH[c] %@", "EhViewer,")).firstMatch
        for _ in 0..<5 {
            if inAppFolder.exists || local.waitForExistence(timeout: 1) { break }
            if back.isHittable, back.isEnabled { back.tap() }
            else if historyBack.isHittable, historyBack.isEnabled { historyBack.tap() }
        }
        if !inAppFolder.exists {
            XCTAssertTrue(local.waitForExistence(timeout: 5))
            local.tap()
            let appFolder = app.cells.matching(NSPredicate(format: "label CONTAINS[c] %@", "EhViewer")).firstMatch
            XCTAssertTrue(appFolder.waitForExistence(timeout: 6))
            appFolder.tap()
        }
        let destination = app.cells.matching(NSPredicate(
            format: "label CONTAINS[c] %@", "export-fixture-" + id)).firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: 8))
        let visible = (app.frame.height * 0.24)...(app.frame.height * 0.78)
        for _ in 0..<8 {
            let y = destination.frame.minY + destination.frame.height * 0.27
            if visible.contains(y) { break }
            if y > visible.upperBound { app.swipeUp() } else { app.swipeDown() }
        }
        XCTAssertTrue(visible.contains(destination.frame.minY + destination.frame.height * 0.27))
        destination.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.27)).tap()
        let selected = app.navigationBars.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "export-fixture-" + id)).firstMatch
        XCTAssertTrue(selected.waitForExistence(timeout: 6), "Files must enter the isolated destination before saving.")
        let save = app.buttons["DOCPicker.actionButton"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 8))
        save.tap()

        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"),
                                                   object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 8), .completed)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        close.tap()
        XCTAssertTrue(read.waitForExistence(timeout: 5))
    }
}
