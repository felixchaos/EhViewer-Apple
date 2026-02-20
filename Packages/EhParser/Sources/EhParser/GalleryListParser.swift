import Foundation
import SwiftSoup
import EhModels

// MARK: - GalleryListParser (对应 Android GalleryListParser.java)
// 解析画廊列表页面 HTML → GalleryInfo 数组

public enum GalleryListParser {

    // MARK: - 正则表达式 (从 Android 源码直接移植)

    /// 评分样式正则: background-position:Xpx Ypx (X 决定星数, Y 决定半星)
    nonisolated(unsafe) private static let ratingPattern = /background-position:(-?\d+)px (-?\d+)px/

    /// 缩略图 URL 正则 (内联样式): url(...)
    nonisolated(unsafe) private static let thumbUrlPattern = /url\(([^)]+)\)/

    /// 画廊 URL 正则: /g/{gid}/{token}/
    nonisolated(unsafe) private static let galleryUrlPattern = /\/g\/(\d+)\/([0-9a-f]+)\//

    /// 页数正则
    nonisolated(unsafe) private static let pagesPattern = /(\d+) pages?/

    /// 下一页正则 (从 URL 参数: ?page=N 或 &page=N 或 ?next=N)
    nonisolated(unsafe) private static let nextPagePattern = /[?&]page=(\d+)/

    /// 结果数文本正则 (对应 Android PATTERN_RESULT_COUNT_PAGE)
    nonisolated(unsafe) private static let resultCountPattern = /Showing\s+.*?\s+results?/

    /// 缩略图尺寸正则 (对应 Android PATTERN_THUMB_SIZE)
    nonisolated(unsafe) private static let thumbSizePattern = /height:(\d+)px;width:(\d+)px/

    /// 收藏槽位 RGB 正则 (对应 Android PATTERN_FAVORITE_SLOT)
    nonisolated(unsafe) private static let favoriteSlotPattern = /background-color:rgba\((\d+),(\d+),(\d+),/

    /// 收藏槽位 RGB 颜色映射表 (对应 Android FAVORITE_SLOT_RGB)
    private static let favoriteSlotRGB: [[String]] = [
        ["0", "0", "0"],
        ["240", "0", "0"],
        ["240", "160", "0"],
        ["208", "208", "0"],
        ["0", "128", "0"],
        ["144", "240", "64"],
        ["64", "176", "240"],
        ["0", "0", "240"],
        ["80", "0", "128"],
        ["224", "128", "224"],
    ]

    // MARK: - 解析入口

    /// 解析画廊列表页面 (对应 Android GalleryListParser.parse)
    public static func parse(_ html: String) throws -> GalleryListResult {
        let doc = try SwiftSoup.parse(html)
        var result = GalleryListResult()

        // === 分页 (严格对应 Android 的 ptt / searchnav 双模式) ===
        do {
            if let ptt = try doc.select(".ptt").first() {
                // ptt 模式: 标准分页表格
                let es = ptt.children().first()?.children().first()?.children().array() ?? []
                if es.count >= 2 {
                    result.pages = Int(try es[es.count - 2].text().trimmingCharacters(in: .whitespaces)) ?? 0
                }
                // 最后一个 td (">" 按钮) 中的 <a> href → nextPage + nextHref
                if let lastTd = es.last, let a = try lastTd.select("a").first() {
                    let href = try a.attr("href")
                    if !href.isEmpty {
                        // ★ 保留完整 href (包含 next=TIMESTAMP 等跳页上下文)
                        // 确保 loadMore 能通过 nextHref 继续按日期顺序加载
                        result.nextHref = href
                    }
                    if let match = href.firstMatch(of: nextPagePattern) {
                        result.nextPage = Int(match.1) ?? 0
                    }
                }
                // 第一个 td ("<" 按钮) 中的 <a> href → prevHref
                if let firstTd = es.first, let a = try firstTd.select("a").first() {
                    let href = try a.attr("href")
                    if !href.isEmpty {
                        result.prevHref = href
                    }
                }
            } else if let searchNav = try doc.select(".searchnav").first() {
                // searchnav 模式 (收藏夹等): 无 ptt, 用 prev/next 链接
                result.pages = -1
                result.nextPage = -1

                if let prev = try searchNav.select("#uprev").first() {
                    result.prevHref = try prev.attr("href")
                    if result.prevHref?.isEmpty == true { result.prevHref = nil }
                }
                if let next = try searchNav.select("#unext").first() {
                    result.nextHref = try next.attr("href")
                    if result.nextHref?.isEmpty == true { result.nextHref = nil }
                }

                // 结果数
                if let searchText = try doc.select(".searchtext").first() {
                    let text = try searchText.text()
                    result.resultCount = parseResultCount(text)
                }
            } else {
                // 没有分页元素
                result.pages = 1
            }
        } catch {
            // 分页解析失败时检查特殊情况
            result.noWatchedTags = html.contains("You do not have any watched tags")
            if html.contains("No hits found</p>") {
                result.pages = 0
                result.galleries = []
                return result
            } else if (try? doc.select(".ptt").first()) == nil {
                result.pages = 1
            } else {
                result.pages = Int.max
            }
        }

        // === 画廊列表解析 ===
        var galleries: [GalleryInfo] = []

        // 检查是否为 Minimal/MinimalPlus 还是 Extended 模式
        if let itg = try doc.select(".itg").first() {
            let es: Elements
            if itg.tagName() == "table" {
                // table 模式: compact/extended
                es = try itg.select("> tbody > tr")
            } else {
                // div 模式: thumbnail/minimal
                es = itg.children()
            }

            for element in es {
                // 跳过表头行
                if ((try? element.select("th").size()) ?? 0) > 0 { continue }

                if let info = try? parseTableRow(element), info.gid > 0 {
                    galleries.append(info)
                }
            }
        }

        // Thumbnail 模式回退
        if galleries.isEmpty {
            let thumbDivs = try doc.select("div.gl1t")
            for div in thumbDivs {
                if let info = try? parseThumbDiv(div), info.gid > 0 {
                    galleries.append(info)
                }
            }
        }

        result.galleries = galleries
        return result
    }

    /// 解析结果数文本 (对应 Android 的多种格式)
    private static func parseResultCount(_ text: String) -> String? {
        // "Showing 1-25 of 12,345 results"
        // "Showing results for thousands of galleries"
        let parts = text.split(separator: " ")
        guard parts.count >= 3 else { return nil }

        if parts.count > 3 {
            if parts[1] == "thousands" {
                return "1,000+"
            } else if parts[1] == "about" {
                return parts.count >= 3 ? String(parts[2]) + "+" : nil
            } else {
                // "Showing 1-25 of 12,345 results" → extract "12,345"
                // Find 'of' and take next word
                if let ofIdx = parts.firstIndex(of: "of"), ofIdx + 1 < parts.count {
                    return String(parts[ofIdx + 1])
                }
                return parts.dropFirst().dropLast().joined()
            }
        } else if parts.count == 3 {
            return String(parts[1])
        }
        return nil
    }

    // MARK: - 表格行解析 (Compact / Extended 模式)
    // 严格对应 Android GalleryListParser.parseGalleryInfo()

    private static func parseTableRow(_ row: Element) throws -> GalleryInfo {
        var info = GalleryInfo()

        // 1. 从 .glname 获取 gid, token, title (对应 Android 逻辑)
        if let glname = try row.select(".glname").first() {
            // 先找 glname 内的 <a>, 如果没有则检查父元素是不是 <a>
            var aTag: Element? = try glname.select("a").first()
            if aTag == nil {
                if let parent = glname.parent(), parent.tagName() == "a" {
                    aTag = parent
                }
            }

            // 从 <a> 的 href 提取 gid/token
            if let a = aTag, let href = try? a.attr("href"),
               let match = href.firstMatch(of: galleryUrlPattern) {
                info.gid = Int64(match.1) ?? 0
                info.token = String(match.2)
            }

            // 标题: 找最深层的子元素文本 (Android 逻辑)
            var child = glname
            while let firstChild = child.children().first() {
                child = firstChild
            }
            info.title = try child.text().trimmingCharacters(in: .whitespaces)

            // simpleTags: 从 glname 内的 tbody 解析标签组 (对应 Android glname>tbody)
            if let tbody = try glname.select("tbody").first() {
                var tags: [String] = []
                for tagRow in tbody.children().array() {
                    let children = tagRow.children().array()
                    guard children.count >= 2 else { continue }
                    var namespace = try children[0].text()
                    // 去除尾部 ":"
                    if namespace.hasSuffix(":") { namespace = String(namespace.dropLast()) }
                    let tagEls = children[1].children().array()
                    for tagEl in tagEls {
                        var tag = try tagEl.text()
                        // 去除 "|" 后的英文翻译 (Android 逻辑)
                        if let pipeIdx = tag.firstIndex(of: "|") {
                            tag = String(tag[..<pipeIdx]).trimmingCharacters(in: .whitespaces)
                        }
                        if !tag.isEmpty {
                            tags.append(namespace.isEmpty ? tag : "\(namespace):\(tag)")
                        }
                    }
                }
                if !tags.isEmpty { info.simpleTags = tags }
            }
        }

        // 如果 .glname 没找到，尝试 .glink (Compact 模式)
        if info.gid == 0 {
            if let glink = try row.select(".glink").first() {
                info.title = try glink.text()
                // 向上找 <a> 提取链接
                if let parent = glink.parent(), parent.tagName() == "a",
                   let href = try? parent.attr("href"),
                   let match = href.firstMatch(of: galleryUrlPattern) {
                    info.gid = Int64(match.1) ?? 0
                    info.token = String(match.2)
                }
            }
        }

        // 如果还是没有，最后尝试任意 href 包含 /g/ 的链接
        if info.gid == 0 {
            for link in try row.select("a[href*='/g/']") {
                let href = try link.attr("href")
                if let match = href.firstMatch(of: galleryUrlPattern) {
                    info.gid = Int64(match.1) ?? 0
                    info.token = String(match.2)
                    break
                }
            }
        }

        // 标题没有则返回 nil
        if info.title == nil || info.title?.isEmpty == true {
            if let glink = try row.select(".glink").first() {
                info.title = try glink.text()
            }
        }

        // 2. 分类: 从 .cn 或 .cs 获取 (Android 逻辑)
        if let categoryEl = try row.select(".cn, .cs").first() {
            let categoryText = try categoryEl.text()
            info.category = EhCategory.from(string: categoryText)
        } else if let categoryTd = try row.select("td.gl1c > div").first() {
            let categoryText = try categoryTd.text()
            info.category = EhCategory.from(string: categoryText)
        }

        // 3. 缩略图 (对应 Android 的 .glthumb div:nth-child(1)>img)
        if let glthumb = try row.select(".glthumb").first() {
            if let img = try glthumb.select("div:nth-child(1)>img").first() {
                // Thumb size (对应 Android PATTERN_THUMB_SIZE)
                let imgStyle = try img.attr("style")
                if let sizeMatch = imgStyle.firstMatch(of: thumbSizePattern) {
                    info.thumbHeight = Int(sizeMatch.1) ?? 0
                    info.thumbWidth = Int(sizeMatch.2) ?? 0
                }
                let dataSrc = try img.attr("data-src")
                let src = try img.attr("src")
                let url = dataSrc.isEmpty ? src : dataSrc
                if !url.isEmpty { info.thumb = url }
            }
        }

        // 回退: Extended 模式 (.gl1e) 或 Thumbnail 模式 (.gl3t)
        if info.thumb == nil {
            var gl = try row.select(".gl1e").first()
            if gl == nil {
                gl = try row.select(".gl3t").first()
            }
            if let g = gl, let img = try g.select("img").first() {
                // Thumb size
                let imgStyle = try img.attr("style")
                if let sizeMatch = imgStyle.firstMatch(of: thumbSizePattern) {
                    info.thumbHeight = Int(sizeMatch.1) ?? 0
                    info.thumbWidth = Int(sizeMatch.2) ?? 0
                }
                let src = try img.attr("src")
                if !src.isEmpty { info.thumb = src }
            }
        }

        // 最后回退: 任意 img 元素
        if info.thumb == nil, let img = try row.select("img").first() {
            let dataSrc = try img.attr("data-src")
            let src = try img.attr("src")
            let url = dataSrc.isEmpty ? src : dataSrc
            if !url.isEmpty { info.thumb = url }
        }

        // 样式中的缩略图 (内联 url())
        if info.thumb == nil, let div = try row.select("div[style*='url']").first() {
            let style = try div.attr("style")
            if let match = style.firstMatch(of: thumbUrlPattern) {
                info.thumb = String(match.1)
            }
        }

        // 4. 评分 (对应 Android ratingPattern)
        if let ratingDiv = try row.select("div.ir[style]").first() {
            let style = try ratingDiv.attr("style")
            info.rating = parseRating(style: style)
            // rated: Android 检查 irr/irg/irb 类
            info.rated = ratingDiv.hasClass("irr") || ratingDiv.hasClass("irg") || ratingDiv.hasClass("irb")
        }

        // 5. 上传者
        if let uploaderEl = try row.select(".glhide a, td.gl4c > a").first() {
            info.uploader = try uploaderEl.text()
        }

        // 6. 页数
        let rowText = try row.text()
        if let match = rowText.firstMatch(of: pagesPattern) {
            info.pages = Int(match.1) ?? 0
        }

        // 7. 发布日期 + 收藏槽位 (对应 Android posted + parseFavoriteSlot)
        if info.gid > 0 {
            let postedId = "posted_\(info.gid)"
            if let postedEl = try row.select("[id='\(postedId)']").first() {
                info.posted = try postedEl.text()
                info.favoriteSlot = parseFavoriteSlot(style: try postedEl.attr("style"))
            }
        }

        // 8. 标签 (gt/gtl 元素的 title 属性, 对应 Android parserTag)
        if info.simpleTags == nil {
            var tags: [String] = []
            for gt in try row.select(".gt") {
                let t = try gt.attr("title")
                if !t.isEmpty { tags.append(t) }
            }
            for gtl in try row.select(".gtl") {
                let t = try gtl.attr("title")
                if !t.isEmpty { tags.append(t) }
            }
            if !tags.isEmpty { info.simpleTags = tags }
        }

        return info
    }

    // MARK: - 缩略图模式解析

    private static func parseThumbDiv(_ div: Element) throws -> GalleryInfo {
        var info = GalleryInfo()

        if let link = try div.select("a[href]").first(),
           let href = try? link.attr("href"),
           let match = href.firstMatch(of: galleryUrlPattern) {
            info.gid = Int64(match.1) ?? 0
            info.token = String(match.2)
        }

        if let img = try div.select("img").first() {
            info.thumb = try img.attr("src")
            if let alt = try? img.attr("alt"), !alt.isEmpty {
                info.title = alt
            }
        }

        if let title = try div.select("div.glink").first() {
            info.title = try title.text()
        }

        return info
    }

    // MARK: - 评分解析

    /// 解析评分 (对应 Android 的评分计算算法)
    /// background-position:Xpx Ypx → rate = 5 + X/16 (X 为负值)
    /// Y <= -21 时减 0.5 (半星)
    public static func parseRating(style: String) -> Float {
        guard let match = style.firstMatch(of: ratingPattern) else { return 0 }

        let posX = Int(match.1) ?? 0  // e.g. 0, -16, -32, ..., -80
        let posY = Int(match.2) ?? 0  // e.g. -1 (full), -21 (half)

        // X=0 → 5 stars, X=-16 → 4 stars, X=-80 → 0 stars
        var rate = Float(5) + Float(posX) / 16.0
        // Y=-21 indicates half-star offset
        if posY <= -21 {
            rate -= 0.5
        }
        return max(0, min(5, rate))
    }

    // MARK: - 收藏槽位解析 (对应 Android parseFavoriteSlot)

    private static func parseFavoriteSlot(style: String) -> Int {
        guard let match = style.firstMatch(of: favoriteSlotPattern) else { return -2 }
        let r = String(match.1)
        let g = String(match.2)
        let b = String(match.3)
        for (slot, rgb) in favoriteSlotRGB.enumerated() {
            if r == rgb[0] && g == rgb[1] && b == rgb[2] {
                return slot
            }
        }
        return -2
    }

    // MARK: - 辅助

    private static func parsePageCount(_ doc: Document) throws -> Int {
        // 尝试从分页控件中提取页数
        if let lastPageLink = try doc.select("table.ptb td:last-child > a[href]").first(),
           let href = try? lastPageLink.attr("href"),
           let url = URLComponents(string: href),
           let pageParam = url.queryItems?.first(where: { $0.name == "page" })?.value {
            return (Int(pageParam) ?? 0) + 1
        }

        // 尝试其他分页方式
        let pttTds = try doc.select("table.ptb td")
        if pttTds.size() > 2 {
            let secondLast = pttTds.get(pttTds.size() - 2)
            let text = try secondLast.text()
            return Int(text) ?? 0
        }

        return 0
    }

    // MARK: - 排行榜解析 (对应 Android TopListParser.java)

    /// 解析排行榜页面 HTML → TopListDetail
    public static func parseTopList(_ html: String) throws -> TopListDetail {
        let doc = try SwiftSoup.parse(html)

        guard let ido = try doc.select(".ido").first() else {
            throw NSError(domain: "GalleryListParser", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing .ido element in toplist page"])
        }

        let children = ido.children().array()
        var categories: [TopListCategory] = []

        // Android: elements.get(1), .get(3), .get(5), .get(7), .get(9), .get(11), .get(13)
        // 每隔一个子元素为一个分类 (中间是标题)
        let categoryIndices = [1, 3, 5, 7, 9, 11, 13]
        let categoryNames = ["Gallery", "Uploader", "Tagging", "Hentai@Home", "EH Tracker", "Clean Up", "Rating & Reviewing"]

        for (i, idx) in categoryIndices.enumerated() {
            guard idx < children.count else { break }
            let element = children[idx]
            let subs = element.children().array()

            // Android: elements.get(1).child(1).child(0) 为 allTime, 2 为 pastYear, 3 为 pastMonth, 4 为 yesterday
            let allTime = subs.count > 1 ? parseTopListItems(subs[1]) : []
            let pastYear = subs.count > 2 ? parseTopListItems(subs[2]) : []
            let pastMonth = subs.count > 3 ? parseTopListItems(subs[3]) : []
            let yesterday = subs.count > 4 ? parseTopListItems(subs[4]) : []

            let category = TopListCategory(
                name: i < categoryNames.count ? categoryNames[i] : "",
                allTime: allTime,
                pastYear: pastYear,
                pastMonth: pastMonth,
                yesterday: yesterday
            )
            categories.append(category)
        }

        return TopListDetail(lists: categories)
    }

    /// 解析排行榜子项列表 (对应 Android TopListParser.parseArray)
    private static func parseTopListItems(_ element: Element) -> [TopListItem] {
        var items: [TopListItem] = []
        // Android: element.child(1).child(0) 获取表格，然后 .getElementsByClass("tun")
        guard let table = try? element.select("table").first() else {
            // 尝试直接在子层级找
            guard let tunElements = try? element.select(".tun") else { return [] }
            for tun in tunElements {
                guard let a = try? tun.select("a").first() else { continue }
                let value = (try? a.text()) ?? ""
                let href = (try? a.attr("href")) ?? ""
                items.append(TopListItem(text: value, href: href))
            }
            return items
        }

        guard let tunElements = try? table.select(".tun") else { return [] }
        for tun in tunElements {
            guard let a = try? tun.select("a").first() else { continue }
            let value = (try? a.text()) ?? ""
            let href = (try? a.attr("href")) ?? ""
            items.append(TopListItem(text: value, href: href))
        }
        return items
    }
}
