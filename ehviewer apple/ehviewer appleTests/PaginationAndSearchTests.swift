//
//  PaginationAndSearchTests.swift
//  ehviewer appleTests
//
//  覆盖 issue #8 的两个回归点:
//    - 问题一: 列表分页游标解析 (searchnav / ptt 两种模式) —— hasMore 判定依赖 pages 的正负
//    - 问题三: 高级搜索最低评分 (f_sr / f_srdd) 必须出现在 URL 里
//
//  HTML 片段取自 Android EhViewer 的解析器测试资源
//  (app/src/test/resources/.../GalleryListParserNew.html)，保证与安卓版行为一致。
//

import Foundation
import Testing
import EhModels
import EhParser
@testable import ehviewer_apple

struct PaginationAndSearchTests {

    // MARK: - 分页解析 (issue #8 问题一)

    /// 现行 E-Hentai 版式: 无 .ptt，用 .searchnav 里的 #uprev / #unext 游标翻页
    /// 解析器必须把 pages 置为 -1 —— GalleryListView 靠 `pages < 0` 区分两种分页模式
    @Test func searchNavPaginationUsesNextHref() throws {
        let html = """
        <html><body>
        <div class="searchnav">
            <div><span id="ufirst">&lt;&lt; First</span></div>
            <div><span id="uprev">&lt; Prev</span></div>
            <div><a id="unext" href="https://e-hentai.org/?next=2370115">Next &gt;</a></div>
            <div><a id="ulast" href="https://e-hentai.org/?prev=1">Last &gt;&gt;</a></div>
        </div>
        </body></html>
        """

        let result = try GalleryListParser.parse(html)

        #expect(result.pages == -1, "searchnav 模式必须置 pages = -1")
        #expect(result.nextHref == "https://e-hentai.org/?next=2370115")
        // 首页的 #uprev 是 <span> 没有 href，不能当成"有上一页"
        #expect(result.prevHref == nil)
    }

    /// 末页: #unext 退化成 <span>，没有 href → nextHref 必须是 nil，否则会一直"加载更多"
    @Test func searchNavLastPageHasNoNextHref() throws {
        let html = """
        <html><body>
        <div class="searchnav">
            <div><a id="uprev" href="https://e-hentai.org/?prev=100">&lt; Prev</a></div>
            <div><span id="unext">Next &gt;</span></div>
        </div>
        </body></html>
        """

        let result = try GalleryListParser.parse(html)

        #expect(result.pages == -1)
        #expect(result.nextHref == nil)
        #expect(result.prevHref == "https://e-hentai.org/?prev=100")
    }

    /// 旧版式: .ptt 分页表格。pages 是正数，nextPage 从 ">" 链接里取
    @Test func pttPaginationReportsPageCount() throws {
        let html = """
        <html><body>
        <table class="ptt"><tbody><tr>
            <td><a href="https://e-hentai.org/?page=0">&lt;</a></td>
            <td class="ptds"><a href="https://e-hentai.org/?page=0">1</a></td>
            <td><a href="https://e-hentai.org/?page=1">2</a></td>
            <td><a href="https://e-hentai.org/?page=2">3</a></td>
            <td><a href="https://e-hentai.org/?page=1">&gt;</a></td>
        </tr></tbody></table>
        </body></html>
        """

        let result = try GalleryListParser.parse(html)

        // 倒数第二个 td 是最大页码
        #expect(result.pages == 3)
        #expect(result.nextPage == 1)
        #expect(result.nextHref == "https://e-hentai.org/?page=1")
    }

    /// ptt 末页: ">" 链接回绕到 page=0。
    /// nextHref 仍然非 nil，所以 hasMore 绝不能只看 nextHref —— 否则列表会翻回第一页循环
    @Test func pttLastPageWrapsBackToZero() throws {
        let html = """
        <html><body>
        <table class="ptt"><tbody><tr>
            <td><a href="https://e-hentai.org/?page=1">&lt;</a></td>
            <td><a href="https://e-hentai.org/?page=0">1</a></td>
            <td class="ptds"><a href="https://e-hentai.org/?page=1">2</a></td>
            <td><a href="https://e-hentai.org/?page=0">&gt;</a></td>
        </tr></tbody></table>
        </body></html>
        """

        let result = try GalleryListParser.parse(html)

        #expect(result.pages >= 0, "ptt 模式 pages 必须是非负数")
        #expect(result.nextPage == 0, "末页的下一页链接回绕到 page=0")
        #expect(result.nextHref != nil, "href 仍然存在, 正因如此才必须用 nextPage 判定末页")
    }

    // MARK: - 高级搜索 URL (issue #8 问题三)

    /// 最低评分必须落到 f_sr=on & f_srdd=N (对齐 Android ListUrlBuilder.build)
    @Test func minRatingAppearsInUrl() {
        var builder = ListUrlBuilder()
        builder.mode = .normal
        builder.advanceSearch = ListUrlBuilder.AdvanceSearch.default.rawValue
        builder.minRating = 4

        let url = builder.build(site: .eHentai)

        #expect(url.contains("advsearch=1"))
        #expect(url.contains("f_sr=on"))
        #expect(url.contains("f_srdd=4"))
    }

    /// 页数范围过滤
    @Test func pageRangeAppearsInUrl() {
        var builder = ListUrlBuilder()
        builder.mode = .normal
        builder.advanceSearch = 0
        builder.pageFrom = 10
        builder.pageTo = 50

        let url = builder.build(site: .eHentai)

        #expect(url.contains("f_sp=on"))
        #expect(url.contains("f_spf=10"))
        #expect(url.contains("f_spt=50"))
    }

    /// 未启用高级搜索时不能污染 URL
    @Test func noAdvanceSearchMeansCleanUrl() {
        var builder = ListUrlBuilder()
        builder.mode = .normal
        builder.keyword = "artist:foo"

        let url = builder.build(site: .eHentai)

        #expect(!url.contains("advsearch"))
        #expect(!url.contains("f_sr"))
        #expect(url.contains("f_search="))
    }

    /// 订阅模式指向 /watched (issue #9: 只看订阅标签)
    @Test func subscriptionModeUsesWatchedUrl() {
        var builder = ListUrlBuilder()
        builder.mode = .subscription
        builder.minRating = 3
        builder.advanceSearch = 0

        let url = builder.build(site: .eHentai)

        #expect(url.contains("watched"))
        #expect(url.contains("f_srdd=3"))
    }
}

// MARK: - Browse request seam

struct GalleryListRequestTests {
    private func parameters(_ url: String) throws -> [String: String] {
        let components = try #require(URLComponents(string: url))
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    @Test func queryCompositionDoesNotSplitTitlesOrQuotedTags() {
        let tag = GallerySearchQuery.exactTag("language:synthetic phrase")
        #expect(tag == "language:\"synthetic phrase$\"")
        #expect(GallerySearchQuery.exactTag("plain fixture") == "\"plain fixture$\"")
        #expect(GallerySearchQuery.exactTag(":x") == "\":x$\"")
        #expect(GallerySearchQuery.exactTag("x:") == "\"x:$\"")
        #expect(GallerySearchQuery.fieldQuery(tokens: [tag], text: "  A title with spaces ") == "\(tag) A title with spaces")
        #expect(GallerySearchQuery.tokensAfterSubmitting([tag], text: "  A title with spaces ") == [tag, "A title with spaces"])
        #expect(GallerySearchQuery.tokensAfterSubmitting([tag], text: " \(tag) ") == [tag])
        #expect(GallerySearchQuery.tokensAfterSubmitting([tag], text: "  ") == [tag])
    }

    @Test func keywordAndBlankHomeKeepTheirAppliedFilters() throws {
        let filters = GalleryListRequest.Filters(category: 1, advanceSearch: 3, minRating: 4, pageFrom: 7, pageTo: 20)
        let query = "language:\"synthetic phrase$\" translated"
        let search = GalleryListRequest(source: .search(keyword: query), filters: filters)
        let page = try parameters(search.pageURL(2, site: .eHentai))
        #expect(page["f_search"] == query)
        #expect(page["page"] == "2")
        #expect(page["f_cats"] == "1022")
        #expect(page["f_sname"] == "on")
        #expect(page["f_stags"] == "on")
        #expect(page["f_srdd"] == "4")
        #expect(page["f_spf"] == "7")
        #expect(page["f_spt"] == "20")
        let home = GalleryListRequest(source: .home, filters: filters)
        let homeParameters = try parameters(home.pageURL(0, site: .eHentai))
        #expect(homeParameters["f_search"] == nil)
        #expect(homeParameters["f_srdd"] == "4")
        #expect(search.jumpBaseURL(site: .eHentai) == search.pageURL(0, site: .eHentai))
        #expect(search.dateSeekBaseURL(site: .eHentai) == search.jumpBaseURL(site: .eHentai))
    }

    @Test func browseSourcesKeepLegacyEndpointsAndCursorFallbacks() throws {
        let watched = GalleryListRequest(source: .subscription, filters: .init(mode: .uploader, cacheMode: 2))
        #expect(watched.pageURL(0, site: .exHentai) == "https://exhentai.org/watched")
        #expect(watched.dateSeekBaseURL(site: .exHentai) == nil)
        let popular = GalleryListRequest(source: .popular)
        #expect(popular.pageURL(9, site: .exHentai) == "https://exhentai.org/popular")
        let top = GalleryListRequest(source: .toplist(period: 12))
        #expect(top.pageURL(2, site: .exHentai) == "https://e-hentai.org/toplist.php?tl=12&p=2")
        let tag = GalleryListRequest(source: .tag(keyword: "language:synthetic phrase"))
        let tagURL = tag.pageURL(2, site: .eHentai)
        #expect(URLComponents(string: tagURL)?.path == "/tag/language:synthetic phrase/2")
        #expect(tagURL.contains("synthetic%20phrase"))
        let all = GalleryListRequest(source: .favorites(slot: -1))
        #expect(all.pageURL(0, site: .eHentai) == "https://e-hentai.org/favorites.php?page=0")
        let favorite = GalleryListRequest(source: .favorites(slot: 4), favoriteKeyword: "synthetic title")
        let page = try parameters(favorite.pageURL(1, site: .eHentai))
        #expect(page == ["favcat": "4", "page": "1", "f_search": "synthetic title"])
        let seekURL = try #require(favorite.favoritesDateURL(day: "2026-01-15", site: .eHentai))
        let seek = try parameters(seekURL)
        #expect(seek == ["favcat": "4", "seek": "2026-01-15", "f_search": "synthetic title"])
        #expect(favorite.jumpBaseURL(site: .eHentai) == "https://e-hentai.org/favorites.php?favcat=4")
    }

    @Test func requestSnapshotKeepsItsCacheIdentityWhenNewFiltersAreApplied() {
        var filters = GalleryListRequest.Filters(mode: .subscription, cacheMode: 1, category: 2, advanceSearch: 3, minRating: 4)
        let old = GalleryListRequest(source: .home, filters: filters)
        filters.minRating = 5
        let updated = GalleryListRequest(source: .home, filters: filters)
        #expect(old.cacheKey(page: 0) == "home:1|2|3|4|-1--1:0")
        #expect(updated.cacheKey(page: 0) == "home:1|2|3|5|-1--1:0")
        #expect(old.pageURL(0, site: .eHentai).contains("f_srdd=4"))
        #expect(updated.pageURL(0, site: .eHentai).contains("f_srdd=5"))
    }
}

struct GallerySearchRefillTests {
    private let qualifiers: Set<String> = ["language", "l", "artist", "a"]

    @Test func multiwordAndExplicitQuotesStayInPlainText() {
        for query in ["A title with spaces", "\"A title with spaces\"", "title:A title with spaces"] {
            let restored = GallerySearchQuery.restoredField(query, knownQualifiers: qualifiers)
            #expect(restored.tokens.isEmpty)
            #expect(restored.text == query)
            #expect(restored.submittedQuery == query)
        }
    }

    @Test func leadingQualifiedTagsStayChipsWithoutChangingOrderedText() {
        let tags = ["language:\"synthetic phrase$\"", "a:fixture"]
        let title = "A title with spaces"
        let query = (tags + [title]).joined(separator: " ")
        let restored = GallerySearchQuery.restoredField(query, knownQualifiers: qualifiers)
        #expect(restored.tokens == tags)
        #expect(restored.text == title)
        #expect(restored.submittedQuery == query)
        let afterDeletion = GallerySearchQuery.Field(tokens: [tags[1]], text: restored.text)
        #expect(afterDeletion.submittedQuery == "\(tags[1]) \(title)")

        let desktop = GallerySearchQuery.restoredField(query)
        #expect(desktop.tokens.isEmpty)
        #expect(desktop.text == query)
        #expect(desktop.submittedQuery == query)
    }

    @Test func interleavedUnknownAndUnfinishedTermsStayLiteral() {
        for query in [
            "A title language:chinese",
            "https://example.invalid A title",
            "language:\"unfinished quote",
            "language:chinese  A title",
            "language:chinese\tA title",
        ] {
            let restored = GallerySearchQuery.restoredField(query, knownQualifiers: qualifiers)
            #expect(restored.tokens.isEmpty)
            #expect(restored.text == query)
            #expect(restored.submittedQuery == query)
        }

        let suffix = "A title l:english"
        let query = "language:chinese \(suffix)"
        let restored = GallerySearchQuery.restoredField(query, knownQualifiers: qualifiers)
        #expect(restored.tokens == ["language:chinese"])
        #expect(restored.text == suffix)
        #expect(restored.submittedQuery == query)
    }

    @Test func advancedRequestRetainsDecodedQueryAndFiltersAfterRefill() throws {
        let query = "language:chinese \"A title with spaces\""
        let restored = GallerySearchQuery.restoredField(query, knownQualifiers: qualifiers)
        let filters = GalleryListRequest.Filters(
            category: EhCategory.manga.rawValue, advanceSearch: 0x003,
            minRating: 4, pageFrom: 8, pageTo: 30
        )
        let baseline = GalleryListRequest(source: .search(keyword: query), filters: filters)
        let replayed = GalleryListRequest(source: .search(keyword: restored.submittedQuery), filters: filters)
        let original = try #require(URLComponents(string: baseline.pageURL(0, site: .eHentai)))
        let replay = try #require(URLComponents(string: replayed.pageURL(0, site: .eHentai)))
        let expected = try #require(original.queryItems)
        let parts = try #require(replay.queryItems)
        #expect(parts == expected)
        #expect(parts.first { $0.name == "f_search" }?.value == query)
        #expect(parts.first { $0.name == "f_srdd" }?.value == "4")
        #expect(parts.first { $0.name == "f_spf" }?.value == "8")
        #expect(parts.first { $0.name == "f_spt" }?.value == "30")
    }

    @Test func persistedQuickSearchCategoryChangesOnlyTheCategoryRequestItem() throws {
        let query = "A title language:chinese"
        let category = EhCategory.manga.rawValue
        let saved = GalleryBrowseSearch(query: query, savedCategory: category)
        let unfiltered = GalleryBrowseSearch(query: query)
        #expect(saved != unfiltered)
        #expect(saved.savedCategory == category)
        let original = GalleryListRequest(source: .search(keyword: query), filters: unfiltered.initialFilters)
        let selected = GalleryListRequest(source: .search(keyword: saved.query), filters: saved.initialFilters)
        let baseline = try #require(URLComponents(string: original.pageURL(0, site: .eHentai))?.queryItems)
        let actual = try #require(URLComponents(string: selected.pageURL(0, site: .eHentai))?.queryItems)
        let excluded = EhCategory.all.rawValue & ~category
        #expect(actual.first { $0.name == "f_cats" }?.value == String(excluded))
        #expect(actual.filter { $0.name != "f_cats" } == baseline)
        #expect(selected.cacheKey(page: 0) != original.cacheKey(page: 0))

        for raw in [0, -1, EhCategory.all.rawValue, 1 << 16] {
            let generic = GalleryBrowseSearch(query: query, savedCategory: raw)
            #expect(generic == unfiltered)
            let request = GalleryListRequest(source: .search(keyword: generic.query), filters: generic.initialFilters)
            #expect(request.pageURL(0, site: .eHentai) == original.pageURL(0, site: .eHentai))
        }
        #expect(GalleryBrowseSearch(query: "", savedCategory: category).savedCategory == nil)
    }

    @Test @MainActor func restoredSavedCategoryReachesInjectedListRequest() async throws {
        let category = EhCategory.manga.rawValue
        let query = "language:chinese A title with spaces"
        let saved = GalleryBrowseSearch(query: query, savedCategory: category)
        var capturedURL: String?
        let model = GalleryListViewModel(
            filterGalleries: { _ in 0 },
            listRequest: { url in
                capturedURL = url
                return GalleryListResult()
            },
            initialFilters: saved.initialFilters
        )
        await model.refreshAsync(mode: .search(keyword: saved.query))

        let url = try #require(capturedURL)
        let items = try #require(URLComponents(string: url)?.queryItems)
        #expect(items.first { $0.name == "f_search" }?.value == query)
        #expect(items.first { $0.name == "f_cats" }?.value == String(EhCategory.all.rawValue & ~category))
        #expect(items.first { $0.name == "f_srdd" } == nil)
    }
}

struct GallerySearchEditingTests {
    private let qualifiers: Set<String> = ["language", "l", "artist", "a"]
    private let title = "A title with spaces"
    private let picked = "artist:\"fixture name$\""

    @Test func suggestionKeepsAppliedTitleAndOnlyReplacesAnUnfinishedDraft() {
        let applied = GallerySearchQuery.restoredField(title, knownQualifiers: qualifiers)
        // Restoration can produce suggestions without any edit. The last
        // word of an unchanged applied title is not a draft to replace.
        #expect(applied.queryPickingSuggestion(picked, lastApplied: applied,
                                               unfinishedPrefix: "A title with ") == "\(title) \(picked)")
        let edited = GallerySearchQuery.Field(tokens: [], text: "\(title) a:fix")
        #expect(edited.queryPickingSuggestion(picked, lastApplied: applied,
                                              unfinishedPrefix: "\(title) ") == "\(title) \(picked)")
        let fresh = GallerySearchQuery.Field(tokens: ["l:chinese"], text: "incomplete draft")
        #expect(fresh.queryPickingSuggestion(picked, lastApplied: nil,
                                             unfinishedPrefix: "incomplete ") == "l:chinese \(picked)")
    }

    @Test func pickerKeepsAppliedTermsBeforeNewTagAndFreshDraftAfterIt() {
        let base = "language:chinese \(title)"
        let applied = GallerySearchQuery.restoredField(base, knownQualifiers: qualifiers)
        #expect(applied.queryPickingTag(picked, lastApplied: applied) == "\(base) \(picked)")

        let edited = GallerySearchQuery.Field(tokens: applied.tokens, text: "\(applied.text) trailing draft")
        #expect(edited.queryPickingTag(picked, lastApplied: applied) == "\(base) \(picked) trailing draft")

        let fresh = GallerySearchQuery.Field(tokens: ["language:chinese"], text: "trailing draft")
        #expect(fresh.queryPickingTag(picked, lastApplied: nil) == "language:chinese \(picked) trailing draft")

        let alreadySelected = GallerySearchQuery.restoredField("\(base) \(picked)", knownQualifiers: qualifiers)
        #expect(alreadySelected.queryPickingTag(picked, lastApplied: alreadySelected) == nil)
    }

    @Test func deletingASelectedChipKeepsTheTitleAndOtherTermsInOrder() throws {
        let withoutTitle = GallerySearchQuery.restoredField("language:chinese", knownQualifiers: qualifiers)
        let selected = try #require(withoutTitle.queryPickingTag(picked, lastApplied: withoutTitle))
        let applied = GallerySearchQuery.restoredField("\(selected) \(title)", knownQualifiers: qualifiers)
        #expect(applied.tokens == ["language:chinese", picked])
        let afterDeletion = GallerySearchQuery.Field(
            tokens: applied.tokens.filter { $0 != picked }, text: applied.text
        )
        #expect(afterDeletion.submittedQuery == "language:chinese \(title)")
    }

    @Test func cancelRestoresAppliedChipsAndLiteralInsteadOfDraft() {
        let query = "language:chinese \"\(title)\""
        let applied = GallerySearchQuery.restoredField(query, knownQualifiers: qualifiers)
        let draft = GallerySearchQuery.Field(tokens: applied.tokens, text: "\(applied.text) a:fix")
        #expect(draft != applied)
        let restored = GallerySearchQuery.Field.restoredOnCancel(applied)
        #expect(restored == applied)
        #expect(restored.submittedQuery == query)
        #expect(GallerySearchQuery.Field.restoredOnCancel(nil).submittedQuery.isEmpty)
    }
}

struct GalleryQuickSearchRatingTests {
    private let query = "language:chinese \"A fixture title\""

    private func parameters(_ url: String) throws -> [String: String] {
        let items = try #require(URLComponents(string: url)?.queryItems)
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    @Test func bothPresetRoutesShareTheSameScoreOnlyFilterSemantics() throws {
        let category = EhCategory.manga.rawValue
        let unrated = GalleryBrowseSearch(query: query, savedCategory: category)
        let browseBaseline = try parameters(GalleryListRequest(
            source: .search(keyword: query), filters: unrated.initialFilters
        ).pageURL(0, site: .eHentai))
        let standaloneBaseline = try parameters(unrated.standaloneURL(
            site: .eHentai, storedCategory: category, legacyAdvanced: false
        ))
        #expect(browseBaseline == standaloneBaseline)
        #expect(browseBaseline["f_search"] == query)

        for rating in 2...5 {
            let rated = GalleryBrowseSearch(query: query, savedCategory: category, savedMinimumRating: rating)
            let browse = try parameters(GalleryListRequest(
                source: .search(keyword: rated.query), filters: rated.initialFilters
            ).pageURL(0, site: .eHentai))
            let standalone = try parameters(rated.standaloneURL(
                site: .eHentai, storedCategory: category, legacyAdvanced: false
            ))
            let scoreOnly = ["advsearch": "1", "f_sr": "on", "f_srdd": String(rating)]
            let expected = browseBaseline.merging(scoreOnly) { _, score in score }
            #expect(browse == expected)
            #expect(standalone == expected)
            #expect(rated.initialFilters.advanceSearch == 0)
            #expect(rated != unrated)
        }
    }

    @Test func legacyUnratedAndInvalidRecordsDoNotAddScoreParameters() throws {
        let defaultPreset = GalleryBrowseSearch(query: query)
        let baseline = GalleryListRequest(source: .search(keyword: query), filters: defaultPreset.initialFilters)
            .pageURL(0, site: .eHentai)
        let historical = defaultPreset.standaloneURL(site: .eHentai, storedCategory: 0, legacyAdvanced: false)
        for value: Int? in [nil, 0, -1, 1, 6, Int.max] {
            let legacy = GalleryBrowseSearch(query: query, savedMinimumRating: value)
            #expect(legacy == defaultPreset)
            #expect(!legacy.hasSavedFilters)
            let url = GalleryListRequest(source: .search(keyword: query), filters: legacy.initialFilters)
                .pageURL(0, site: .eHentai)
            #expect(url == baseline)
            let standalone = legacy.standaloneURL(site: .eHentai, storedCategory: 0, legacyAdvanced: false)
            #expect(standalone == historical)
        }
        let standalone = try parameters(defaultPreset.standaloneURL(
            site: .eHentai, storedCategory: 0, legacyAdvanced: true
        ))
        #expect(standalone == ["f_search": query, "advsearch": "1"])
    }
}

struct GalleryTagRouteTests {
    @Test func seedKeepsNamespacedPathAndPagination() {
        let tag = GalleryListRequest.Source.tag(keyword: "artist:route fixture")
        let selected = GalleryListRequest.Source.tagRoute(source: tag, submittedQuery: nil)
        let request = GalleryListRequest(source: selected)
        #expect(URLComponents(string: request.pageURL(0, site: .eHentai))?.path == "/tag/artist:route fixture")
        #expect(URLComponents(string: request.pageURL(2, site: .eHentai))?.path == "/tag/artist:route fixture/2")
    }

    @Test func explicitSearchAndClearMatchTheirOwnRequestModes() {
        let tag = GalleryListRequest.Source.tag(keyword: "artist:route fixture")
        for query in ["artist:route fixture", "some new query"] {
            let edited = GalleryListRequest.Source.tagRoute(source: tag, submittedQuery: query)
            #expect(GalleryListRequest(source: edited).pageURL(0, site: .eHentai) ==
                    GalleryListRequest(source: .search(keyword: query)).pageURL(0, site: .eHentai))
        }
        let cleared = GalleryListRequest.Source.tagRoute(source: tag, submittedQuery: "")
        #expect(GalleryListRequest(source: cleared).pageURL(0, site: .eHentai) ==
                GalleryListRequest(source: .home).pageURL(0, site: .eHentai))
    }
}

struct GalleryAppliedAdvancedBrowseSearchTests {
    private func items(_ url: String) throws -> [String: String] {
        let components = try #require(URLComponents(string: url))
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    @Test func blankRatingIsASeparateResultsRouteAndPreservesPagination() throws {
        let search = GalleryBrowseSearch(query: "  \r\n ", applying: .init(advanceSearch: 3, minRating: 5))
        #expect(search.showsResults)
        #expect(search.query.isEmpty)
        let request = GalleryListRequest(source: .search(keyword: search.query), filters: search.initialFilters)
        let first = try items(request.pageURL(0, site: .eHentai))
        #expect(first["advsearch"] == "1")
        #expect(first["f_sr"] == "on")
        #expect(first["f_srdd"] == "5")
        #expect(first["f_search"] == nil)
        let next = try items(request.pageURL(2, site: .eHentai))
        #expect(next == first.merging(["page": "2"]) { _, page in page })

        let four = GalleryBrowseSearch(query: "", applying: .init(advanceSearch: 3, minRating: 4))
        #expect(four != search)
        let other = GalleryListRequest(source: .search(keyword: four.query), filters: four.initialFilters)
        #expect(other.cacheKey(page: 0) != request.cacheKey(page: 0))
        #expect(other.cacheKey(page: 2) != request.cacheKey(page: 2))
    }

    @Test func emptyPlainSearchAndInactiveOrDefaultOptionsKeepTheOriginalSource() {
        #expect(!GalleryBrowseSearch(query: "").showsResults)
        #expect(!GalleryBrowseSearch(query: "", savedMinimumRating: 5).showsResults)
        #expect(!GalleryBrowseSearch(query: "", applying: .init(advanceSearch: 3)).showsResults)
        #expect(!GalleryBrowseSearch(query: "", applying: .init(minRating: 5, pageFrom: 20)).showsResults)
        #expect(!GalleryBrowseSearch(query: "", applying: .init(mode: .uploader)).showsResults)
        #expect(!GalleryBrowseSearch(query: "", applying: .init(mode: .tag)).showsResults)
        #expect(GalleryBrowseSearch(query: "", applying: .init(category: EhCategory.manga.rawValue)).showsResults)
    }

    @Test func clearingOnlyFiltersKeepsTheSubmittedKeyword() {
        let filters = GalleryListRequest.Filters(advanceSearch: 3, minRating: 5)
        let typed = GalleryBrowseSearch(query: "fixture title", applying: filters)
        #expect(typed.clearingAppliedFilters == .init(query: "fixture title"))
        #expect(typed.clearingAppliedFilters.showsResults)
        let blank = GalleryBrowseSearch(query: "", applying: filters)
        #expect(!blank.clearingAppliedFilters.showsResults)
    }

    @Test func normalizedSnapshotKeepsExplicitOptionsAndUnchangedTextSemantics() throws {
        let search = GalleryBrowseSearch(
            query: "  artist:\"fixture example\"  ",
            applying: .init(category: EhCategory.manga.rawValue, advanceSearch: 0x14, minRating: 5,
                            pageFrom: 20, pageTo: 60)
        )
        let request = GalleryListRequest(source: .search(keyword: search.query), filters: search.initialFilters)
        let params = try items(request.pageURL(1, site: .exHentai))
        #expect(params == [
            "page": "1", "f_cats": String((~EhCategory.manga.rawValue) & 0x3FF),
            "f_search": "artist:\"fixture example\"", "advsearch": "1", "f_sdesc": "on", "f_sto": "on",
            "f_sr": "on", "f_srdd": "5", "f_sp": "on", "f_spf": "20", "f_spt": "60"
        ])
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct StandaloneQuickSearchOwnershipTests {
    private static let query = "synthetic gallery"
    private static let olderCursor = "https://search.invalid/four-next"
    private static let newestCursor = "https://search.invalid/five-next"
    private static let newestPrev = "https://search.invalid/five-prev"

    @Test func delayedFourStarSuccessCannotReplaceFiveStarRowsOrCursor() async {
        let older = HeldQuickSearchResult()
        var requests: [String] = []
        let model = GalleryListViewModel(filterGalleries: { _ in 0 }, listRequest: { url in
            requests.append(url)
            if url == Self.newestCursor { return Self.result(6) }
            if Self.rating(in: url) == "4" { return try await older.request() }
            #expect(Self.rating(in: url) == "5")
            return Self.result(5, previous: Self.newestPrev, next: Self.newestCursor)
        })

        let first = select(4, in: model)
        await older.waitUntilRequested()
        await select(5, in: model).value
        older.finish(.success(Self.result(4, next: Self.olderCursor)))
        await first.value

        #expect(model.galleries.map(\.gid) == [5])
        #expect(model.prevHref == Self.newestPrev)
        #expect(model.nextHref == Self.newestCursor)
        #expect(model.totalPages == -1 && model.hasMore)
        #expect(model.errorMessage == nil && !model.isLoading)
        await model.loadMore(mode: .search(keyword: Self.query))
        #expect(requests.last == Self.newestCursor)
        #expect(model.galleries.map(\.gid) == [5, 6])
    }

    @Test func obsoleteFailureLeavesReplacementLoadingUntilItCompletes() async {
        let older = HeldQuickSearchResult()
        let newest = HeldQuickSearchResult()
        let model = GalleryListViewModel(filterGalleries: { _ in 0 }, listRequest: { url in
            if Self.rating(in: url) == "4" { return try await older.request() }
            #expect(Self.rating(in: url) == "5")
            return try await newest.request()
        })
        let first = select(4, in: model)
        await older.waitUntilRequested()
        let second = select(5, in: model)
        await newest.waitUntilRequested()

        older.finish(.failure(URLError(.timedOut)))
        await first.value
        #expect(model.isLoading && model.errorMessage == nil)
        #expect(model.galleries.isEmpty && model.nextHref == nil)

        newest.finish(.success(Self.result(5, previous: Self.newestPrev, next: Self.newestCursor)))
        await second.value
        #expect(model.galleries.map(\.gid) == [5])
        #expect(model.prevHref == Self.newestPrev && model.nextHref == Self.newestCursor)
        #expect(!model.isLoading && model.errorMessage == nil)
    }

    @Test func oldHrefPageCannotAppendToNewQuickSearch() async {
        let oldPage = HeldQuickSearchResult()
        let model = GalleryListViewModel(filterGalleries: { _ in 0 }, listRequest: { url in
            if url == Self.olderCursor { return try await oldPage.request() }
            if Self.rating(in: url) == "4" { return Self.result(4, next: Self.olderCursor) }
            #expect(Self.rating(in: url) == "5")
            return Self.result(5, previous: Self.newestPrev, next: Self.newestCursor)
        })
        await select(4, in: model).value
        let pagination = Task { await model.loadMore(mode: .search(keyword: Self.query)) }
        await oldPage.waitUntilRequested()
        await select(5, in: model).value

        oldPage.finish(.success(Self.result(46)))
        await pagination.value
        #expect(model.galleries.map(\.gid) == [5])
        #expect(model.prevHref == Self.newestPrev && model.nextHref == Self.newestCursor)
        #expect(!model.isLoading && model.errorMessage == nil && model.hasMore)
    }

    private func select(_ rating: Int, in model: GalleryListViewModel) -> Task<Void, Never> {
        model.applyQuickSearch(GalleryBrowseSearch(query: Self.query, savedMinimumRating: rating),
                               storedCategory: 0, legacyAdvanced: false)
    }

    private static func result(_ id: Int64, previous: String? = nil, next: String? = nil) -> GalleryListResult {
        .init(galleries: [GalleryInfo(gid: id, token: "neutral", title: "Fixture \(id)")],
              pages: -1, prevHref: previous, nextHref: next)
    }

    private static func rating(in url: String) -> String? {
        URLComponents(string: url)?.queryItems?.first(where: { $0.name == "f_srdd" })?.value
    }
}

@MainActor
private final class HeldQuickSearchResult {
    private var response: CheckedContinuation<GalleryListResult, any Error>?
    private var start: CheckedContinuation<Void, Never>?

    func request() async throws -> GalleryListResult {
        try await withCheckedThrowingContinuation {
            response = $0
            start?.resume()
            start = nil
        }
    }

    func waitUntilRequested() async {
        if response == nil { await withCheckedContinuation { start = $0 } }
    }

    func finish(_ result: Result<GalleryListResult, any Error>) {
        response?.resume(with: result)
        response = nil
    }
}


struct TagWorkspaceScopeTests {
    @Test func favoriteCursorAndDateStayWithinOriginalSlotAndBothTags() throws {
        let first = TagWorkspaceOrigin(scope: .cloudFavorites(4), query: "left+right & title")
            .selecting("female:sample one")
        let second = first.descending(into: "group:sample two", extra: "edition", filters: .init())
        let url = try #require(URLComponents(string: second.preservingScope(
            of: "https://e-hentai.org/?favcat=7&f_search=ignore&next=567",
            extra: "", filters: .init(), site: .eHentai)))
        let items = url.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        #expect(url.path == "/favorites.php")
        #expect(value("favcat") == "4")
        #expect(value("st") == "on")
        #expect(value("next") == "567")
        #expect(value("f_search") == "left+right & title edition female:\"sample one$\" group:\"sample two$\"")
        #expect(url.percentEncodedQuery?.contains("%2B") == true)
        let date = second.request(extra: "", filters: .init()).favoritesDateURL(day: "2026-01-07", site: .eHentai)
        #expect(date?.contains("seek=2026-01-07") == true)
        #expect(date?.contains("favcat=4") == true)
        #expect(first.tags == ["female:sample one"])
    }

    @Test func watchedAndInheritedRatingArePreservedWithoutGlobalFallback() throws {
        var filters = GalleryListRequest.Filters.subscriptionSearch
        filters.minRating = 4
        filters.advanceSearch = 0
        let origin = TagWorkspaceOrigin(scope: .watched, query: "existing", filters: filters)
        let query = try #require(URLComponents(string: origin.selecting("artist:sample")
            .request(extra: "another", filters: filters).pageURL(0, site: .eHentai)))
        #expect(query.path == "/watched")
        #expect(query.queryItems?.first { $0.name == "f_search" }?.value == "existing another artist:\"sample$\"")
        #expect(query.queryItems?.first { $0.name == "f_srdd" }?.value == "4")
    }

    @Test func localCandidatesNeverAddRemoteOrBroadenAfterClearingExtra() {
        let good = GalleryInfo(gid: 1, title: "Fixture match", simpleTags: ["a:one", "g:two"])
        let near = GalleryInfo(gid: 2, title: "Fixture partial", simpleTags: ["a:one"])
        let other = GalleryInfo(gid: 3, title: "Fixture excluded", simpleTags: ["a:one two", "g:two"])
        let origin = TagWorkspaceOrigin(scope: .localFavorites, candidates: [good, near, other])
        let first = origin.selecting("artist:one")
        #expect(first.localList(extra: "", filters: .init()).galleries.map(\.gid) == [1, 2])
        let nested = first.descending(into: "group:two", extra: "match", filters: .init())
        #expect(nested.localList(extra: "", filters: .init()).galleries.map(\.gid) == [1])
        #expect(first.localList(extra: "", filters: .init()).galleries.map(\.gid) == [1, 2])
    }
}
