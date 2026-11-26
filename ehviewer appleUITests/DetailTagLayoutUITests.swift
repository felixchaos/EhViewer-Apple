import XCTest

final class DetailTagLayoutUITests: XCTestCase {
    @MainActor func testLongGalleryTagWrapsWithinViewportWithoutClippingOtherTags() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EH_OFFLINE_UI_FIXTURE"] = "1"
        app.launchEnvironment["EH_FIXTURE_LONG_DETAIL_TAGS"] = "1"
        app.launch()

        let gallery = app.staticTexts["Synthetic Gallery"].firstMatch
        XCTAssertTrue(gallery.waitForExistence(timeout: 8))
        gallery.tap()
        XCTAssertTrue(app.buttons["gallery-detail-read"].waitForExistence(timeout: 8))

        let previous = app.buttons["fixture before long tag"].firstMatch
        let longTag = String(repeating: "fixture long tag ", count: 8) + "end"
        let oversized = app.buttons.matching(NSPredicate(format: "label == %@", longTag)).firstMatch
        let following = app.buttons["fixture after long tag"].firstMatch
        XCTAssertTrue(previous.waitForExistence(timeout: 8))
        XCTAssertTrue(oversized.waitForExistence(timeout: 8))
        XCTAssertTrue(following.waitForExistence(timeout: 8))

        let viewport = app.frame
        for chip in [previous, oversized, following] {
            XCTAssertGreaterThanOrEqual(chip.frame.minX, viewport.minX)
            XCTAssertLessThanOrEqual(chip.frame.maxX, viewport.maxX + 1)
        }
        XCTAssertGreaterThan(oversized.frame.height, previous.frame.height * 1.5,
                             "The title should wrap instead of being truncated on one line.")
        XCTAssertGreaterThanOrEqual(following.frame.minY + 1, oversized.frame.maxY,
                                    "A wrapped chip must reserve enough height for the following row.")
    }
}
