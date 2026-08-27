import Foundation

// MARK: - ListUrlBuilder (对应 Android ListUrlBuilder.java)
// 8 种模式的 URL 构建器，支持高级搜索

public struct ListUrlBuilder: Sendable, Codable {

    // MARK: - 搜索模式

    public enum Mode: Int, Sendable, Codable {
        case normal       = 0
        case uploader     = 1
        case tag          = 2
        case whatsHot     = 3
        case imageSearch  = 4
        case subscription = 5
        case filter       = 6
        case topList      = 7
    }

    // MARK: - 高级搜索标志 (对应 Android AdvanceSearchTable)

    public struct AdvanceSearch: OptionSet, Sendable, Codable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let sname = AdvanceSearch(rawValue: 0x001)  // 搜索名称
        public static let stags = AdvanceSearch(rawValue: 0x002)  // 搜索标签
        public static let sdesc = AdvanceSearch(rawValue: 0x004)  // 搜索描述
        public static let storr = AdvanceSearch(rawValue: 0x008)  // 搜索种子
        public static let sto   = AdvanceSearch(rawValue: 0x010)  // 搜索种子文件名
        public static let sdt1  = AdvanceSearch(rawValue: 0x020)  // 搜索已删除
        public static let sdt2  = AdvanceSearch(rawValue: 0x040)  // 搜索已删除(精确)
        public static let sh    = AdvanceSearch(rawValue: 0x080)  // 仅显示有种子
        public static let sfl   = AdvanceSearch(rawValue: 0x100)  // 搜索低评分
        public static let sfu   = AdvanceSearch(rawValue: 0x200)  // 搜索用户标签
        public static let sft   = AdvanceSearch(rawValue: 0x400)  // 搜索所有标签

        public static let `default`: AdvanceSearch = [.sname, .stags]
    }

    public static let defaultMinRating = 2

    // MARK: - 属性

    public var mode: Mode = .normal
    public var pageIndex: Int = 0
    public var category: Int = 0  // -1 = none, 0 = default, 位掩码
    public var keyword: String?
    public var follow: String?   // topList 模式下的参数 (tl=N)

    /// -1 表示未启用
    public var advanceSearch: Int = -1
    public var minRating: Int = -1
    public var pageFrom: Int = -1
    public var pageTo: Int = -1

    // Image search 专用
    public var imagePath: String?
    public var useSimilarityScan: Bool = false
    public var onlySearchCovers: Bool = false
    public var showExpunged: Bool = false

    public init() {}

    // MARK: - 重置

    public mutating func reset() {
        mode = .normal
        pageIndex = 0
        category = 0
        keyword = nil
        follow = nil
        advanceSearch = -1
        minRating = -1
        pageFrom = -1
        pageTo = -1
        imagePath = nil
        useSimilarityScan = false
        onlySearchCovers = false
        showExpunged = false
    }

    // MARK: - 从 QuickSearch 加载

    public mutating func set(from qs: QuickSearch) {
        mode = Mode(rawValue: qs.mode) ?? .normal
        category = qs.category
        keyword = qs.keyword
        advanceSearch = qs.advanceSearch
        minRating = qs.minRating
        pageFrom = qs.pageFrom
        pageTo = qs.pageTo
        imagePath = nil
        useSimilarityScan = false
        onlySearchCovers = false
        showExpunged = false
    }

    /// 转为 QuickSearch
    public func toQuickSearch() -> QuickSearch {
        QuickSearch(
            mode: mode.rawValue,
            category: category,
            keyword: keyword,
            advanceSearch: advanceSearch,
            minRating: minRating,
            pageFrom: pageFrom,
            pageTo: pageTo
        )
    }

    // MARK: - URL 查询参数解析 (对应 Android setQuery)

    /// 从 URL 查询字符串解析参数
    /// - Parameter query: 如 "f_cats=123&f_search=keyword&advsearch=1..."
    public mutating func setQuery(_ query: String) {
        reset()
        guard !query.isEmpty else { return }

        let pairs = query.split(separator: "&")
        var category = 0
        var keyword: String?
        var enableAdvanceSearch = false
        var advanceSearch = 0
        var enableMinRating = false
        var minRating = -1
        var enablePage = false
        var pageFrom = -1
        var pageTo = -1

        for pair in pairs {
            guard let eqIdx = pair.firstIndex(of: "=") else { continue }
            let key = String(pair[..<eqIdx])
            let value = String(pair[pair.index(after: eqIdx)...])

            switch key {
            case "f_cats":
                let cats = Int(value) ?? 0x3FF
                category |= (~cats) & 0x3FF
            case "f_doujinshi": if value == "1" { category |= 0x2 }
            case "f_manga": if value == "1" { category |= 0x4 }
            case "f_artistcg": if value == "1" { category |= 0x8 }
            case "f_gamecg": if value == "1" { category |= 0x10 }
            case "f_western": if value == "1" { category |= 0x200 }
            case "f_non-h": if value == "1" { category |= 0x100 }
            case "f_imageset": if value == "1" { category |= 0x20 }
            case "f_cosplay": if value == "1" { category |= 0x40 }
            case "f_asianporn": if value == "1" { category |= 0x80 }
            case "f_misc": if value == "1" { category |= 0x1 }
            case "f_search":
                keyword = value.removingPercentEncoding ?? value
            case "advsearch":
                if value == "1" { enableAdvanceSearch = true }
            case "f_sname": if value == "on" { advanceSearch |= 0x1 }
            case "f_stags": if value == "on" { advanceSearch |= 0x2 }
            case "f_sdesc": if value == "on" { advanceSearch |= 0x4 }
            case "f_storr": if value == "on" { advanceSearch |= 0x8 }
            case "f_sto": if value == "on" { advanceSearch |= 0x10 }
            case "f_sdt1": if value == "on" { advanceSearch |= 0x20 }
            case "f_sdt2": if value == "on" { advanceSearch |= 0x40 }
            case "f_sh": if value == "on" { advanceSearch |= 0x80 }
            case "f_sfl": if value == "on" { advanceSearch |= 0x100 }
            case "f_sfu": if value == "on" { advanceSearch |= 0x200 }
            case "f_sft": if value == "on" { advanceSearch |= 0x400 }
            case "f_sr":
                if value == "on" { enableMinRating = true }
            case "f_srdd":
                minRating = Int(value) ?? -1
            case "f_sp":
                if value == "on" { enablePage = true }
            case "f_spf":
                pageFrom = Int(value) ?? -1
            case "f_spt":
                pageTo = Int(value) ?? -1
            default:
                break
            }
        }

        self.category = category
        self.keyword = keyword

        if enableAdvanceSearch {
            self.advanceSearch = advanceSearch
            self.minRating = enableMinRating ? minRating : -1
            if enablePage {
                self.pageFrom = pageFrom
                self.pageTo = pageTo
            } else {
                self.pageFrom = -1
                self.pageTo = -1
            }
        } else {
            self.advanceSearch = -1
        }
    }

    // MARK: - 关键词清洗

    /// 去掉搜索词里的换行符 (对齐上游 2026-03-02 / 2026-03-14「搜索时过滤文本中的换行符」)
    ///
    /// 从别处粘贴标签时很容易带进 \r / \n。上游一开始替换成空格，后来改成**直接删除** ——
    /// 因为多余的空格会被 E-Hentai 当成词分隔符，把 `artist:foo` 这类语法拆断。
    /// 注意 `trimmingCharacters(in: .whitespaces)` 并不会去掉换行，必须显式处理。
    public static func sanitizeKeyword(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\r", with: "")
           .replacingOccurrences(of: "\n", with: "")
           .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 构建 URL (对应 Android build())

    public func build(site: EhSite = .eHentai) -> String {

        switch mode {
        case .normal, .subscription:
            let baseUrl = mode == .normal
                ? EhURL.host(for: site)
                : EhURL.watchedUrl(for: site)

            var params: [String] = []

            // 分类
            if category > 0 {
                params.append("f_cats=\((~category) & 0x3FF)")
            }

            // 关键词
            if let kw = keyword.map(Self.sanitizeKeyword), !kw.isEmpty {
                if let encoded = kw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                    params.append("f_search=\(encoded)")
                }
            }

            // 分页
            if pageIndex > 0 {
                params.append("page=\(pageIndex)")
            }

            // 高级搜索
            if advanceSearch != -1 {
                params.append("advsearch=1")
                let flags: [(Int, String)] = [
                    (0x001, "f_sname"), (0x002, "f_stags"), (0x004, "f_sdesc"),
                    (0x008, "f_storr"), (0x010, "f_sto"), (0x020, "f_sdt1"),
                    (0x040, "f_sdt2"), (0x080, "f_sh"), (0x100, "f_sfl"),
                    (0x200, "f_sfu"), (0x400, "f_sft"),
                ]
                for (flag, name) in flags {
                    if advanceSearch & flag != 0 {
                        params.append("\(name)=on")
                    }
                }
                // 最低评分
                if minRating != -1 {
                    params.append("f_sr=on")
                    params.append("f_srdd=\(minRating)")
                }
                // 页数范围
                if pageFrom != -1 || pageTo != -1 {
                    params.append("f_sp=on")
                    params.append("f_spf=\(pageFrom != -1 ? String(pageFrom) : "")")
                    params.append("f_spt=\(pageTo != -1 ? String(pageTo) : "")")
                }
            }

            if params.isEmpty {
                return baseUrl
            }
            return baseUrl + "?" + params.joined(separator: "&")

        case .uploader:
            let encoded = keyword.map(Self.sanitizeKeyword)?
                .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
            var url = EhURL.host(for: site) + "uploader/" + encoded
            if pageIndex > 0 {
                url += "/\(pageIndex)"
            }
            return url

        case .tag:
            let encoded = keyword.map(Self.sanitizeKeyword)?
                .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
            var url = EhURL.host(for: site) + "tag/" + encoded
            if pageIndex > 0 {
                url += "/\(pageIndex)"
            }
            return url

        case .filter:
            var url = EhURL.host(for: site) + "?"
            if pageIndex > 0 {
                url += "page=\(pageIndex)&"
            }
            url += "f_search="
            if let kw = keyword.map(Self.sanitizeKeyword)?
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                url += kw
            }
            return url

        case .whatsHot:
            return EhURL.popularUrl(for: site)

        case .imageSearch:
            return EhURL.imageLookupUrl(for: site)

        case .topList:
            var url = EhURL.topListUrl() + "?"
            if let f = follow {
                url += f
            }
            if pageIndex > 0 && pageIndex < 200 {
                url += "&p=\(pageIndex)"
            }
            return url
        }
    }
}
