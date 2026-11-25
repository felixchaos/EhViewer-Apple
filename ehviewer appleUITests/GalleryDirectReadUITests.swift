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
        XCTAssertTrue(app.buttons["阅读"].firstMatch.waitForExistence(timeout: 8))
    }
}
