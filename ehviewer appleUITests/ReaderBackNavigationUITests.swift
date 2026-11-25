import XCTest

final class ReaderBackNavigationUITests: XCTestCase {
    @MainActor func testDetailEdgeRetreatCancelsThenCompletesAndKeepsListAnchor() throws {
        let app = try launch(scrolled: true)
        let row = app.staticTexts["First visit fixture"].firstMatch
        let visible = (app.frame.height * 0.24)...(app.frame.height * 0.84)
        for _ in 0..<5 {
            if row.exists, visible.contains(row.frame.midY) { break }
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(row.exists && visible.contains(row.frame.midY))
        let rowY = row.frame.midY
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let detailBack = app.buttons["gallery-detail-back"]
        XCTAssertTrue(detailBack.waitForExistence(timeout: 7))
        XCTAssertTrue(detailBack.isHittable)

        edgeDrag(in: app, to: 0.17, velocity: .slow, hold: 0.4)
        XCTAssertTrue(detailBack.isHittable, "Short, held edge drag should cancel the pop.")
        edgeDrag(in: app, to: 0.78, velocity: .fast, hold: 0)
        XCTAssertTrue(detailBack.waitForNonExistence(timeout: 6), "Completed left-edge drag should pop detail.")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(row.frame.midY, rowY, accuracy: 4)

        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(waitForHit(detailBack))
        detailBack.tap()
        XCTAssertTrue(detailBack.waitForNonExistence(timeout: 6))
        XCTAssertEqual(row.frame.midY, rowY, accuracy: 4)
    }

    @MainActor func testReaderButtonReturnsToTheSameDetail() throws {
        let app = try launch()
        let detail = enterDetail(app)
        openReader(app, read: detail)
        let close = app.buttons["reader-close"]
        close.tap()
        XCTAssertTrue(readerArtwork(in: app).waitForNonExistence(timeout: 6))
        assertDetailCanReturnToList(app)
    }

    @MainActor func testReaderEdgeRetreatCancelsThenReturnsToDetail() throws {
        let app = try launch()
        let detail = enterDetail(app)
        openReader(app, read: detail)
        let close = app.buttons["reader-close"]
        edgeDrag(in: app, to: 0.17, velocity: .slow, hold: 0.4)
        XCTAssertTrue(close.isHittable, "Short edge drag should not close the reader.")
        edgeDrag(in: app, to: 0.78, velocity: .fast, hold: 0)
        XCTAssertTrue(readerArtwork(in: app).waitForNonExistence(timeout: 6),
                      "Completed left-edge retreat should close the reader, not only hide its toolbar.")
        assertDetailCanReturnToList(app)
    }

    @MainActor private func readerArtwork(in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "reader-zoom-page-")).firstMatch
    }

    @MainActor private func waitForHit(_ element: XCUIElement) -> Bool {
        let hit = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: element)
        return XCTWaiter.wait(for: [hit], timeout: 6) == .completed
    }

    @MainActor private func assertDetailCanReturnToList(_ app: XCUIApplication) {
        let back = app.buttons["gallery-detail-back"]
        XCTAssertTrue(waitForHit(back), "The original detail's back button must be real and interactive.")
        XCTAssertGreaterThanOrEqual(back.frame.width, 44)
        XCTAssertGreaterThanOrEqual(back.frame.height, 44)
        back.tap()
        let popped = back.waitForNonExistence(timeout: 6)
        if !popped {
            XCTContext.runActivity(named: "Back failure screenshot") { activity in
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.lifetime = .keepAlways
                activity.add(attachment)
            }
        }
        XCTAssertTrue(popped, "The detail Back tap should return to its list.")
        XCTAssertTrue(app.staticTexts["Synthetic Gallery"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForHit(app.buttons["我的"].firstMatch))
    }

    @MainActor private func launch(scrolled: Bool = false) throws -> XCUIApplication {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["EH_RUN_READER_GESTURES"] == "1")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EH_OFFLINE_UI_FIXTURE"] = "1"
        if scrolled { app.launchEnvironment["EH_FIXTURE_DIRECT_COLD"] = "scrolled-reset" }
        else {
            app.launchEnvironment["EH_FIXTURE_READER_GESTURES"] = "1"
            app.launchEnvironment["EH_FIXTURE_LOCAL_READER"] = "1"
        }
        app.launch()
        return app
    }

    @MainActor private func enterDetail(_ app: XCUIApplication) -> XCUIElement {
        let row = app.staticTexts["Synthetic Gallery"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
        let detail = app.buttons["gallery-detail-read"].firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 7))
        return detail
    }

    @MainActor private func openReader(_ app: XCUIApplication, read: XCUIElement) {
        read.tap()
        XCTAssertTrue(app.buttons["reader-close"].waitForExistence(timeout: 8))
        XCTAssertTrue(readerArtwork(in: app).waitForExistence(timeout: 8))
    }

    @MainActor private func edgeDrag(in app: XCUIApplication, to x: CGFloat,
                                     velocity: XCUIGestureVelocity, hold: TimeInterval) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.006, dy: 0.47))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.47))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: velocity, thenHoldForDuration: hold)
    }
}
