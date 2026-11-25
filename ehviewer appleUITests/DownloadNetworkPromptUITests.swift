import XCTest

final class DownloadNetworkPromptUITests: XCTestCase {
    @MainActor func testHistoryLongPressRequiresTheSameConsentAsDetails() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EH_OFFLINE_UI_FIXTURE"] = "1"
        app.launchEnvironment["EH_FIXTURE_DOWNLOAD_NETWORK_CONFIRMATION"] = "1"
        app.launchEnvironment["EH_FIXTURE_HISTORY_TAG"] = "1"
        app.launchEnvironment["EH_FIXTURE_LAUNCH_PAGE"] = "5"
        app.launch()

        let history = app.staticTexts["Synthetic tag history item"].firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 8))
        history.press(forDuration: 0.8)
        let download = app.buttons.matching(NSPredicate(format: "label == %@", "下载")).allElementsBoundByIndex
        guard let action = download.last(where: \.isHittable) else {
            XCTFail("History download context menu item is missing.")
            return
        }
        action.tap()
        cancelNetworkPrompt(in: app)
        XCTAssertTrue(history.isHittable)

        history.tap()
        let detailDownload = app.buttons["gallery-detail-download"].firstMatch
        XCTAssertTrue(detailDownload.waitForExistence(timeout: 8))
        XCTAssertTrue(detailDownload.isEnabled, "Cancellation must not enqueue the history download.")
        detailDownload.tap()
        cancelNetworkPrompt(in: app)
        XCTAssertTrue(detailDownload.isEnabled, "Cancellation must not enqueue the detail download.")
    }

    @MainActor private func cancelNetworkPrompt(in app: XCUIApplication) {
        let prompt = app.alerts["下载网络确认"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 6))
        XCTAssertTrue(prompt.buttons["继续下载"].exists)
        prompt.buttons["取消"].tap()
        XCTAssertTrue(prompt.waitForNonExistence(timeout: 6))
    }
}
