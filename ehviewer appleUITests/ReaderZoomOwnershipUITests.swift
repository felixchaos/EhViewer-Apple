import XCTest

final class ReaderZoomOwnershipUITests: XCTestCase {
    @MainActor func testJumpFromZoomedPageDoesNotLockTheNextPage() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["EH_RUN_READER_GESTURES"] == "1")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EH_OFFLINE_UI_FIXTURE"] = "1"
        app.launchEnvironment["EH_FIXTURE_LOCAL_READER"] = "1"
        app.launchEnvironment["EH_FIXTURE_READER_GESTURES"] = "1"
        app.launch()
        let row = app.staticTexts["Synthetic Gallery"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
        let read = app.buttons["gallery-detail-read"].firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 8))
        read.tap()

        let first = app.staticTexts["reader-zoom-page-1"]
        let second = app.staticTexts["reader-zoom-page-2"]
        let third = app.staticTexts["reader-zoom-page-3"]
        XCTAssertTrue(waitForVisible(first, label: "Fit", in: app))
        jumpTo(2, in: app)
        XCTAssertTrue(waitForVisible(second, label: "Fit", in: app))
        swipeForward(in: app)
        XCTAssertTrue(waitForVisible(third, label: "Fit", in: app), "Unzoomed control must allow swiping after a grid jump.")
        jumpTo(1, in: app)
        XCTAssertTrue(waitForVisible(first, label: "Fit", in: app))

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.43)).doubleTap()
        XCTAssertTrue(waitForVisible(first, label: "Zoomed", in: app))
        jumpTo(2, in: app)
        XCTAssertTrue(waitForVisible(second, label: "Fit", in: app), "Grid must reach page 2 even when the prior page was zoomed.")
        swipeForward(in: app)
        XCTAssertTrue(waitForVisible(third, label: "Fit", in: app),
                      "The unzoomed destination must not inherit page 1's scroll lock.")
    }

    @MainActor private func swipeForward(in app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.84, dy: 0.50))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.50))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
    }

    @MainActor private func jumpTo(_ page: Int, in app: XCUIApplication) {
        let directory = app.buttons["reader-pages"]
        if !directory.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.43)).tap()
        }
        XCTAssertTrue(directory.waitForExistence(timeout: 6))
        directory.tap()
        let target = app.buttons[String(page)].firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        target.tap()
        XCTAssertTrue(target.waitForNonExistence(timeout: 5))
    }

    @MainActor private func waitForVisible(_ page: XCUIElement, label: String, in app: XCUIApplication) -> Bool {
        let deadline = Date().addingTimeInterval(6)
        repeat {
            if page.exists, page.label == label,
               page.frame.midX >= app.frame.minX && page.frame.midX < app.frame.midX,
               page.frame.midY >= app.frame.minY && page.frame.midY < app.frame.midY {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return false
    }
}
