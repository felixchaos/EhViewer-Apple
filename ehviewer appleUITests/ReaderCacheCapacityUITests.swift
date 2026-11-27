import XCTest

final class ReaderCacheCapacityUITests: XCTestCase {
    @MainActor func testClearReadingCacheReportsFilesystemFailure() {
        let app = openCacheSettings(failure: true)
        app.buttons["清空阅读缓存"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["无法清空阅读缓存。"].firstMatch.waitForExistence(timeout: 5),
                      "A cache-path failure must not report success.")
    }

    @MainActor func testClearReadingCacheRemovesSeededBytesWithoutRestart() {
        let app = openCacheSettings(failure: false)
        let usage = app.staticTexts["settings-reader-cache-usage"].firstMatch
        let seeded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "43"), object: usage)
        XCTAssertEqual(XCTWaiter.wait(for: [seeded], timeout: 5), .completed)
        app.buttons["清空阅读缓存"].firstMatch.tap()
        let empty = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "0"), object: usage)
        XCTAssertEqual(XCTWaiter.wait(for: [empty], timeout: 5), .completed)
    }

    @MainActor private func openCacheSettings(failure: Bool) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EH_OFFLINE_UI_FIXTURE"] = "1"
        app.launchEnvironment[failure ? "EH_FIXTURE_READ_CACHE_CLEAR_FAILURE" : "EH_FIXTURE_READ_CACHE_LIMIT"] = "1"
        app.launch()
        let profile = app.buttons["我的"].firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 8))
        profile.tap()
        let download = app.buttons.matching(NSPredicate(format: "label == %@", "下载"))
            .allElementsBoundByIndex.first { $0.isHittable && $0.frame.midY < app.frame.height * 0.83 }
        XCTAssertNotNil(download)
        download?.tap()
        let clear = app.buttons["清空阅读缓存"].firstMatch
        for _ in 0..<7 where !clear.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(clear.isHittable)
        return app
    }

    @MainActor func testLoweringCapacityAppliesWithoutRestart() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EH_OFFLINE_UI_FIXTURE"] = "1"
        app.launchEnvironment["EH_FIXTURE_READ_CACHE_LIMIT"] = "1"
        app.launch()
        let profile = app.buttons["我的"].firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 8))
        profile.tap()
        let download = app.buttons.matching(NSPredicate(format: "label == %@", "下载"))
            .allElementsBoundByIndex.first { $0.isHittable && $0.frame.midY < app.frame.height * 0.83 }
        XCTAssertNotNil(download)
        download?.tap()
        let picker = app.descendants(matching: .any)["settings-reader-cache-capacity"].firstMatch
        for _ in 0..<7 where !picker.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(picker.isHittable)
        let usage = app.staticTexts["settings-reader-cache-usage"].firstMatch
        let initial = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "43"), object: usage)
        XCTAssertEqual(XCTWaiter.wait(for: [initial], timeout: 5), .completed)
        picker.tap()
        let lower = app.buttons["40 MB"].firstMatch
        XCTAssertTrue(lower.waitForExistence(timeout: 5))
        lower.tap()
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "0"), object: usage)
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 5), .completed,
                       "Usage should update after applying the new limit within this app session.")
        XCTAssertTrue((picker.value as? String)?.contains("40 MB") == true || picker.label.contains("40 MB")
                      || picker.staticTexts["40 MB"].exists,
                      "Selected capacity: \(String(describing: picker.value)), \(picker.label)")
    }
}
