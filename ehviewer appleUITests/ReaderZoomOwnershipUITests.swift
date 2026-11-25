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

    @MainActor func testVerticalReaderZoomsAndPansWithoutLeavingContinuousScroll() throws {
        let app = try openVerticalReader()
        let fit = try XCTUnwrap(waitForMetrics(app) { $0.width > 0 })
        let point = app.coordinate(withNormalizedOffset: CGVector(dx: 0.40, dy: 0.43))
        point.doubleTap()
        let zoomed = try XCTUnwrap(waitForMetrics(app) { $0.width > fit.width * 3 / 2 },
                                   "Double tap must enlarge the vertical reader's canvas.")
        XCTAssertGreaterThan(zoomed.y, fit.y + 60, "Zoom should preserve the tapped region.")
        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.81, dy: 0.53))
        let left = app.coordinate(withNormalizedOffset: CGVector(dx: 0.21, dy: 0.53))
        right.press(forDuration: 0.05, thenDragTo: left, withVelocity: .slow, thenHoldForDuration: 0.05)
        let panned = try XCTUnwrap(waitForMetrics(app) { $0.x > zoomed.x + 30 })
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.77))
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.23))
        bottom.press(forDuration: 0.05, thenDragTo: top, withVelocity: .slow, thenHoldForDuration: 0.05)
        let firstScroll = try XCTUnwrap(waitForMetrics(app) { $0.y > panned.y + 120 && $0.width == zoomed.width })
        bottom.press(forDuration: 0.05, thenDragTo: top, withVelocity: .slow, thenHoldForDuration: 0.05)
        XCTAssertNotNil(waitForMetrics(app) { $0.y > firstScroll.y + 120 && $0.width == zoomed.width })
        point.doubleTap()
        XCTAssertNotNil(waitForMetrics(app) { abs($0.width - fit.width) <= 2 && abs($0.x) <= 2 })
    }

    @MainActor func testVerticalReaderSupportsTwoFingerPinch() throws {
        let app = try openVerticalReader()
        let fit = try XCTUnwrap(waitForMetrics(app) { $0.width > 0 })
        let point = app.coordinate(withNormalizedOffset: CGVector(dx: 0.40, dy: 0.43))
        let controls = app.buttons["reader-pages"]
        if controls.exists {
            point.tap()
            XCTAssertTrue(controls.waitForNonExistence(timeout: 5), "Both fingers need to begin on the artwork, not on toolbars.")
        }
        point.doubleTap()
        let zoomed = try XCTUnwrap(waitForMetrics(app) { $0.width > fit.width * 3 / 2 })
        app.pinch(withScale: 0.65, velocity: -0.35)
        let reduced = waitForMetrics(app) { $0.width < zoomed.width * 9 / 10 }
        let final = app.staticTexts["Fixture vertical zoom"].value as? String ?? "unavailable"
        let phase = app.staticTexts["Fixture pinch"].value as? String ?? "unavailable"
        let shrunk = try XCTUnwrap(reduced, "Pinch-in (fit: \(fit.width), zoom: \(zoomed.width), settled: \(final), phase: \(phase)).")
        app.pinch(withScale: 1.7, velocity: 1)
        XCTAssertNotNil(waitForMetrics(app) { $0.width > shrunk.width * 5 / 4 },
                        "Pinching out must enlarge images without switching to horizontal paging.")
    }

    @MainActor private func openVerticalReader() throws -> XCUIApplication {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["EH_RUN_READER_GESTURES"] == "1")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EH_OFFLINE_UI_FIXTURE"] = "1"
        app.launchEnvironment["EH_FIXTURE_LOCAL_READER"] = "1"
        app.launchEnvironment["EH_FIXTURE_READER_GESTURES"] = "1"
        app.launchEnvironment["EH_FIXTURE_VERTICAL_GESTURES"] = "1"
        app.launch()
        let row = app.staticTexts["Synthetic Gallery"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
        let read = app.buttons["gallery-detail-read"].firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 8))
        read.tap()
        XCTAssertTrue(app.staticTexts["Fixture vertical zoom"].waitForExistence(timeout: 8))
        return app
    }

    private struct Metrics { var x: Int; var y: Int; var width: Int }

    @MainActor private func waitForMetrics(_ app: XCUIApplication, matching: (Metrics) -> Bool) -> Metrics? {
        let element = app.staticTexts["Fixture vertical zoom"]
        let deadline = Date().addingTimeInterval(6)
        repeat {
            let values = (element.value as? String ?? "").split(separator: "|").compactMap { Int($0) }
            if values.count == 3 {
                let metrics = Metrics(x: values[0], y: values[1], width: values[2])
                if matching(metrics) { return metrics }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return nil
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
