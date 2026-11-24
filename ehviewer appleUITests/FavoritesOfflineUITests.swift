#if EH_OFFLINE_UI_FIXTURE && targetEnvironment(simulator)
import CoreGraphics
import XCTest

final class FavoritesOfflineUITests: XCTestCase {
    @MainActor private func launch(cloud: String, importID: String? = nil, nativePicker: Bool = false, launchPage: Int? = nil, localReader: Bool = false, historyTag: Bool = false, clearFinished: Bool = false, downloadSort: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EH_OFFLINE_UI_FIXTURE"] = "1"
        app.launchEnvironment["EH_FIXTURE_CLOUD"] = cloud
        if let importID { app.launchEnvironment["EH_FIXTURE_IMPORT"] = importID }
        if nativePicker { app.launchEnvironment["EH_FIXTURE_NATIVE_FILE_PICKER"] = "1" }
        if let launchPage { app.launchEnvironment["EH_FIXTURE_LAUNCH_PAGE"] = String(launchPage) }
        if localReader { app.launchEnvironment["EH_FIXTURE_LOCAL_READER"] = "1" }
        if historyTag { app.launchEnvironment["EH_FIXTURE_HISTORY_TAG"] = "1" }
        if clearFinished { app.launchEnvironment["EH_FIXTURE_CLEAR_FINISHED"] = "1" }
        if downloadSort { app.launchEnvironment["EH_FIXTURE_DOWNLOAD_SORT"] = "1" }
        app.launch()
        return app
    }

    @MainActor private func tab(_ name: String, in app: XCUIApplication) {
        // Both the floating tab bar and the expanded sidebar are actual production controls.
        let button = app.buttons[name].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 8), name)
        button.tap()
    }

    @MainActor private func header(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "favorites-page-header").firstMatch
    }

    @MainActor private func openSynthetic(_ app: XCUIApplication) {
        let item = app.staticTexts["Synthetic Gallery"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 8))
        item.tap()
    }

    @MainActor private func back(_ app: XCUIApplication) {
        let custom = app.buttons["gallery-detail-back"]
        let labeled = app.buttons["返回"]
        if custom.waitForExistence(timeout: 2) { custom.tap() }
        else if labeled.exists { labeled.tap() }
        else {
            let native = app.navigationBars.buttons.firstMatch
            if !native.exists { attachHierarchy(app, note: "Missing detail Back") }
            XCTAssertTrue(native.exists)
            native.tap()
        }
    }

    @MainActor private func attachHierarchy(_ app: XCUIApplication, note: String) {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = note + " hierarchy"
        tree.lifetime = .keepAlways
        add(tree)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = note + " screenshot"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        print(note, app.debugDescription)
    }

    @MainActor private func expectSelection(_ selected: Bool, heart: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == %@", NSNumber(value: selected)), object: heart
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 4), .completed)
    }

    @MainActor private func checkFlow(cloud: String) {
        let app = launch(cloud: cloud)
        tab("收藏", in: app)
        let header = header(app)
        XCTAssertTrue(header.waitForExistence(timeout: 8))
        let emptyY = header.frame.minY
        tab("首页", in: app)
        openSynthetic(app)
        let heart = app.buttons["gallery-detail-favorite"]
        XCTAssertTrue(heart.waitForExistence(timeout: 8))
        expectSelection(false, heart: heart)
        heart.tap()
        expectSelection(true, heart: heart)
        back(app)
        tab("收藏", in: app)
        XCTAssertTrue(app.staticTexts["Synthetic Gallery"].firstMatch.waitForExistence(timeout: 8))
        XCTAssertEqual(header.frame.minY, emptyY, accuracy: 2)
        if cloud == "one" {
            XCTAssertTrue(app.staticTexts["Synthetic Cloud Gallery"].firstMatch.exists)
        }
        openSynthetic(app)
        XCTAssertTrue(heart.waitForExistence(timeout: 8))
        expectSelection(true, heart: heart)
        heart.tap()
        expectSelection(false, heart: heart)
        back(app)
        XCTAssertEqual(header.frame.minY, emptyY, accuracy: 2)
        tab("历史", in: app)
        XCTAssertTrue(app.staticTexts["阅读历史"].waitForExistence(timeout: 6))
        tab("下载", in: app)
        XCTAssertTrue(app.staticTexts["下载"].firstMatch.waitForExistence(timeout: 6))
        tab("收藏", in: app)
        XCTAssertEqual(header.frame.minY, emptyY, accuracy: 2)
    }

    @MainActor private func checkMountedImport(nativePicker: Bool) {
        let importID = UUID().uuidString
        let fileBase = "offline-regression-" + importID
        let app = launch(cloud: "empty", importID: importID, nativePicker: nativePicker)
        XCTAssertTrue(app.staticTexts["Apple resume fixture"].firstMatch.waitForExistence(timeout: 8))
        tab("收藏", in: app)
        XCTAssertTrue(header(app).waitForExistence(timeout: 8))
        tab("历史", in: app)
        XCTAssertTrue(app.staticTexts["Apple resume fixture"].firstMatch.waitForExistence(timeout: 8))
        tab("我的", in: app)

        let entry = app.buttons["settings-favorites-entry"].firstMatch
        for _ in 0..<3 where !entry.isHittable { app.swipeUp() }
        XCTAssertTrue(entry.isHittable)
        entry.tap()
        let importButton = app.buttons["settings-android-library-import"].firstMatch
        if !importButton.waitForExistence(timeout: 8) { attachHierarchy(app, note: "Missing import control") }
        XCTAssertTrue(importButton.exists)
        importButton.tap()

        if nativePicker {
            let searchField = app.searchFields.firstMatch
            XCTAssertTrue(searchField.waitForExistence(timeout: 6))
            searchField.tap()
            searchField.typeText(importID)
            let file = app.cells.matching(NSPredicate(format: "identifier CONTAINS %@ OR label CONTAINS %@",
                                                     fileBase, fileBase)).firstMatch
            XCTAssertTrue(file.waitForExistence(timeout: 8))
            file.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        }

        let preview = app.staticTexts["导入预览"]
        if !preview.waitForExistence(timeout: 8) { attachHierarchy(app, note: "The import selection did not open preview") }
        XCTAssertTrue(preview.exists)
        app.buttons["导入"].tap()
        let success = app.alerts["导入完成"]
        if !success.waitForExistence(timeout: 8) { attachHierarchy(app, note: "Import failed") }
        XCTAssertTrue(success.exists)
        success.buttons["好"].tap()
        let labeledBack = app.buttons["返回"].firstMatch
        let duoSystemBack = app.buttons["BackButton"].firstMatch
        let nativeBack = app.navigationBars.buttons.firstMatch
        if labeledBack.isHittable {
            labeledBack.tap()
        } else if duoSystemBack.isHittable {
            duoSystemBack.tap()
        } else if nativeBack.isHittable {
            nativeBack.tap()
        } else {
            attachHierarchy(app, note: "Missing settings Back after import")
            XCTFail("Missing settings Back after import")
            return
        }
        tab("收藏", in: app)
        let importedFavorite = app.staticTexts["Imported favorite fixture"].firstMatch
        XCTAssertTrue(importedFavorite.waitForExistence(timeout: 8))
        XCTAssertTrue(importedFavorite.isHittable)
        tab("历史", in: app)
        let importedRead = app.staticTexts["Imported reading 54"].firstMatch
        XCTAssertTrue(importedRead.waitForExistence(timeout: 8))
        XCTAssertTrue(importedRead.isHittable)
        tab("首页", in: app)
        XCTAssertTrue(app.staticTexts["Apple resume fixture"].firstMatch.waitForExistence(timeout: 8))
    }

    @MainActor func testImportRefreshesMountedTabsAndKeepsHomeResume() {
        checkMountedImport(nativePicker: false)
    }

    @MainActor func testNativeFilesImportRefreshesMountedTabs() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["EH_RUN_NATIVE_FILE_SMOKE"] == "1",
                          "Native Files provider smoke is an explicit separate check.")
        checkMountedImport(nativePicker: true)
    }

    @MainActor func testLaunchPreferenceSelectsPopularAndRankingRequests() {
        let popular = launch(cloud: "empty", launchPage: 1)
        XCTAssertTrue(popular.staticTexts["Synthetic popular launch"].firstMatch.waitForExistence(timeout: 8))
        popular.terminate()

        let ranking = launch(cloud: "empty", launchPage: 2)
        XCTAssertTrue(ranking.staticTexts["Synthetic ranking launch"].firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(ranking.buttons["全部时间"].firstMatch.exists)
    }

    @MainActor func testApplyKeywordlessMinimumRatingAndReplaceIt() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EH_OFFLINE_UI_FIXTURE"] = "1"
        app.launchEnvironment["EH_FIXTURE_ADVANCED_SEARCH"] = "1"
        app.launch()

        func openOptions() {
            let fields = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "搜索标签或标题"))
                .allElementsBoundByIndex.filter(\.isHittable)
            // On blank filtered results the visible field leaves room for its
            // Clear affordance; the retained origin can still appear in AX.
            let field = fields.min(by: { $0.frame.width < $1.frame.width })
            XCTAssertNotNil(field)
            field?.tap()
            let advanced = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "高级搜索")).firstMatch
            XCTAssertTrue(advanced.waitForExistence(timeout: 5))
            if !advanced.isHittable { app.swipeUp() }
            advanced.tap()
            XCTAssertTrue(app.navigationBars["搜索选项"].waitForExistence(timeout: 5))
        }
        func chooseRating(_ current: String, _ next: String) {
            let currentRating = app.buttons[current].firstMatch
            if !currentRating.isHittable { app.swipeUp() }
            XCTAssertTrue(currentRating.waitForExistence(timeout: 5))
            currentRating.tap()
            app.buttons[next].firstMatch.tap()
        }
        func apply() {
            let apply = app.buttons["应用"].firstMatch
            if apply.exists { apply.tap() } else { app.buttons["完成"].firstMatch.tap() }
        }
        XCTAssertTrue(app.staticTexts["Synthetic Gallery"].firstMatch.waitForExistence(timeout: 8))
        openOptions()
        app.switches["Enable advance options"].firstMatch.tap()
        let rating = app.buttons["Minimum Rating:"].firstMatch
        if !rating.isHittable { app.swipeUp() }
        XCTAssertTrue(rating.waitForExistence(timeout: 5))
        rating.tap()
        chooseRating("2 stars", "4 stars")
        apply()
        let four = app.staticTexts["Synthetic rating 4"].firstMatch
        let five = app.staticTexts["Synthetic rating 5"].firstMatch
        XCTAssertTrue(four.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Synthetic rating 4 cursor page"].waitForExistence(timeout: 8))

        openOptions()
        chooseRating("4 stars", "5 stars")
        app.navigationBars["搜索选项"].buttons["取消"].tap()
        XCTAssertFalse(app.navigationBars["搜索选项"].exists)
        // The advanced form returns to search focus; leave the search panel
        // separately without submitting another query.
        if !four.isHittable { app.buttons["取消"].firstMatch.tap() }
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: four)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed)
        XCTAssertFalse(five.exists)

        openOptions()
        chooseRating("4 stars", "5 stars")
        apply()
        XCTAssertTrue(five.waitForExistence(timeout: 8))
        XCTAssertFalse(four.exists)
        XCTAssertFalse(app.staticTexts["Synthetic rating 4 cursor page"].exists)
        XCTAssertTrue(app.staticTexts["Synthetic rating 5 numbered page"].waitForExistence(timeout: 8))
        app.buttons["清除搜索"].firstMatch.tap()
        let home = app.staticTexts["Synthetic Gallery"].firstMatch
        let homeVisible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: home)
        XCTAssertEqual(XCTWaiter.wait(for: [homeVisible], timeout: 5), .completed)
        XCTAssertFalse(five.exists)
    }

    @MainActor func testClearFiltersKeepsTypedQuery() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EH_OFFLINE_UI_FIXTURE"] = "1"
        app.launchEnvironment["EH_FIXTURE_ADVANCED_SEARCH"] = "1"
        app.launch()
        let field = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "搜索标签或标题")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap()
        field.typeText("offline-filter-reset")
        let advanced = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "高级搜索")).firstMatch
        XCTAssertTrue(advanced.waitForExistence(timeout: 5))
        if !advanced.isHittable { app.swipeUp() }
        advanced.tap()
        app.switches["Enable advance options"].firstMatch.tap()
        app.buttons["应用"].firstMatch.tap()

        let relax = app.buttons["清除筛选条件"].firstMatch
        XCTAssertTrue(relax.waitForExistence(timeout: 8))
        relax.tap()
        XCTAssertTrue(app.staticTexts["Synthetic same query after clearing filters"].waitForExistence(timeout: 8))
    }

    @MainActor func testHomeAndPopularUseSubmittedSearchQuery() {
        let app = launch(cloud: "empty")
        XCTAssertTrue(app.staticTexts["Synthetic Gallery"].firstMatch.waitForExistence(timeout: 8))

        func submit(_ query: String) {
            // The wide shell keeps Home's submitted search mounted when a
            // sidebar destination is selected. Target the current empty input,
            // not Home's retained field that still holds the prior query.
            let placeholder = "搜索标签或标题"
            let emptyInput = NSPredicate(format: "placeholderValue == %@ AND (value == %@ OR value == %@ OR value == nil)", placeholder, placeholder, "")
            let field = app.textFields.matching(emptyInput).firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            XCTAssertTrue(field.isHittable)
            field.tap()
            field.typeText(query + "\n")
        }

        submit("offlinehome")
        XCTAssertTrue(app.staticTexts["Synthetic home search result"].firstMatch.waitForExistence(timeout: 8))

        let popular = app.buttons["热门"].firstMatch
        XCTAssertTrue(popular.waitForExistence(timeout: 5))
        popular.tap()
        XCTAssertTrue(app.staticTexts["Synthetic popular launch"].firstMatch.waitForExistence(timeout: 8))
        submit("offlinepopular")
        XCTAssertTrue(app.staticTexts["Synthetic popular search result"].firstMatch.waitForExistence(timeout: 8))
    }

    @MainActor func testHistoryDetailTagShowsScopedResultAndReturnsToHistory() {
        let app = launch(cloud: "empty", launchPage: 5, historyTag: true)
        let historyItem = app.staticTexts["Synthetic tag history item"].firstMatch
        let tag = app.buttons["route fixture"].firstMatch
        let result = app.staticTexts["Synthetic history tag result"].firstMatch

        XCTAssertTrue(historyItem.waitForExistence(timeout: 8))
        historyItem.tap()
        XCTAssertTrue(tag.waitForExistence(timeout: 8))
        tag.tap()
        // This result is emitted only for the exact namespaced tag endpoint.
        XCTAssertTrue(result.waitForExistence(timeout: 8))
        back(app)
        XCTAssertTrue(tag.waitForExistence(timeout: 8))
        back(app)
        XCTAssertTrue(historyItem.waitForExistence(timeout: 8))
    }

    // Run only on a dedicated offline simulator with no non-fixture downloads.
    @MainActor func testClearFinishedDownloadsRequiresDestructiveConfirmation() {
        let app = launch(cloud: "empty", localReader: true, clearFinished: true)
        tab("下载", in: app)
        let completed = app.staticTexts["Synthetic cleared download"].firstMatch
        let paused = app.staticTexts["Synthetic preserved download"].firstMatch
        XCTAssertTrue(completed.waitForExistence(timeout: 8))
        XCTAssertTrue(paused.waitForExistence(timeout: 8))
        let actions = app.buttons["downloads-actions"].firstMatch

        func openConfirmation() {
            XCTAssertTrue(actions.waitForExistence(timeout: 5))
            actions.tap()
            let clear = app.buttons["清空已完成"].firstMatch
            XCTAssertTrue(clear.waitForExistence(timeout: 5))
            clear.tap()
            XCTAssertTrue(app.staticTexts["删除 1 个已完成的下载？"].firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["删除记录和文件"].firstMatch.exists)
        }

        openConfirmation()
        let cancel = app.buttons["取消"].firstMatch
        if cancel.exists { cancel.tap() }
        else {
            // iPad SwiftUI popover omits Cancel; outside-tap is dismissal.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.10, dy: 0.85)).tap()
        }
        XCTAssertTrue(completed.exists)
        XCTAssertTrue(paused.exists)
        openConfirmation()
        app.buttons["删除记录和文件"].firstMatch.tap()
        XCTAssertTrue(completed.waitForNonExistence(timeout: 8))
        XCTAssertTrue(paused.exists)
    }

    // Local written fixture recordings only. No destructive confirmation is accepted.
    @MainActor func testDownloadCategoryAndTitleOrderScopeSelectAll() {
        continueAfterFailure = false
        let app = launch(cloud: "empty", localReader: true, downloadSort: true)
        tab("下载", in: app)
        let zebra = app.staticTexts["Sort Fixture Zebra"].firstMatch
        let apple = app.staticTexts["Sort Fixture Apple"].firstMatch
        XCTAssertTrue(zebra.waitForExistence(timeout: 8))
        XCTAssertTrue(apple.exists)
        let actions = app.buttons["downloads-actions"].firstMatch

        func tapMenu(_ name: String) {
            let action = app.buttons[name].firstMatch
            if !action.waitForExistence(timeout: 4) {
                attachHierarchy(app, note: "Missing downloads menu action: " + name)
            }
            XCTAssertTrue(action.exists)
            action.tap()
        }

        actions.tap()
        tapMenu("排序：默认顺序")
        // Depending on the OS the picker is a submenu or its options are inlined.
        let sortBy = app.buttons["排序依据"].firstMatch
        if sortBy.exists { sortBy.tap() }
        tapMenu("标题")
        XCTAssertTrue(apple.waitForExistence(timeout: 6))
        XCTAssertLessThan(apple.frame.minY, zebra.frame.minY)

        actions.tap()
        let category = app.buttons["downloads-category"].firstMatch
        XCTAssertTrue(category.waitForExistence(timeout: 5))
        category.tap()
        let categoryOptions = app.buttons["画廊分类"].firstMatch
        if categoryOptions.exists && categoryOptions.isHittable { categoryOptions.tap() }
        tapMenu("Manga")
        XCTAssertTrue(apple.waitForNonExistence(timeout: 6))
        XCTAssertTrue(zebra.exists)
        if app.buttons["Manga"].firstMatch.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.10)).tap()
        }

        actions.tap()
        tapMenu("批量操作")
        actions.tap()
        tapMenu("全选")
        actions.tap()
        tapMenu("批量删除 (1)")
        XCTAssertTrue(app.staticTexts["确认删除 1 个下载？"].firstMatch.waitForExistence(timeout: 5))
        let cancel = app.buttons["取消"].firstMatch
        if cancel.exists { cancel.tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.10, dy: 0.85)).tap() }
        XCTAssertTrue(zebra.exists)
    }

    @MainActor func testDownloadedReaderPageJumpAndReopenRetainsProgress() {
        let app = launch(cloud: "empty", localReader: true)
        openSynthetic(app)
        let read = app.buttons["阅读"].firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 8))
        read.tap()

        let pages = app.buttons["reader-pages"]
        XCTAssertTrue(pages.waitForExistence(timeout: 8))
        pages.tap()
        XCTAssertTrue(app.navigationBars["跳转到第 1 页"].waitForExistence(timeout: 5))
        app.buttons["2"].tap()

        // Reopening the grid proves the logical reading position changed.
        if !pages.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(pages.waitForExistence(timeout: 5))
        pages.tap()
        XCTAssertTrue(app.navigationBars["跳转到第 2 页"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        app.buttons["reader-close"].tap()
        back(app)
        openSynthetic(app)

        let resume = app.buttons["继续阅读"].firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 8))
        resume.tap()
        if !pages.waitForExistence(timeout: 3) {
            let hud = app.staticTexts["2 / 3"].firstMatch
            if !hud.waitForExistence(timeout: 4) { attachHierarchy(app, note: "Reader reopen did not show page 2") }
            XCTAssertTrue(hud.exists)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(pages.waitForExistence(timeout: 5))
        pages.tap()
        XCTAssertTrue(app.navigationBars["跳转到第 2 页"].waitForExistence(timeout: 5))
    }

    @MainActor func testSuccessfulEmptyCloudAndLocalFavoriteReopen() { checkFlow(cloud: "empty") }
    @MainActor func testCloudFailureStillShowsLocalAndStableHeader() { checkFlow(cloud: "failure") }
    @MainActor func testMixedLocalCloudAndNavigation() { checkFlow(cloud: "one") }
}
#endif
