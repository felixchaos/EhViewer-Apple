import XCTest

final class BrowseSearchScopeUITests: XCTestCase {
    @MainActor func testSubscriptionKeywordUsesWatchedEndpoint() {
        continueAfterFailure = false
        let app = launch()
        app.buttons["订阅"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Synthetic subscription origin"].waitForExistence(timeout: 8))
        typeKeyword(in: app, submit: true)
        XCTAssertTrue(app.staticTexts["Scoped fixture result"].waitForExistence(timeout: 8),
                      "Submitting in Subscriptions must request /watched with the keyword.")
        XCTAssertFalse(app.staticTexts["Global fixture result"].exists)
    }

    @MainActor func testExplicitFullSiteSearchFromSubscriptionUsesGlobalEndpoint() {
        continueAfterFailure = false
        let app = launch()
        app.buttons["订阅"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Synthetic subscription origin"].waitForExistence(timeout: 8))
        typeKeyword(in: app, submit: false)
        let global = app.buttons["浏览-搜全站"]
        XCTAssertTrue(global.waitForExistence(timeout: 6))
        global.tap()
        XCTAssertTrue(app.staticTexts["Global fixture result"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["Scoped fixture result"].exists)
    }

    @MainActor func testHomeKeywordRemainsGlobal() {
        continueAfterFailure = false
        let app = launch()
        typeKeyword(in: app, submit: true)
        XCTAssertTrue(app.staticTexts["Global fixture result"].waitForExistence(timeout: 8))
    }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["EH_OFFLINE_UI_FIXTURE"] = "1"
        app.launchEnvironment["EH_FIXTURE_SEARCH_SCOPE"] = "1"
        app.launch()
        XCTAssertTrue(app.staticTexts["Synthetic Gallery"].firstMatch.waitForExistence(timeout: 8))
        return app
    }

    @MainActor private func typeKeyword(in app: XCUIApplication, submit: Bool) {
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 6))
        field.tap()
        let focused = app.textFields.matching(NSPredicate(format: "hasKeyboardFocus == YES")).firstMatch
        XCTAssertTrue(focused.waitForExistence(timeout: 5))
        focused.typeText(submit ? "offlineparity\n" : "offlineparity")
    }
}
