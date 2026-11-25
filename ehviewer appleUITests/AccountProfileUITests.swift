import XCTest

final class AccountProfileUITests: XCTestCase {
    @MainActor func testGuestProfileOffersLoginWithoutImplyingSignedIn() {
        let app = openProfile(signedIn: false)
        XCTAssertTrue(app.staticTexts["未登录"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["登录"].firstMatch.isHittable)
        XCTAssertFalse(app.staticTexts["已登录"].exists)
        XCTAssertFalse(app.buttons["账号"].firstMatch.isHittable)
    }

    @MainActor func testAccountNameAndLocalAvatarControlsAppearInProfile() {
        let app = openProfile(signedIn: true)
        let name = app.staticTexts["Synthetic account"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 6))
        let account = app.buttons["账号"].firstMatch
        XCTAssertTrue(account.isHittable)
        account.tap()

        XCTAssertTrue(app.staticTexts["UID 970001"].waitForExistence(timeout: 6))
        let editor = app.buttons["account-avatar-edit"].firstMatch
        XCTAssertTrue(editor.isHittable)
        // Tap the row center, not just the text. Form previously advertised a
        // full-width action but the nested menu only responded on its label.
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5)).tap()
        let fromFile = app.buttons["account-avatar-file"].firstMatch
        let fromPhoto = app.buttons["account-avatar-photo"].firstMatch
        XCTAssertTrue(fromFile.waitForExistence(timeout: 5))
        XCTAssertTrue(fromPhoto.isHittable)

        fromFile.tap()
        let files = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "DOC.")).firstMatch
        XCTAssertTrue(files.waitForExistence(timeout: 8), "The native Files picker must open.")
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"])).firstMatch
        XCTAssertTrue(cancel.isHittable, "The document picker must expose Cancel.")
        cancel.tap()
        XCTAssertTrue(fromPhoto.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["UID 970001"].isHittable)
    }

    @MainActor private func openProfile(signedIn: Bool) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EH_OFFLINE_UI_FIXTURE"] = "1"
        if signedIn { app.launchEnvironment["EH_FIXTURE_ACCOUNT_PROFILE"] = "1" }
        app.launch()
        let tab = app.buttons["我的"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 8))
        tab.tap()
        return app
    }
}
