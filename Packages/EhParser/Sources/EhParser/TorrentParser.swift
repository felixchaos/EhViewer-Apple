import Foundation
import EhModels

// MARK: - TorrentParser (对应 Android TorrentParser.java)
// 解析种子列表页面 HTML
//
// 对齐上游 2026-04-30「种子下载列表添加上传时间」的重写:
//   - 先按 <form>…</form> 切块，每块一个种子，这样才能把 "Posted:" 和对应的下载链接配对
//   - 三个正则全部启用 DOTALL (.dotMatchesLineSeparators)，因为 EH 的表格是换行排版的
//   - 链接正则放宽: `<td colspan="5">` 后允许任意空白，<a> 的属性段用 [^<]* 而不是 [^<]+
//     (旧写法要求字面量 `> &nbsp; <` 且 href 后必须还有至少一个字符，EH 稍微改一下排版就整列解析不出来)

public enum TorrentParser {

    /// 单个种子块 (对应 Android PATTERN_TORRENT_BLOCK)
    private static let blockPattern = try! NSRegularExpression(
        pattern: #"<form\b[^>]*>.*?</form>"#,
        options: [.dotMatchesLineSeparators]
    )

    /// 上传时间 (对应 Android PATTERN_POSTED)
    private static let postedPattern = try! NSRegularExpression(
        pattern: #"<span[^>]*>\s*Posted:\s*</span>\s*<span>([^<]+)</span>"#,
        options: [.dotMatchesLineSeparators]
    )

    /// 种子链接 + 名称 (对应 Android PATTERN_TORRENT，再放宽一点)
    /// EH 实际输出里 `<a` 和 `href` 之间可能换行、href 后面还跟着 onclick，
    /// 而且长文件名会被折行 —— 所以属性段用 `[^>]*?`，名字用非贪婪的 `.*?` 后再规范化空白
    private static let torrentPattern = try! NSRegularExpression(
        pattern: #"<td colspan="5">\s*&nbsp;\s*<a\b[^>]*?href="([^"]+)"[^>]*>(.*?)</a>"#,
        options: [.dotMatchesLineSeparators]
    )

    /// 连续空白 (含换行) → 单个空格
    private static let whitespaceRun = try! NSRegularExpression(pattern: #"\s+"#)

    /// 解析种子列表
    /// - Returns: TorrentInfo 数组，url 已移除 `?p=` 及其后内容
    public static func parse(_ body: String) -> [TorrentInfo] {
        var result: [TorrentInfo] = []

        let nsBody = body as NSString
        let fullRange = NSRange(location: 0, length: nsBody.length)

        for blockMatch in blockPattern.matches(in: body, range: fullRange) {
            let block = nsBody.substring(with: blockMatch.range)
            let blockRange = NSRange(location: 0, length: (block as NSString).length)

            guard let torrentMatch = torrentPattern.firstMatch(in: block, range: blockRange),
                  let urlRange = Range(torrentMatch.range(at: 1), in: block),
                  let nameRange = Range(torrentMatch.range(at: 2), in: block) else {
                continue
            }

            // 对应 Android: 去掉 "?p=" 及其后内容，使种子可再分发
            var url = ParserUtils.trim(String(block[urlRange]))
            if let pRange = url.range(of: "?p=") {
                url = String(url[..<pRange.lowerBound])
            }
            // 文件名在页面里是折行的，先把换行/缩进压成单空格再解实体
            let name = ParserUtils.trim(collapseWhitespace(String(block[nameRange])))

            var posted = ""
            if let postedMatch = postedPattern.firstMatch(in: block, range: blockRange),
               let postedRange = Range(postedMatch.range(at: 1), in: block) {
                posted = ParserUtils.trim(collapseWhitespace(String(block[postedRange])))
            }

            guard !url.isEmpty else { continue }

            result.append(TorrentInfo(url: url, name: name, posted: posted))
        }

        return result
    }

    private static func collapseWhitespace(_ text: String) -> String {
        let range = NSRange(location: 0, length: (text as NSString).length)
        return whitespaceRun.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
    }
}
