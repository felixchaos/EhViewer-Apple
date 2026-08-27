//
//  AndroidUpstreamAlignmentTests.swift
//  ehviewer appleTests
//
//  对齐 Android 上游 (xiaojieonly/Ehviewer_CN_SXJ, BiLi_PC_Gamer) 2026-02-12 → 2026-08-21
//  期间协议层的两处变更:
//    - 2026-04-30「种子下载列表添加上传时间」→ TorrentParser 重写 + TorrentInfo.posted
//    - 2026-07-30「添加获取可编辑评论的功能」→ GetEditCommentParser
//  以及「搜索时过滤文本中的换行符」(2026-03-02 / 2026-03-14)。
//
//  HTML 取自上游解析器测试资源 torrentList.html 的真实排版。
//

import Testing
import Foundation
import EhModels
import EhParser

struct AndroidUpstreamAlignmentTests {

    // MARK: - 种子列表

    /// 上游真实排版: `<a` 与 `href` 之间换行、href 后还有 onclick、文件名折行。
    /// 旧正则要求字面量 `<a href="` 且 `> &nbsp; <` 单空格，这种页面一条都解析不出来。
    private static let torrentHTML = """
    <html><body>
    <form method="post" action="https://e-hentai.org/gallerytorrents.php?gid=3906770&amp;t=4d49b5c7bf">
      <div>
        <table style="width:99%">
          <tr>
            <td style="width:180px"><span style="font-weight:bold">Posted:</span>
              <span>2026-04-26 05:14</span></td>
            <td style="width:150px"><span style="font-weight:bold">Size:</span> 252.0 MiB</td>
          </tr>
          <tr>
            <td colspan="5"><span style="font-weight:bold">Uploader:</span> Konazumi</td>
          </tr>
          <tr>
            <td colspan="5"> &nbsp; <a
                    href="https://ehtracker.org/get/3905209/96d5199d.torrent?p=2052868"
                    onclick="document.location='https://ehtracker.org/get/3905209/96d5199d.torrent'; return false">[Uniyaa
                (Ikinari Mojio)] Hatsuiku ga Yokute I Can&#039;t Stop
                Thinking.zip</a></td>
          </tr>
        </table>
      </div>
    </form>
    <form method="post" action="https://e-hentai.org/gallerytorrents.php?gid=3906770&amp;t=4d49b5c7bf">
      <div>
        <table style="width:99%">
          <tr>
            <td style="width:180px"><span style="font-weight:bold">Posted:</span>
              <span>2026-05-02 11:03</span></td>
          </tr>
          <tr>
            <td colspan="5"> &nbsp; <a href="https://ehtracker.org/get/3905209/713846c3.torrent">second.zip</a></td>
          </tr>
        </table>
      </div>
    </form>
    </body></html>
    """

    @Test func torrentParserReadsEveryEntry() {
        let result = TorrentParser.parse(Self.torrentHTML)
        #expect(result.count == 2, "两个 <form> 块应各解析出一条种子")
    }

    /// 上传时间必须和所在的 <form> 块配对 —— 这正是上游按 form 切块的原因
    @Test func torrentParserPairsPostedWithItsOwnBlock() {
        let result = TorrentParser.parse(Self.torrentHTML)
        try? #require(result.count == 2)
        #expect(result.first?.posted == "2026-04-26 05:14")
        #expect(result.last?.posted == "2026-05-02 11:03")
    }

    /// `?p=` 必须去掉，否则种子无法再分发 (对齐 Android)
    @Test func torrentParserStripsPParameter() {
        let result = TorrentParser.parse(Self.torrentHTML)
        #expect(result.first?.url == "https://ehtracker.org/get/3905209/96d5199d.torrent")
        #expect(result.first?.url.contains("?p=") == false)
    }

    /// 折行的文件名要压成单行，HTML 实体要解码
    @Test func torrentParserNormalizesWrappedName() {
        let result = TorrentParser.parse(Self.torrentHTML)
        let name = result.first?.name ?? ""
        #expect(!name.contains("\n"))
        #expect(!name.contains("  "))
        #expect(name.contains("Can't Stop"), "&#039; 应被解码为 '")
        #expect(name.hasSuffix(".zip"))
    }

    @Test func torrentParserReturnsEmptyForUnrelatedPage() {
        #expect(TorrentParser.parse("<html><body>No torrents</body></html>").isEmpty)
    }

    // MARK: - 可编辑评论

    @Test func editCommentParserKeepsRawBBCodeAndNewlines() throws {
        let json = """
        {"comment_id": 987654,
         "editable_comment": "<textarea name=\\"commenttext_edit\\" rows=\\"6\\">第一行\\n[b]加粗[/b]\\n第三行</textarea>"}
        """
        let result = try GetEditCommentParser.parse(Data(json.utf8))

        #expect(result.id == 987654)
        // 关键: 换行和 BBCode 都不能被 HTML 折叠掉
        #expect(result.comment.contains("\n"))
        #expect(result.comment.contains("[b]加粗[/b]"))
        #expect(result.comment.hasPrefix("第一行"))
    }

    @Test func editCommentParserSurfacesServerError() {
        let json = #"{"error": "You cannot edit this comment"}"#
        #expect(throws: (any Error).self) {
            try GetEditCommentParser.parse(Data(json.utf8))
        }
    }

    @Test func editCommentParserRejectsMissingTextarea() {
        let json = #"{"comment_id": 1, "editable_comment": "<div>nope</div>"}"#
        #expect(throws: (any Error).self) {
            try GetEditCommentParser.parse(Data(json.utf8))
        }
    }

    // MARK: - 搜索词换行过滤

    /// 从别处粘贴标签常带 \r\n；上游最终选择**直接删除**而不是替换成空格，
    /// 因为多余空格会被 E-Hentai 当成词分隔符，拆断 `artist:foo` 这类语法
    @Test func keywordSanitizerRemovesNewlinesWithoutAddingSpaces() {
        #expect(ListUrlBuilder.sanitizeKeyword("artist:\nfoo") == "artist:foo")
        #expect(ListUrlBuilder.sanitizeKeyword("a\r\nb") == "ab")
        #expect(ListUrlBuilder.sanitizeKeyword("  \n padded \n ") == "padded")
    }

    /// 清洗必须真的作用到最终 URL 上
    @Test func builtUrlContainsNoEncodedNewline() {
        var builder = ListUrlBuilder()
        builder.mode = .normal
        builder.keyword = "artist:\nfoo"

        let url = builder.build(site: .eHentai)

        // 解码后比对，避开 ":" 编不编码这种与本次改动无关的细节
        let searchValue = URLComponents(string: url)?
            .queryItems?.first { $0.name == "f_search" }?.value
        #expect(searchValue == "artist:foo")

        #expect(!url.contains("%0A"))
        #expect(!url.contains("%0D"))
        #expect(!url.contains("\n"))
    }
}
