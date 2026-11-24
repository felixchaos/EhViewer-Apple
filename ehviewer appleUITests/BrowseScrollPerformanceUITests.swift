import XCTest

/// Compare two pinned builds on the same simulator/hardware. This is disabled
/// for regular CI because it repeats real gestures and needs an idle host.
final class BrowseScrollPerformanceUITests: XCTestCase {
    @MainActor func testWarmWatchedCenterScroll() throws { try measureScroll(startX: 0.55) }
    @MainActor func testWarmWatchedTrailingScroll() throws { try measureScroll(startX: 0.972) }

    @MainActor private func measureScroll(startX: CGFloat) throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["EH_RUN_SCROLL_PERFORMANCE"] == "1",
                          "Run this comparison explicitly on an idle host.")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EH_OFFLINE_UI_FIXTURE"] = "1"
        app.launchEnvironment["EH_FIXTURE_SUBSCRIPTION_FLOW"] = "1"
        app.launch()
        XCTAssertTrue(app.staticTexts["Synthetic Gallery"].firstMatch.waitForExistence(timeout: 8))
        let controls = app.buttons.matching(NSPredicate(format: "label == %@", "订阅"))
        try XCTUnwrap(controls.allElementsBoundByIndex.first(where: \.isHittable)).tap()
        let first = app.staticTexts["Watched origin row 1"]
        XCTAssertTrue(first.waitForExistence(timeout: 8))

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: startX, dy: 0.74))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: startX, dy: 0.37))
        let restoreStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.36))
        let restoreEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.82))
        let initialY = first.frame.midY
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        options.invocationOptions = [.manuallyStart]
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            // Restoration and correctness assertions are outside the timed interval.
            for _ in 0..<3 where !first.isHittable || abs(first.frame.midY - initialY) > 2 {
                restoreStart.press(forDuration: 0.06, thenDragTo: restoreEnd,
                                   withVelocity: .fast, thenHoldForDuration: 0)
            }
            XCTAssertTrue(first.isHittable)
            XCTAssertEqual(first.frame.midY, initialY, accuracy: 2)
            startMeasuring()
            start.press(forDuration: 0.06, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
            stopMeasuring()
            XCTAssertTrue(!first.isHittable || abs(first.frame.midY - initialY) > 40,
                          "The list must actually move; a swallowed swipe cannot be a performance pass.")
            XCTAssertFalse(app.staticTexts["快速搜索"].firstMatch.isHittable)
            XCTAssertFalse(app.buttons["reader-close"].exists)
        }
    }
}
