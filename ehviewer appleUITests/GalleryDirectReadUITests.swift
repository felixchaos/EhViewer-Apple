import XCTest

final class GalleryDirectReadUITests: XCTestCase {
    @MainActor func testDirectReadRestoresSecondPageAndReturnsToTheSameRow() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EH_OFFLINE_UI_FIXTURE"] = "1"
        app.launchEnvironment["EH_FIXTURE_LOCAL_READER"] = "1"
        app.launchEnvironment["EH_FIXTURE_SAVED_READER_PAGE"] = "1"
        app.launch()
        let row = app.staticTexts["Synthetic Gallery"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        let originalY = row.frame.midY
        row.press(forDuration: 0.8)

        let read = app.buttons["直接阅读"].firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 6))
        let close = app.buttons["reader-close"]
        XCTAssertFalse(close.exists, "Long press alone must not open the reader.")
        read.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
        // Resuming an already-saved page can enter immersive mode. Verify the
        // page HUD first, then show the controls with the normal reader gesture.
        XCTAssertTrue(app.staticTexts["2 / 3"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["我的"].firstMatch.isHittable)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))

        let pages = app.buttons["reader-pages"]
        XCTAssertTrue(pages.waitForExistence(timeout: 8))
        pages.tap()
        XCTAssertTrue(app.navigationBars["跳转到第 2 页"].waitForExistence(timeout: 5))
        app.buttons["完成"].firstMatch.tap()
        XCTAssertTrue(close.isHittable)
        close.tap()

        let profile = app.buttons["我的"].firstMatch
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: profile)
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 8), .completed)
        XCTAssertFalse(close.exists)
        XCTAssertTrue(row.exists)
        XCTAssertEqual(row.frame.midY, originalY, accuracy: 2)
        // A retained accessibility node is not enough: the actual row must
        // respond to a normal tap and open detail, not start reading again.
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let detailRead = app.buttons["gallery-detail-read"]
        XCTAssertTrue(detailRead.waitForExistence(timeout: 8))
        XCTAssertTrue(detailRead.isHittable)
        XCTAssertFalse(close.exists, "A normal row tap must open the detail, not the reader.")
    }
    @MainActor func testFirstUncachedReadPersistsHistoryAndResumeAfterRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EH_OFFLINE_UI_FIXTURE"] = "1"
        app.launchEnvironment["EH_FIXTURE_DIRECT_COLD"] = "reset"
        app.launch()
        XCTAssertTrue(app.staticTexts["Previous visit fixture"].firstMatch.waitForExistence(timeout: 8))
        let row = app.staticTexts["First visit fixture"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.press(forDuration: 0.8)
        let read = app.buttons["直接阅读"].firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 6))
        read.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()

        let pages = app.buttons["reader-pages"]
        XCTAssertTrue(pages.waitForExistence(timeout: 8))
        pages.tap()
        XCTAssertTrue(app.navigationBars["跳转到第 1 页"].waitForExistence(timeout: 5))
        app.buttons["2"].tap()
        showReaderControls(app)
        pages.tap()
        XCTAssertTrue(app.navigationBars["跳转到第 2 页"].waitForExistence(timeout: 5))
        app.buttons["完成"].firstMatch.tap()
        app.buttons["reader-close"].tap()

        let history = app.buttons["历史"].firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: history)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
        history.tap()
        XCTAssertTrue(app.staticTexts["阅读历史"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.staticTexts["First visit fixture"].firstMatch.waitForExistence(timeout: 8))

        app.terminate()
        app.launchEnvironment["EH_FIXTURE_DIRECT_COLD"] = "keep"
        app.launch()
        let resume = app.buttons["home-continue-reading"]
        XCTAssertTrue(resume.waitForExistence(timeout: 8))
        XCTAssertTrue(resume.staticTexts["First visit fixture"].exists || resume.label.contains("First visit fixture"))
        resume.tap()
        showReaderControls(app)
        pages.tap()
        XCTAssertTrue(app.navigationBars["跳转到第 2 页"].waitForExistence(timeout: 5))
    }

    @MainActor func testHomeResumeReopensLatestProgressWithoutRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EH_OFFLINE_UI_FIXTURE"] = "1"
        app.launchEnvironment["EH_FIXTURE_DIRECT_COLD"] = "reset"
        app.launch()
        let resume = app.buttons["home-continue-reading"]
        XCTAssertTrue(resume.waitForExistence(timeout: 8))
        XCTAssertTrue(resume.label.contains("Previous visit fixture") || resume.staticTexts["Previous visit fixture"].exists)
        resume.tap()

        let pages = app.buttons["reader-pages"]
        XCTAssertTrue(pages.waitForExistence(timeout: 8))
        pages.tap()
        XCTAssertTrue(app.navigationBars["跳转到第 1 页"].waitForExistence(timeout: 5))
        app.buttons["2"].tap()
        showReaderControls(app)
        app.buttons["reader-close"].tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                                object: app.buttons["reader-close"])
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 8), .completed)
        XCTAssertTrue(resume.exists)
        resume.coordinate(withNormalizedOffset: CGVector(dx: 0.40, dy: 0.50)).tap()
        showReaderControls(app)
        pages.tap()
        XCTAssertTrue(app.navigationBars["跳转到第 2 页"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        app.buttons["reader-close"].tap()
        let updated = NSPredicate { _, _ in
            resume.label.contains("2 / 3 页") || resume.staticTexts["2 / 3 页 · 66%"].exists
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: updated, object: nil)], timeout: 5),
                       .completed)
    }

    @MainActor func testNewDirectReadUpdatesHomeWithoutDisplacingScrolledRow() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EH_OFFLINE_UI_FIXTURE"] = "1"
        app.launchEnvironment["EH_FIXTURE_DIRECT_COLD"] = "scrolled-reset"
        app.launch()
        let resume = app.buttons["home-continue-reading"]
        XCTAssertTrue(resume.waitForExistence(timeout: 8))
        XCTAssertTrue(resume.label.contains("Previous visit fixture") || resume.staticTexts["Previous visit fixture"].exists)
        let row = app.staticTexts["First visit fixture"].firstMatch
        let visibleArea = (app.frame.height * 0.24)...(app.frame.height * 0.84)
        for _ in 0..<5 {
            if row.exists, visibleArea.contains(row.frame.midY) { break }
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(row.exists)
        XCTAssertTrue(visibleArea.contains(row.frame.midY))
        let originalY = row.frame.midY
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.8)
        let read = app.buttons["直接阅读"].firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 6))
        read.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
        let close = app.buttons["reader-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 8))
        close.tap()
        let profile = app.buttons["我的"].firstMatch
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: profile)
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 8), .completed)
        XCTAssertEqual(row.frame.midY, originalY, accuracy: 2)

        for _ in 0..<6 {
            if resume.exists, resume.frame.midY > app.frame.height * 0.17 { break }
            app.swipeDown()
        }
        XCTAssertTrue(resume.exists)
        XCTAssertGreaterThan(resume.frame.midY, app.frame.height * 0.17)
        XCTAssertTrue(resume.label.contains("First visit fixture") || resume.staticTexts["First visit fixture"].exists)
    }

    @MainActor func testMissingMetadataAllowsRetryAndKeepsPreviousResumeOnFailure() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EH_OFFLINE_UI_FIXTURE"] = "1"
        app.launchEnvironment["EH_FIXTURE_DIRECT_COLD"] = "missing-reset"
        app.launch()
        openMissingCount(app)
        XCTAssertTrue(app.staticTexts["无法加载画廊"].waitForExistence(timeout: 8))
        app.buttons["reader-close"].tap()

        app.terminate()
        app.launchEnvironment["EH_FIXTURE_DIRECT_COLD"] = "missing-keep"
        app.launch()
        let previous = app.buttons["home-continue-reading"]
        XCTAssertTrue(previous.waitForExistence(timeout: 8))
        XCTAssertTrue(previous.staticTexts["Previous visit fixture"].exists || previous.label.contains("Previous visit fixture"))
        openMissingCount(app)
        let retry = app.buttons["重试"]
        XCTAssertTrue(retry.waitForExistence(timeout: 8))
        retry.tap()
        let pages = app.buttons["reader-pages"]
        XCTAssertTrue(pages.waitForExistence(timeout: 8))
        pages.tap()
        XCTAssertTrue(app.navigationBars["跳转到第 1 页"].waitForExistence(timeout: 5))
    }

    @MainActor private func openMissingCount(_ app: XCUIApplication) {
        let row = app.staticTexts["Missing page count fixture"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.press(forDuration: 0.8)
        let read = app.buttons["直接阅读"].firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 6))
        read.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
    }

    @MainActor private func showReaderControls(_ app: XCUIApplication) {
        let pages = app.buttons["reader-pages"]
        if !pages.waitForExistence(timeout: 3) {
            XCTAssertTrue(app.staticTexts["2 / 3"].waitForExistence(timeout: 4))
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(pages.waitForExistence(timeout: 5))
    }

}
