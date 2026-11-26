import XCTest

final class ReaderVolumePagingUITests: XCTestCase {
    @MainActor func testVolumePagingChangesInsideTheSameReader() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["EH_RUN_VOLUME_PAGING"] == "1")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EH_OFFLINE_UI_FIXTURE"] = "1"
        app.launchEnvironment["EH_FIXTURE_LOCAL_READER"] = "1"
        app.launchEnvironment["EH_FIXTURE_VOLUME_PAGING"] = "1"
        app.launch()

        let row = app.staticTexts["Synthetic Gallery"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
        let read = app.buttons["gallery-detail-read"].firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 8))
        read.tap()

        let down = app.buttons["Fixture volume down"]
        let up = app.buttons["Fixture volume up"]
        let first = app.staticTexts["Fixture page 1"]
        let second = app.staticTexts["Fixture page 2"]
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        down.tap()
        XCTAssertTrue(first.exists)

        setPaging(true, in: app)
        down.tap()
        XCTAssertTrue(second.waitForExistence(timeout: 6), "Enabling volume keys must take effect without reopening.")
        up.tap()
        XCTAssertTrue(first.waitForExistence(timeout: 6))

        setPaging(false, in: app)
        down.tap()
        XCTAssertTrue(first.exists)

        setPaging(true, in: app)
        down.tap()
        XCTAssertTrue(second.waitForExistence(timeout: 6))
        setPaging(false, in: app)
    }

    @MainActor func testVolumePagesThroughFinalTallImage() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["EH_RUN_VOLUME_PAGING"] == "1")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EH_OFFLINE_UI_FIXTURE"] = "1"
        app.launchEnvironment["EH_FIXTURE_LOCAL_READER"] = "1"
        app.launchEnvironment["EH_FIXTURE_VOLUME_PAGING"] = "1"
        app.launchEnvironment["EH_FIXTURE_TALL_VOLUME"] = "1"
        app.launch()
        let row = app.staticTexts["Synthetic Gallery"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
        let read = app.buttons["gallery-detail-read"].firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 8))
        read.tap()
        let finalPage = app.staticTexts["Fixture page 3"]
        XCTAssertTrue(finalPage.waitForExistence(timeout: 8))
        setPaging(true, in: app)
        let scroll = app.staticTexts["Fixture scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        let start = try XCTUnwrap((scroll.value as? String).flatMap(Int.init))
        XCTAssertGreaterThan(start, 500, "The final image must already start below the previous two images.")
        let down = app.buttons["Fixture volume down"]
        down.tap()
        let later = try XCTUnwrap(waitForOffset(scroll) { $0 - start > 450 },
                                  "The last image must scroll down instead of ignoring the key.")
        XCTAssertLessThan(later - start, Int(app.frame.height) + 20)
        XCTAssertTrue(finalPage.exists)
        app.buttons["Fixture volume up"].tap()
        XCTAssertNotNil(waitForOffset(scroll) { abs($0 - start) < 30 })
        XCTAssertTrue(finalPage.exists)
        setPaging(false, in: app)
    }

    @MainActor func testPageAndArrowKeysUseTheSameVerticalStepAsVolume() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["EH_RUN_VOLUME_PAGING"] == "1")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EH_OFFLINE_UI_FIXTURE"] = "1"
        app.launchEnvironment["EH_FIXTURE_LOCAL_READER"] = "1"
        app.launchEnvironment["EH_FIXTURE_VOLUME_PAGING"] = "1"
        app.launchEnvironment["EH_FIXTURE_TALL_VOLUME"] = "1"
        app.launchEnvironment["EH_FIXTURE_KEY_COMMANDS"] = "1"
        app.launch()

        let row = app.staticTexts["Synthetic Gallery"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
        let read = app.buttons["gallery-detail-read"].firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 8))
        read.tap()
        let finalPage = app.staticTexts["Fixture page 3"]
        let scroll = app.staticTexts["Fixture scroll"]
        XCTAssertTrue(finalPage.waitForExistence(timeout: 8))
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))

        setPaging(true, in: app)
        let start = try XCTUnwrap(waitForOffset(scroll) { $0 > 500 })
        app.buttons["Fixture volume down"].tap()
        let volumeOffset = try XCTUnwrap(waitForOffset(scroll) { $0 - start > 450 })
        app.buttons["Fixture volume up"].tap()
        XCTAssertNotNil(waitForOffset(scroll) { abs($0 - start) < 30 })
        setPaging(false, in: app)

        for (down, up) in [("Fixture PgDn", "Fixture PgUp"), ("Fixture Down", "Fixture Up")] {
            app.buttons[down].tap()
            let offset = try XCTUnwrap(waitForOffset(scroll) { $0 - start > 450 },
                                      "The keyboard must advance inside the final image.")
            XCTAssertEqual(Double(offset), Double(volumeOffset), accuracy: 30)
            XCTAssertTrue(finalPage.exists)
            app.buttons[up].tap()
            XCTAssertNotNil(waitForOffset(scroll) { abs($0 - start) < 30 })
            XCTAssertTrue(finalPage.exists)
        }
    }

    @MainActor private func waitForOffset(_ element: XCUIElement, until matches: (Int) -> Bool) -> Int? {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if let offset = (element.value as? String).flatMap(Int.init), matches(offset) { return offset }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return nil
    }

    @MainActor private func setPaging(_ enabled: Bool, in app: XCUIApplication) {
        let settings = app.buttons["reader-settings"]
        if !settings.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.42)).tap()
        }
        XCTAssertTrue(settings.waitForExistence(timeout: 4))
        settings.tap()

        let toggle = app.switches["音量键翻页"].firstMatch
        let visible = (app.frame.height * 0.18)...(app.frame.height * 0.82)
        for _ in 0..<8 {
            if toggle.exists && visible.contains(toggle.frame.midY) { break }
            if toggle.exists && toggle.frame.midY < visible.lowerBound { app.swipeDown() }
            else { app.swipeUp() }
        }
        XCTAssertTrue(toggle.exists && visible.contains(toggle.frame.midY))
        XCTAssertEqual(toggle.value as? String, enabled ? "0" : "1")
        // In a Form this element can span the entire row; tap the trailing switch.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let state = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", enabled ? "1" : "0"),
                                              object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [state], timeout: 4), .completed)
        app.buttons["完成"].tap()
        XCTAssertTrue(app.navigationBars["阅读设置"].waitForNonExistence(timeout: 5))
    }
}
