import XCTest

final class ReaderLoadingIndicatorUITests: XCTestCase {
    @MainActor func testDoubleSpreadHasOneIndicatorWhenOneImageFinishesEarlier() throws {
        let app = try openReader(mode: "spread")
        let active = app.descendants(matching: .any).matching(identifier: "reader-image-loading")
        let indicator = active.firstMatch
        XCTAssertTrue(indicator.waitForExistence(timeout: 5))
        XCTAssertEqual(indicator.label, "正在加载双页图片")
        XCTAssertEqual(active.count, 1)
        XCTAssertTrue(waitForValue("50%", of: indicator, timeout: 10))
        XCTAssertEqual(active.count, 1)
        XCTAssertTrue(waitForValue("90%", of: indicator, timeout: 10))
        XCTAssertEqual(active.count, 1)
        XCTAssertTrue(indicator.waitForNonExistence(timeout: 16))
    }

    @MainActor func testSecondImageArrivingFirstIsDrawnWithoutASecondIndicator() throws {
        let app = try openReader(mode: "spread-reverse")
        let active = app.descendants(matching: .any).matching(identifier: "reader-image-loading")
        let indicator = active.firstMatch
        XCTAssertTrue(indicator.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue("50%", of: indicator, timeout: 10))
        XCTAssertTrue(waitForValue("60%", of: indicator, timeout: 10))
        let second = app.descendants(matching: .any)["reader-drawn-page-3"].firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 3))
        XCTAssertTrue(second.frame.intersects(app.frame))
        XCTAssertEqual(active.count, 1)
        XCTAssertFalse(app.descendants(matching: .any)["reader-drawn-page-2"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["reader-drawn-spread"].firstMatch.waitForExistence(timeout: 12))
        XCTAssertTrue(indicator.waitForNonExistence(timeout: 4))
    }

    @MainActor func testPrimaryFailureRetainsSecondImageAndOffersOneRetry() throws {
        let app = try openReader(mode: "spread-error")
        let second = app.descendants(matching: .any)["reader-drawn-page-3"].firstMatch
        let retry = app.buttons.matching(identifier: "重新加载")
        XCTAssertTrue(second.waitForExistence(timeout: 18))
        XCTAssertTrue(retry.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(second.exists)
        XCTAssertEqual(retry.count, 1)
        XCTAssertFalse(app.descendants(matching: .any)["reader-image-loading"].exists)
        XCTAssertTrue(app.staticTexts["第 2 页：合成测试图片读取失败"].exists)
        retry.firstMatch.tap()
        let loading = app.descendants(matching: .any).matching(identifier: "reader-image-loading")
        XCTAssertTrue(loading.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(second.exists)
        XCTAssertEqual(loading.count, 1)
        XCTAssertTrue(app.descendants(matching: .any)["reader-drawn-spread"].firstMatch.waitForExistence(timeout: 16))
        XCTAssertTrue(loading.firstMatch.waitForNonExistence(timeout: 4))
    }

    @MainActor func testVerticalHasOneIndicatorWhileAdjacentImagesLoad() throws {
        try checkSingleIndicator(mode: "vertical")
    }

    @MainActor func testHorizontalHasOneIndicatorWhileAdjacentImagesLoad() throws {
        try checkSingleIndicator(mode: "horizontal")
    }

    @MainActor func testDetailGridUsesStaticPlaceholdersWhileImagesWait() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["EH_RUN_READER_LOADING"] == "1")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EH_OFFLINE_UI_FIXTURE"] = "1"
        app.launchEnvironment["EH_FIXTURE_STATIC_PREVIEWS"] = "1"
        app.launch()
        let row = app.staticTexts["Synthetic Gallery"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
        let first = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "第 1 页预览")).firstMatch
        for _ in 0..<4 {
            if first.exists, first.frame.midY > 0, first.frame.midY < app.frame.height * 0.85 { break }
            app.swipeUp()
        }
        XCTAssertTrue(first.waitForExistence(timeout: 6))
        XCTAssertTrue(first.frame.midY > 0 && first.frame.midY < app.frame.height)
        XCTAssertEqual(app.activityIndicators.count, 0)
        XCTAssertEqual(app.progressIndicators.count, 0)
    }

    @MainActor private func checkSingleIndicator(mode: String) throws {
        let app = try openReader(mode: mode)
        let active = app.descendants(matching: .any).matching(identifier: "reader-image-loading")
        let indicator = active.firstMatch
        XCTAssertTrue(indicator.waitForExistence(timeout: 5))
        XCTAssertEqual(indicator.label, "正在加载图片")
        XCTAssertEqual(active.count, 1)
        XCTAssertTrue(waitForValue("20%", of: indicator, timeout: 10))
        XCTAssertEqual(active.count, 1)
        XCTAssertTrue(indicator.waitForNonExistence(timeout: 12))
    }

    @MainActor private func waitForValue(_ value: String, of indicator: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value),
                                                     object: indicator)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor private func openReader(mode: String) throws -> XCUIApplication {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["EH_RUN_READER_LOADING"] == "1")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EH_OFFLINE_UI_FIXTURE"] = "1"
        app.launchEnvironment["EH_FIXTURE_LOCAL_READER"] = "1"
        app.launchEnvironment["EH_FIXTURE_READER_LOADING"] = mode
        app.launch()
        let row = app.staticTexts["Synthetic Gallery"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
        let read = app.buttons["gallery-detail-read"].firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 8))
        read.tap()
        return app
    }
}
