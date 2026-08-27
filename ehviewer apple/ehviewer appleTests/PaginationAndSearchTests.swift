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

import Testing
import EhModels
import EhParser

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
