import Foundation
import SwiftSoup
import EhModels

// MARK: - GalleryDetailParser (对应 Android GalleryDetailParser.java)
// 解析画廊详情页面 HTML → GalleryDetail

public enum GalleryDetailParser {

    // MARK: - 正则表达式

    /// 详情页 URL: /g/{gid}/{token}/
    private static let detailUrlRegex = try! NSRegularExpression(
        pattern: #"https?://(?:e-hentai|exhentai)\.org/g/(\d+)/([0-9a-f]+)"#
    )

    /// 关键 JS 变量: gid, token, apiuid, apikey (对应 Android PATTERN_DETAIL)
    private static let detailJsRegex = try! NSRegularExpression(
        pattern: #"var gid = (\d+);.+?var token = "([a-f0-9]+)";.+?var apiuid = ([\-\d]+);.+?var apikey = "([a-f0-9]+)""#,
        options: [.dotMatchesLineSeparators]
    )

    /// Torrent URL + count (对应 Android PATTERN_TORRENT)
    private static let torrentRegex = try! NSRegularExpression(
        pattern: #"<a[^<>]*onclick="return popUp\('([^']+)'[^)]+\)">Torrent Download \((\d+)\)</a>"#
    )

    /// Archive URL (对应 Android PATTERN_ARCHIVE)
    private static let archiveRegex = try! NSRegularExpression(
        pattern: #"<a[^<>]*onclick="return popUp\('([^']+)'[^)]+\)">Archive Download</a>"#
    )

    /// 评分数值: Average: X.XX
    private static let averageRatingRegex = try! NSRegularExpression(
        pattern: #"Average:\s*([\d.]+)"#
    )

    /// 评分人数: X ratings
    private static let ratingCountRegex = try! NSRegularExpression(
        pattern: #"(\d+)\s+ratings?"#
    )

    /// 收藏人数: X times
    private static let favCountRegex = try! NSRegularExpression(
        pattern: #"(\d+)\s+times"#
    )

    /// 评论 ID: comment_\d+
    private static let commentIdRegex = try! NSRegularExpression(
        pattern: #"comment_(\d+)"#
    )

    /// 页面 JS 变量提取页数
    private static let pagesBodyRegex = try! NSRegularExpression(
        pattern: #"var pages = (\d+)"#
    )

    /// 错误文本: <div class="d"><p>...</p>
    private static let errorRegex = try! NSRegularExpression(
        pattern: #"<div class="d">\n<p>([^<]+)</p>"#
    )

    // MARK: - 特殊内容检测字符串 (对应 Android 三种异常)
    private static let offensiveString = "<p>(And if you choose to ignore this warning, you lose all rights to complain about it in the future.)</p>"
    private static let piningString = "<p>This gallery is pining for the fjords.</p>"
    private static let unavailableString = "This gallery is unavailable"

    // MARK: - 解析入口

    /// 解析画廊详情页面 HTML (对齐 Android GalleryDetailParser.parse)
    public static func parse(_ html: String) throws -> GalleryDetail {

        // 1. 特殊状态检测 (对应 Android 前置抛异常)
        if html.contains(offensiveString) {
            throw DetailParseError.offensive
        }
        if html.contains(piningString) {
            throw DetailParseError.pining
        }
        if html.contains(unavailableString) {
            throw DetailParseError.galleryUnavailable
        }

        // 2. 服务端错误文本 <div class="d"><p>...</p>
        let fullRange = NSRange(html.startIndex..., in: html)
        if let errMatch = errorRegex.firstMatch(in: html, range: fullRange),
           let msgRange = Range(errMatch.range(at: 1), in: html) {
            throw DetailParseError.serverMessage(String(html[msgRange]))
        }

        let doc = try SwiftSoup.parse(html)
        var detail = GalleryDetail()

        // 3. 从内联 JS 提取 gid / token / apiUid / apiKey (对应 Android PATTERN_DETAIL)
        if let match = detailJsRegex.firstMatch(in: html, range: fullRange) {
            if let r = Range(match.range(at: 1), in: html) { detail.info.gid = Int64(html[r]) ?? 0 }
            if let r = Range(match.range(at: 2), in: html) { detail.info.token = String(html[r]) }
            if let r = Range(match.range(at: 3), in: html) { detail.apiUid = Int64(html[r]) ?? -1 }
            if let r = Range(match.range(at: 4), in: html) { detail.apiKey = String(html[r]) }
        }

        // 4. Torrent URL + count (对应 Android PATTERN_TORRENT)
        if let tMatch = torrentRegex.firstMatch(in: html, range: fullRange) {
            if let r = Range(tMatch.range(at: 1), in: html) { detail.torrentUrl = unescapeXml(String(html[r])) }
            if let r = Range(tMatch.range(at: 2), in: html) { detail.torrentCount = Int(html[r]) ?? 0 }
        }

        // 5. Archive URL (对应 Android PATTERN_ARCHIVE)
        if let aMatch = archiveRegex.firstMatch(in: html, range: fullRange) {
            if let r = Range(aMatch.range(at: 1), in: html) { detail.archiveUrl = unescapeXml(String(html[r])) }
        }

        // 6. DOM 解析基本信息
        try parseGalleryInfo(doc, detail: &detail)

        // 7. 标签
        detail.tags = try parseTags(doc)

        // 8. 评论 (含 editable/vote 字段)
        let (comments, hasMore) = try parseComments(doc)
        detail.comments = GalleryCommentList(comments: comments, hasMore: hasMore)

        // 9. 预览
        detail.previewSet = try parsePreviews(doc)
        detail.previewPages = try parsePreviewPagesFromDoc(doc, body: html)

        // 10. SpiderInfo (用于阅读器)
        if let pagesMatch = pagesBodyRegex.firstMatch(in: html, range: fullRange),
           let r = Range(pagesMatch.range(at: 1), in: html) {
            detail.spiderInfoPages = Int(html[r]) ?? 0
        }

        // 11. NewVersions (对应 Android #gnd 解析)
        detail.newVersions = parseNewVersions(doc)

        return detail
    }

    // MARK: - 错误类型 (Detail 解析专用)
    public enum DetailParseError: LocalizedError {
        case offensive
        case pining
        case galleryUnavailable
        case serverMessage(String)

        public var errorDescription: String? {
            switch self {
            case .offensive: return "该画廊包含攻击性内容，需确认后访问"
            case .pining: return "该画廊已被删除 (pining for the fjords)"
            case .galleryUnavailable: return "该画廊不可用"
            case .serverMessage(let msg): return msg
            }
        }
    }

    // MARK: - XML 反转义 (对应 Android StringUtils.unescapeXml)
    private static func unescapeXml(_ string: String) -> String {
        string.replacingOccurrences(of: "&amp;", with: "&")
              .replacingOccurrences(of: "&lt;", with: "<")
              .replacingOccurrences(of: "&gt;", with: ">")
              .replacingOccurrences(of: "&quot;", with: "\"")
              .replacingOccurrences(of: "&#39;", with: "'")
    }

    // MARK: - 解析画廊基本信息

    private static func parseGalleryInfo(_ doc: Document, detail: inout GalleryDetail) throws {
        // gid + token from URL
        if let metaLink = try doc.select("link[rel=canonical]").first(),
           let href = try? metaLink.attr("href") {
            let range = NSRange(href.startIndex..., in: href)
            if let match = detailUrlRegex.firstMatch(in: href, range: range) {
                if let gidRange = Range(match.range(at: 1), in: href) {
                    detail.info.gid = Int64(href[gidRange]) ?? 0
                }
                if let tokenRange = Range(match.range(at: 2), in: href) {
                    detail.info.token = String(href[tokenRange])
                }
            }
        }

        // 标题
        if let titleEl = try doc.select("h1#gn").first() {
            detail.info.title = try titleEl.text()
        }
        if let titleJpnEl = try doc.select("h1#gj").first() {
            detail.info.titleJpn = try titleJpnEl.text()
            if detail.info.titleJpn?.isEmpty == true { detail.info.titleJpn = nil }
        }

        // 缩略图
        if let thumbDiv = try doc.select("div#gd1 > div[style]").first() {
            let style = try thumbDiv.attr("style")
            let urlRegex = try! NSRegularExpression(pattern: #"url\(([^)]+)\)"#)
            let range = NSRange(style.startIndex..., in: style)
            if let match = urlRegex.firstMatch(in: style, range: range),
               let urlRange = Range(match.range(at: 1), in: style) {
                detail.info.thumb = String(style[urlRange])
            }
        }

        // 分类
        if let catDiv = try doc.select("div#gdc > div").first() {
            let catText = try catDiv.text()
            detail.info.category = EhCategory.from(string: catText)
        }

        // 上传者
        if let uploaderDiv = try doc.select("div#gdn > a").first() {
            detail.info.uploader = try uploaderDiv.text()
        }

        // 左侧信息栏
        let gdds = try doc.select("div#gdd tr")
        for row in gdds {
            let label = try row.select("td.gdt1").text()
            let value = try row.select("td.gdt2").text()

            if label.contains("Posted") {
                detail.info.posted = value
            } else if label.contains("Pages") {
                // "123 pages"
                let num = value.components(separatedBy: " ").first ?? ""
                detail.info.pages = Int(num) ?? 0
            } else if label.contains("Length") {
                let num = value.components(separatedBy: " ").first ?? ""
                detail.info.pages = Int(num) ?? 0
            } else if label.contains("Parent") {
                if let a = try row.select("td.gdt2 a").first() {
                    detail.parent = try a.attr("href")
                }
            } else if label.contains("Visible") {
                detail.visible = value
            } else if label.contains("Favorited") {
                switch value {
                case "Never":
                    detail.favoriteCount = 0
                case "Once":
                    detail.favoriteCount = 1
                default:
                    let num = value.components(separatedBy: " ").first ?? ""
                    detail.favoriteCount = Int(num) ?? 0
                }
            } else if label.contains("Language") {
                detail.language = value
            } else if label.contains("File Size") {
                detail.size = value
            }
        }

        // 评分 (对应 Android: Not Yet Rated → -1.0)
        if let ratingLabel = try doc.select("td#rating_label").first() {
            let text = try ratingLabel.text().trimmingCharacters(in: .whitespaces)
            if text == "Not Yet Rated" {
                detail.info.rating = -1.0
            } else {
                let range = NSRange(text.startIndex..., in: text)
                if let match = averageRatingRegex.firstMatch(in: text, range: range),
                   let valRange = Range(match.range(at: 1), in: text) {
                    detail.info.rating = Float(text[valRange]) ?? 0
                }
            }
        }

        if let ratingCount = try doc.select("td#rating_count").first() {
            let text = try ratingCount.text()
            detail.ratingCount = Int(text) ?? 0
        }

        // isFavorited + favoriteName (对应 Android #gdf 解析)
        if let gdf = try doc.select("#gdf").first() {
            let text = try gdf.text().trimmingCharacters(in: .whitespaces)
            detail.isFavorited = text != "Add to Favorites"
            if text == "Add to Favorites" {
                detail.info.favoriteName = nil
                detail.info.favoriteSlot = -1
            } else {
                detail.info.favoriteName = text
                detail.info.favoriteSlot = 0
            }
        }
    }

    // MARK: - 解析新版本 (对应 Android #gnd 解析)

    private static func parseNewVersions(_ doc: Document) -> [NewVersion] {
        guard let gnd = try? doc.select("#gnd").first() else { return [] }

        var versions: [NewVersion] = []
        let textNodes = gnd.textNodes()

        for child in gnd.children().array() {
            guard let href = try? child.attr("href"), !href.isEmpty else { continue }

            let name = (try? child.text()) ?? ""
            var posted = ""
            // Android: textNodes.get(versionList.size()) — 每个成功版本对应一个文本节点
            if versions.count < textNodes.count {
                posted = textNodes[versions.count].text().trimmingCharacters(in: .whitespaces)
            }

            // 从 URL 提取 gid/token
            var gid: Int64 = 0
            var token = ""
            let range = NSRange(href.startIndex..., in: href)
            if let match = detailUrlRegex.firstMatch(in: href, range: range) {
                if let r = Range(match.range(at: 1), in: href) { gid = Int64(href[r]) ?? 0 }
                if let r = Range(match.range(at: 2), in: href) { token = String(href[r]) }
            }

            versions.append(NewVersion(gid: gid, token: token, name: name, posted: posted))
        }

        return versions
    }

    // MARK: - 解析预览页数 (对应 Android parsePreviewPages(Document, String))

    private static func parsePreviewPagesFromDoc(_ doc: Document, body: String) throws -> Int {
        // Android: document.getElementsByClass("ptt").first().child(0).child(0).children()
        // → table.ptt > tbody > tr > [td...], 取倒数第 2 个 td 的文本
        guard let ptt = try doc.select(".ptt").first() else { return 0 }
        let tds = try ptt.child(0).child(0).children()
        let count = tds.size()
        guard count >= 2 else { return 0 }
        return Int(try tds.get(count - 2).text()) ?? 0
    }

    // MARK: - 解析标签

    private static func parseTags(_ doc: Document) throws -> [GalleryTagGroup] {
        var tagGroups: [GalleryTagGroup] = []

        let tagRows = try doc.select("div#taglist > table > tbody > tr")
        for row in tagRows {
            let namespace = try row.select("td.tc").text().trimmingCharacters(in: .init(charactersIn: ":"))
            let tags = try row.select("td > div > a").eachText()
            if !namespace.isEmpty {
                tagGroups.append(GalleryTagGroup(groupName: namespace, tags: tags))
            }
        }

        return tagGroups
    }

    // MARK: - 解析评论 (对应 Android GalleryDetailParser.parseComments)

    /// 评论日期格式: "dd MMMM yyyy, HH:mm"
    private static let commentDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd MMMM yyyy, HH:mm"
        return formatter
    }()

    private static func parseComments(_ doc: Document) throws -> ([GalleryComment], Bool) {
        var comments: [GalleryComment] = []

        // Android: document.getElementById("cdiv").getElementsByClass("c1")
        guard let cdiv = try doc.select("#cdiv").first() else {
            return ([], false)
        }

        let c1Elements = try cdiv.select(".c1")
        for element in c1Elements {
            var comment = GalleryComment()

            // 评论 ID: 从前一个兄弟元素的 name 属性获取 "c{id}"
            if let prevSibling = try element.previousElementSibling(),
               let name = try? prevSibling.attr("name"), !name.isEmpty {
                // name 格式: "c12345"
                let idStr = name.dropFirst() // 去掉 "c"
                comment.id = Int64(idStr) ?? 0
            }

            // Editable / Vote (对应 Android c4 children 遍历)
            if let c4 = try element.select(".c4").first() {
                for child in c4.children().array() {
                    let text = try child.text()
                    switch text {
                    case "Vote+":
                        comment.voteUpAble = true
                        let style = try child.attr("style").trimmingCharacters(in: .whitespaces)
                        comment.voteUpEd = !style.isEmpty
                    case "Vote-":
                        comment.voteDownAble = true
                        let style = try child.attr("style").trimmingCharacters(in: .whitespaces)
                        comment.voteDownEd = !style.isEmpty
                    case "Edit":
                        comment.editable = true
                    default:
                        break
                    }
                }
            }

            // 分数: c5 的第一个子元素文本
            if let c5 = try element.select(".c5").first(),
               let scoreSpan = try c5.select("span").first() {
                comment.score = Int(try scoreSpan.text()) ?? 0
            }

            // 时间和用户: 从 c3 解析
            if let c3 = try element.select(".c3").first() {
                // 时间: c3 的 ownText，格式 "Posted on dd MMMM yyyy, HH:mm by:" 或 "Posted on dd MMMM yyyy, HH:mm"
                var timeText = c3.ownText()
                if timeText.hasPrefix("Posted on ") {
                    timeText = String(timeText.dropFirst("Posted on ".count))
                }
                if timeText.hasSuffix(" by:") {
                    timeText = String(timeText.dropLast(" by:".count))
                }
                if let date = commentDateFormatter.date(from: timeText) {
                    comment.time = date
                } else {
                    comment.time = Date()
                }

                // 用户: 如果 c3 有子元素则取第一个子元素文本，否则从 c4 取
                let c3Children = c3.children().array()
                if !c3Children.isEmpty {
                    comment.user = try c3Children[0].text()
                } else if let c4 = try element.select(".c4").first() {
                    comment.user = try c4.text()
                }
            }

            // 评论内容 (HTML): c6
            if let c6 = try element.select(".c6").first() {
                comment.comment = try c6.html()
            }

            // 投票状态 (对应 Android c7)
            if let c7 = try element.select(".c7").first() {
                let text = try c7.text().trimmingCharacters(in: .whitespaces)
                if !text.isEmpty {
                    comment.voteState = text
                }
            }

            // 最后编辑时间 (对应 Android c8)
            if let c8 = try element.select(".c8").first(),
               let firstChild = c8.children().first() {
                let editedText = try firstChild.text()
                if let date = commentDateFormatter.date(from: editedText) {
                    comment.lastEdited = date
                }
            }

            comments.append(comment)
        }

        // 是否有更多评论: 查找 "click to show all" 文本
        let hasMore: Bool
        if let chd = try cdiv.select("#chd").first() {
            let text = try chd.text()
            hasMore = text.contains("click to show all")
        } else {
            hasMore = false
        }

        return (comments, hasMore)
    }

    // MARK: - 解析预览 (对应 Android GalleryDetailParser.parsePreview)
    
    // 预览正则表达式 (与 Android 完全对应)
    // 大图预览新版 (0 0 表示无偏移)
    private static let largePreviewNewRegex = try! NSRegularExpression(
        pattern: #"<a href="(.+?)">[^<>]*<div title="Page (\d+):[^<>]*\((.+?)\)[^<>]*0 0[^<>]*>"#,
        options: []
    )
    // 大图预览旧版 (div.gdtl)
    private static let largePreviewRegex = try! NSRegularExpression(
        pattern: #"<div class="gdtl".+?<a href="(.+?)"><img alt="([\d,]+)".+?src="(.+?)""#,
        options: [.dotMatchesLineSeparators]
    )
    // 小预览 (有 xOffset)
    private static let smallPreviewRegex = try! NSRegularExpression(
        pattern: #"<a href="(.+?)">[^<>]*<div[^<>]*title="Page (\d+):[^<>]*width:(\d+)[^<>]*height:(\d+)[^<>]*\((.+?)\)[^<>]*-(\d+)px[^<>]*>"#,
        options: []
    )
    // 小预览带标签 (有 xOffset)
    private static let smallPreviewWithLabelRegex = try! NSRegularExpression(
        pattern: #"<a href="(.+?)">[^<>]*<div>[^<>]*<div[^<>]*title="Page (\d+):[^<>]*width:(\d+)[^<>]*height:(\d+)[^<>]*\((.+?)\)[^<>]*-(\d+)px[^<>]*>"#,
        options: []
    )
    // 普通预览新版 (无 xOffset)
    private static let normalPreviewNewRegex = try! NSRegularExpression(
        pattern: #"<a href="(.+?)">[^<>]*<div[^<>]*title="Page (\d+):[^<>]*width:(\d+)[^<>]*height:(\d+)[^<>]*\((.+?)\)[^<>]*"></div>[^<>]*</a>"#,
        options: []
    )
    // 普通预览新版带标签 (无 xOffset)
    private static let normalPreviewNewWithLabelRegex = try! NSRegularExpression(
        pattern: #"<a href="(.+?)">[^<>]*<div>[^<>]*<div[^<>]*title="Page (\d+):[^<>]*width:(\d+)[^<>]*height:(\d+)[^<>]*\((.+?)\)[^<>]*">"#,
        options: []
    )
    // 旧版普通预览 (GDTM)
    private static let normalPreviewOldRegex = try! NSRegularExpression(
        pattern: #"<div class="gdtm"[^<>]*><div[^<>]*width:(\d+)[^<>]*height:(\d+)[^<>]*\((.+?)\)[^<>]*-(\d+)px[^<>]*><a[^<>]*href="(.+?)"[^<>]*><img alt="([\d,]+)""#,
        options: []
    )

    private static func parsePreviews(_ doc: Document) throws -> PreviewSet {
        // 获取 HTML 字符串用于正则匹配
        let html = try doc.html()
        
        // 先尝试获取 gt200 或 gt100 区域的 HTML (安卓的方式)
        var targetHtml = html
        if let gt200 = try doc.select(".gt200").first() {
            targetHtml = try gt200.html()
        } else if let gt100 = try doc.select(".gt100").first() {
            targetHtml = try gt100.html()
        }
        
        let fullRange = NSRange(targetHtml.startIndex..., in: targetHtml)
        
        // 1. 尝试解析大图预览 (新版)
        var largePreviews: [LargePreview] = []
        for match in largePreviewNewRegex.matches(in: targetHtml, range: fullRange) {
            guard let pageUrlRange = Range(match.range(at: 1), in: targetHtml),
                  let pageRange = Range(match.range(at: 2), in: targetHtml),
                  let imageUrlRange = Range(match.range(at: 3), in: targetHtml) else { continue }
            
            let pageUrl = String(targetHtml[pageUrlRange])
            let page = Int(targetHtml[pageRange]) ?? 0
            let imageUrl = String(targetHtml[imageUrlRange])
            
            largePreviews.append(LargePreview(position: page - 1, imageUrl: imageUrl, pageUrl: pageUrl))
        }
        
        // 2. 如果新版没有结果，尝试旧版大图预览
        if largePreviews.isEmpty {
            for match in largePreviewRegex.matches(in: targetHtml, range: fullRange) {
                guard let pageUrlRange = Range(match.range(at: 1), in: targetHtml),
                      let pageRange = Range(match.range(at: 2), in: targetHtml),
                      let imageUrlRange = Range(match.range(at: 3), in: targetHtml) else { continue }
                
                let pageUrl = String(targetHtml[pageUrlRange])
                let pageStr = String(targetHtml[pageRange]).replacingOccurrences(of: ",", with: "")
                let page = Int(pageStr) ?? 0
                let imageUrl = String(targetHtml[imageUrlRange])
                
                largePreviews.append(LargePreview(position: page - 1, imageUrl: imageUrl, pageUrl: pageUrl))
            }
        }
        
        if !largePreviews.isEmpty {
            return .large(largePreviews)
        }
        
        // 3. 尝试解析普通预览
        var normalPreviews: [NormalPreview] = []
        
        // 尝试小预览 (有 xOffset)
        for match in smallPreviewRegex.matches(in: targetHtml, range: fullRange) {
            guard let pageUrlRange = Range(match.range(at: 1), in: targetHtml),
                  let pageRange = Range(match.range(at: 2), in: targetHtml),
                  let widthRange = Range(match.range(at: 3), in: targetHtml),
                  let heightRange = Range(match.range(at: 4), in: targetHtml),
                  let imageUrlRange = Range(match.range(at: 5), in: targetHtml),
                  let xOffsetRange = Range(match.range(at: 6), in: targetHtml) else { continue }
            
            let pageUrl = String(targetHtml[pageUrlRange])
            let page = Int(targetHtml[pageRange]) ?? 0
            let width = Int(targetHtml[widthRange]) ?? 0
            let height = Int(targetHtml[heightRange]) ?? 0
            let imageUrl = String(targetHtml[imageUrlRange])
            let xOffset = Int(targetHtml[xOffsetRange]) ?? 0
            
            normalPreviews.append(NormalPreview(
                position: page - 1,
                imageUrl: imageUrl,
                pageUrl: pageUrl,
                offsetX: xOffset,
                clipWidth: width,
                clipHeight: height
            ))
        }
        
        // 如果没有结果，尝试带标签的小预览
        if normalPreviews.isEmpty {
            for match in smallPreviewWithLabelRegex.matches(in: targetHtml, range: fullRange) {
                guard let pageUrlRange = Range(match.range(at: 1), in: targetHtml),
                      let pageRange = Range(match.range(at: 2), in: targetHtml),
                      let widthRange = Range(match.range(at: 3), in: targetHtml),
                      let heightRange = Range(match.range(at: 4), in: targetHtml),
                      let imageUrlRange = Range(match.range(at: 5), in: targetHtml),
                      let xOffsetRange = Range(match.range(at: 6), in: targetHtml) else { continue }
                
                let pageUrl = String(targetHtml[pageUrlRange])
                let page = Int(targetHtml[pageRange]) ?? 0
                let width = Int(targetHtml[widthRange]) ?? 0
                let height = Int(targetHtml[heightRange]) ?? 0
                let imageUrl = String(targetHtml[imageUrlRange])
                let xOffset = Int(targetHtml[xOffsetRange]) ?? 0
                
                normalPreviews.append(NormalPreview(
                    position: page - 1,
                    imageUrl: imageUrl,
                    pageUrl: pageUrl,
                    offsetX: xOffset,
                    clipWidth: width,
                    clipHeight: height
                ))
            }
        }
        
        // 如果没有结果，尝试普通预览新版 (无 xOffset)
        if normalPreviews.isEmpty {
            for match in normalPreviewNewRegex.matches(in: targetHtml, range: fullRange) {
                guard let pageUrlRange = Range(match.range(at: 1), in: targetHtml),
                      let pageRange = Range(match.range(at: 2), in: targetHtml),
                      let widthRange = Range(match.range(at: 3), in: targetHtml),
                      let heightRange = Range(match.range(at: 4), in: targetHtml),
                      let imageUrlRange = Range(match.range(at: 5), in: targetHtml) else { continue }
                
                let pageUrl = String(targetHtml[pageUrlRange])
                let page = Int(targetHtml[pageRange]) ?? 0
                let width = Int(targetHtml[widthRange]) ?? 0
                let height = Int(targetHtml[heightRange]) ?? 0
                let imageUrl = String(targetHtml[imageUrlRange])
                
                normalPreviews.append(NormalPreview(
                    position: page - 1,
                    imageUrl: imageUrl,
                    pageUrl: pageUrl,
                    offsetX: 0,
                    clipWidth: width,
                    clipHeight: height
                ))
            }
        }
        
        // 如果没有结果，尝试带标签的普通预览新版
        if normalPreviews.isEmpty {
            for match in normalPreviewNewWithLabelRegex.matches(in: targetHtml, range: fullRange) {
                guard let pageUrlRange = Range(match.range(at: 1), in: targetHtml),
                      let pageRange = Range(match.range(at: 2), in: targetHtml),
                      let widthRange = Range(match.range(at: 3), in: targetHtml),
                      let heightRange = Range(match.range(at: 4), in: targetHtml),
                      let imageUrlRange = Range(match.range(at: 5), in: targetHtml) else { continue }
                
                let pageUrl = String(targetHtml[pageUrlRange])
                let page = Int(targetHtml[pageRange]) ?? 0
                let width = Int(targetHtml[widthRange]) ?? 0
                let height = Int(targetHtml[heightRange]) ?? 0
                let imageUrl = String(targetHtml[imageUrlRange])
                
                normalPreviews.append(NormalPreview(
                    position: page - 1,
                    imageUrl: imageUrl,
                    pageUrl: pageUrl,
                    offsetX: 0,
                    clipWidth: width,
                    clipHeight: height
                ))
            }
        }
        
        // 如果没有结果，尝试旧版 GDTM 格式
        if normalPreviews.isEmpty {
            for match in normalPreviewOldRegex.matches(in: targetHtml, range: fullRange) {
                guard let widthRange = Range(match.range(at: 1), in: targetHtml),
                      let heightRange = Range(match.range(at: 2), in: targetHtml),
                      let imageUrlRange = Range(match.range(at: 3), in: targetHtml),
                      let xOffsetRange = Range(match.range(at: 4), in: targetHtml),
                      let pageUrlRange = Range(match.range(at: 5), in: targetHtml),
                      let pageRange = Range(match.range(at: 6), in: targetHtml) else { continue }
                
                let pageUrl = String(targetHtml[pageUrlRange])
                let pageStr = String(targetHtml[pageRange]).replacingOccurrences(of: ",", with: "")
                let page = Int(pageStr) ?? 0
                let width = Int(targetHtml[widthRange]) ?? 0
                let height = Int(targetHtml[heightRange]) ?? 0
                let imageUrl = String(targetHtml[imageUrlRange])
                let xOffset = Int(targetHtml[xOffsetRange]) ?? 0
                
                normalPreviews.append(NormalPreview(
                    position: page - 1,
                    imageUrl: imageUrl,
                    pageUrl: pageUrl,
                    offsetX: xOffset,
                    clipWidth: width,
                    clipHeight: height
                ))
            }
        }
        
        if !normalPreviews.isEmpty {
            return .normal(normalPreviews)
        }
        
        return .normal([])
    }

    // MARK: - 解析 API 参数

    // MARK: - Public Convenience (接受 HTML 字符串，供 EhAPI 调用)

    /// 解析评论 (从 HTML 字符串) — commentGallery API 返回值
    public static func parseComments(_ html: String) throws -> GalleryCommentList {
        let doc = try SwiftSoup.parse(html)
        let (comments, hasMore) = try parseComments(doc)
        return GalleryCommentList(comments: comments, hasMore: hasMore)
    }

    /// 解析预览 (从 HTML 字符串) — getPreviewSet API 返回值
    public static func parsePreviews(_ html: String) throws -> PreviewSet {
        let doc = try SwiftSoup.parse(html)
        return try parsePreviews(doc)
    }

    /// 解析预览页数 (从 HTML 字符串) — getPreviewSet API 返回值
    public static func parsePreviewPages(_ html: String) throws -> Int {
        let doc = try SwiftSoup.parse(html)
        // 尝试从分页控件中获取总页数 (ptb table)
        if let lastPageLink = try doc.select("table.ptb td:last-child > a[href]").first(),
           let href = try? lastPageLink.attr("href"),
           let url = URLComponents(string: href),
           let pageParam = url.queryItems?.first(where: { $0.name == "p" })?.value {
            return (Int(pageParam) ?? 0) + 1
        }

        let pttTds = try doc.select("table.ptb td")
        if pttTds.size() > 2 {
            let secondLast = pttTds.get(pttTds.size() - 2)
            let text = try secondLast.text()
            return Int(text) ?? 0
        }

        return 0
    }

    /// 从 HTML 提取 apiUid 和 apiKey (用于评分等 API)
    /// Android: var gid = (\d+);.+?var apiuid = ([\-\d]+);.+?var apikey = "([a-f0-9]+)"
    private static let apiParamsRegex = try! NSRegularExpression(
        pattern: #"var apiuid = ([\-\d]+);.+?var apikey = \"([a-f0-9]+)\""#,
        options: [.dotMatchesLineSeparators]
    )

    public static func parseApiParams(from html: String) -> (apiUid: Int64, apiKey: String)? {
        let range = NSRange(html.startIndex..., in: html)
        guard let match = apiParamsRegex.firstMatch(in: html, range: range) else {
            return nil
        }

        guard let uidRange = Range(match.range(at: 1), in: html),
              let keyRange = Range(match.range(at: 2), in: html) else {
            return nil
        }

        let apiUid = Int64(html[uidRange]) ?? -1
        let apiKey = String(html[keyRange])

        return (apiUid, apiKey)
    }
}
