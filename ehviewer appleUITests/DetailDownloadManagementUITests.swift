import XCTest

final class DetailDownloadManagementUITests: XCTestCase {
    @MainActor func testCompletedDownloadManagementCancellationAndOfflineRead() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EH_OFFLINE_UI_FIXTURE"] = "1"
        app.launchEnvironment["EH_FIXTURE_LOCAL_READER"] = "1"
        app.launch()

        let row = app.staticTexts["Synthetic Gallery"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
        let manage = app.buttons["gallery-detail-download"].firstMatch
        XCTAssertTrue(manage.waitForExistence(timeout: 8))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "管理下载，已下载"), object: manage)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 6), .completed)
        manage.tap()
        let remove = app.buttons["移除离线文件…"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        let confirm = app.alerts["移除离线文件？"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 6))
        XCTAssertTrue(confirm.buttons["移除下载文件"].exists)
        confirm.buttons["取消"].tap()
        XCTAssertTrue(manage.waitForExistence(timeout: 6))
        XCTAssertEqual(manage.label, "管理下载，已下载", "Cancelling must keep the download.")
        manage.tap()
        let offline = app.buttons["离线阅读"].firstMatch
        XCTAssertTrue(offline.waitForExistence(timeout: 5))
        offline.tap()
        XCTAssertTrue(app.buttons["reader-close"].waitForExistence(timeout: 8))
    }
}
