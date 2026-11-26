import XCTest

final class DownloadNetworkPromptUITests: XCTestCase {
    @MainActor func testHistoryAndDetailsShowInlineConsentWithoutEnqueueingOnBack() {
        continueAfterFailure = false
        let app = launchHistory(metered: true)
        let history = app.staticTexts["Synthetic tag history item"].firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 8))
        openHistoryDownload(in: app, history: history)
        cancelSetup(in: app, metered: true)
        XCTAssertTrue(history.isHittable)

        history.tap()
        let detailDownload = app.buttons["gallery-detail-download"].firstMatch
        XCTAssertTrue(detailDownload.waitForExistence(timeout: 8))
        XCTAssertTrue(detailDownload.isEnabled, "Cancellation must not enqueue the history download.")
        detailDownload.tap()
        cancelSetup(in: app, metered: true)
        XCTAssertTrue(detailDownload.isEnabled, "Cancellation must not enqueue the detail download.")
    }

    @MainActor func testSettingsDefaultAndOneTimeSelectionAreIndependent() {
        continueAfterFailure = false
        let app = launchHistory(metered: false)
        let profile = app.buttons["我的"].firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 8))
        profile.tap()
        let download = app.buttons["下载"].firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 6))
        // The row also shares its name with the floating tab. Require the
        // settings destination rather than converting an AX tap into evidence.
        let rows = app.buttons.matching(NSPredicate(format: "label == %@", "下载")).allElementsBoundByIndex
        guard let settingsRow = rows.first(where: { $0.isHittable && $0.frame.midY < app.frame.maxY * 0.83 }) else {
            XCTFail("未找到下载设置入口")
            return
        }
        settingsRow.tap()
        let defaultEntry = app.buttons["download-default-quality-entry"].firstMatch
        XCTAssertTrue(defaultEntry.waitForExistence(timeout: 6))
        defaultEntry.tap()
        let defaultQuality = app.buttons["download-quality-1600"]
        XCTAssertTrue(defaultQuality.waitForExistence(timeout: 6))
        defaultQuality.tap()
        XCTAssertTrue(defaultQuality.isSelected)
        app.navigationBars.firstMatch.buttons.firstMatch.tap()
        XCTAssertTrue(defaultEntry.exists)
        app.navigationBars.firstMatch.buttons.firstMatch.tap()

        let historyTab = app.buttons["历史"].firstMatch
        XCTAssertTrue(historyTab.waitForExistence(timeout: 6))
        historyTab.tap()
        let history = app.staticTexts["Synthetic tag history item"].firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 8))
        openHistoryDownload(in: app, history: history)
        XCTAssertTrue(defaultQuality.waitForExistence(timeout: 6))
        XCTAssertTrue(defaultQuality.isSelected)
        let once = app.buttons["download-quality-780"]
        once.tap()
        XCTAssertTrue(once.isSelected)
        XCTAssertFalse(defaultQuality.isSelected)
        cancelSetup(in: app, metered: false)
        openHistoryDownload(in: app, history: history)
        XCTAssertTrue(defaultQuality.waitForExistence(timeout: 6))
        XCTAssertTrue(defaultQuality.isSelected, "A one-time selection must not overwrite the saved default.")
        cancelSetup(in: app, metered: false)
    }

    @MainActor func testRetainedFilesBlockNewQualityAndCanBeRestoredFromSettings() {
        continueAfterFailure = false
        let app = launchHistory(metered: false, retainedFiles: true)
        let history = app.staticTexts["Retained quality fixture"].firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 8))
        openHistoryDownload(in: app, history: history)
        let choice = app.buttons["download-quality-original"]
        XCTAssertTrue(choice.waitForExistence(timeout: 6))
        choice.tap()
        XCTAssertTrue(choice.isSelected)
        app.buttons["download-setup-submit"].tap()
        XCTAssertTrue(app.staticTexts["本地图片已保留。可在下载设置中恢复原任务。"].waitForExistence(timeout: 3))

        app.buttons["我的"].firstMatch.tap()
        let rows = app.buttons.matching(NSPredicate(format: "label == %@", "下载")).allElementsBoundByIndex
        guard let settingsRow = rows.first(where: { $0.isHittable && $0.frame.midY < app.frame.maxY * 0.83 }) else {
            XCTFail("未找到下载设置入口")
            return
        }
        settingsRow.tap()
        let entry = app.buttons["download-default-quality-entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 6))
        let restore = app.buttons["恢复下载项目"]
        for _ in 0..<4 where !restore.isHittable { app.swipeUp() }
        XCTAssertTrue(restore.isHittable)
        restore.tap()
        let result = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "成功恢复")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 6))
        app.navigationBars.firstMatch.buttons.firstMatch.tap()
        let downloadTabs = app.buttons.matching(NSPredicate(format: "label == %@", "下载")).allElementsBoundByIndex
        guard let tab = downloadTabs.last(where: { $0.isHittable && $0.frame.midY > app.frame.maxY * 0.83 }) else {
            XCTFail("未找到下载底栏")
            return
        }
        tab.tap()
        XCTAssertTrue(app.staticTexts["Retained quality fixture"].firstMatch.waitForExistence(timeout: 8))
    }

    @MainActor private func launchHistory(metered: Bool, retainedFiles: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["EH_OFFLINE_UI_FIXTURE"] = "1"
        app.launchEnvironment["EH_FIXTURE_DOWNLOAD_NETWORK_CONFIRMATION"] = metered ? "1" : "0"
        app.launchEnvironment["EH_FIXTURE_HISTORY_TAG"] = "1"
        app.launchEnvironment["EH_FIXTURE_LAUNCH_PAGE"] = "5"
        if retainedFiles { app.launchEnvironment["EH_FIXTURE_RETAINED_DOWNLOAD"] = "1" }
        app.launch()
        return app
    }

    @MainActor private func openHistoryDownload(in app: XCUIApplication, history: XCUIElement) {
        history.press(forDuration: 0.8)
        let download = app.buttons.matching(NSPredicate(format: "label == %@", "下载")).allElementsBoundByIndex
        guard let action = download.last(where: \.isHittable) else {
            XCTFail("History download context menu item is missing.")
            return
        }
        action.tap()
    }

    @MainActor private func cancelSetup(in app: XCUIApplication, metered: Bool) {
        let back = app.buttons["download-setup-back"]
        XCTAssertTrue(back.waitForExistence(timeout: 6))
        XCTAssertTrue(back.isHittable)
        XCTAssertFalse(app.alerts["下载网络确认"].exists)
        XCTAssertFalse(app.otherElements["workspace-floating-tabs"].isHittable)
        if metered {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Download settings with inline network consent"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        XCTAssertEqual(app.buttons["download-setup-submit"].label, metered ? "继续下载" : "加入下载队列")
        if metered {
            XCTAssertTrue(app.staticTexts["当前使用蜂窝网络或受限网络。"].exists)
        }
        back.tap()
        XCTAssertTrue(back.waitForNonExistence(timeout: 6))
    }
}
