import Foundation

// MARK: - 站点选择

public enum EhSite: Int, Sendable, Codable, CaseIterable {
    case eHentai = 0    // 表站
    case exHentai = 1   // 里站
}

// MARK: - URL 常量系统 (对应 Android EhUrl.java)

public enum EhURL {
    // MARK: 域名
    public static let domainE  = "e-hentai.org"
    public static let domainEX = "exhentai.org"
    public static let domainLofi = "lofi.e-hentai.org"
    public static let domainForums = "forums.e-hentai.org"

    // MARK: 基础 URL
    public static let hostE  = "https://e-hentai.org/"
    public static let hostEX = "https://exhentai.org/"

    // MARK: 登录
    public static let signInUrl = "https://forums.e-hentai.org/index.php?act=Login&CODE=01"
    public static let signInReferer = "https://forums.e-hentai.org/index.php?act=Login&CODE=00"
    public static let signInOrigin = "https://forums.e-hentai.org"
    public static let registerUrl = "https://forums.e-hentai.org/index.php?act=Reg&CODE=00"

    // MARK: 论坛
    public static let forumsUrl = "https://forums.e-hentai.org/"

    // MARK: 新闻
    public static let newsUrl = "https://e-hentai.org/news.php"

    // MARK: 站点相关动态 URL
    public static func host(for site: EhSite) -> String {
        site == .exHentai ? hostEX : hostE
    }

    public static func apiUrl(for site: EhSite) -> String {
        // 对齐 Android: API_EHENTAI = "https://api.e-hentai.org/api.php"
        //             API_EXHENTAI = "https://s.exhentai.org/api.php"
        switch site {
        case .eHentai:  return "https://api.e-hentai.org/api.php"
        case .exHentai: return "https://s.exhentai.org/api.php"
        }
    }

    public static func homeUrl(for site: EhSite) -> String {
        "\(host(for: site))home.php"
    }

    public static func popularUrl(for site: EhSite) -> String {
        "\(host(for: site))popular"
    }

    public static func favoritesUrl(for site: EhSite) -> String {
        "\(host(for: site))favorites.php"
    }

    public static func watchedUrl(for site: EhSite) -> String {
        "\(host(for: site))watched"
    }

    public static func topListUrl() -> String {
        // 排行榜仅 E 站
        "\(hostE)toplist.php"
    }

    public static func topListUrl(period: Int, page: Int = 0) -> String {
        let firstPage = "\(topListUrl())?tl=\(period)"
        return page > 0 ? "\(firstPage)&p=\(page)" : firstPage
    }

    /// Accept relative pagination links and keep toplist navigation on the E endpoint.
    public static func topListNavigationUrl(_ href: String) -> String? {
        guard !href.isEmpty,
              let base = URL(string: topListUrl()),
              let url = URL(string: href, relativeTo: base)?.absoluteURL,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https",
              components.host == domainE || components.host == domainEX,
              components.user == nil, components.password == nil, components.port == nil,
              components.path == base.path,
              let query = components.percentEncodedQuery, !query.isEmpty else { return nil }
        return "\(topListUrl())?\(query)"
    }

    public static func imageLookupUrl(for site: EhSite) -> String {
        site == .exHentai
            ? "https://upld.exhentai.org/upld/image_lookup.php"
            : "https://upld.e-hentai.org/image_lookup.php"
    }

    public static func uconfigUrl(for site: EhSite) -> String {
        "\(host(for: site))uconfig.php"
    }

    public static func myTagsUrl(for site: EhSite) -> String {
        "\(host(for: site))mytags"
    }

    public static func referer(for site: EhSite) -> String {
        host(for: site)
    }

    public static func origin(for site: EhSite) -> String {
        site == .exHentai ? "https://exhentai.org" : "https://e-hentai.org"
    }

    // MARK: 动态路径构建

    /// 画廊详情 URL: {host}g/{gid}/{token}/?p={page}&hc=1
    /// 注: 默认 allComment=false 对齐 Android (EhUrl.getGalleryDetailUrl)
    public static func galleryDetailUrl(gid: Int64, token: String, page: Int = 0,
                                         allComment: Bool = false, site: EhSite) -> String {
        var url = "\(host(for: site))g/\(gid)/\(token)/"
        var params: [String] = []
        if page > 0 { params.append("p=\(page)") }
        if allComment { params.append("hc=1") }
        if !params.isEmpty {
            url += "?" + params.joined(separator: "&")
        }
        return url
    }

    /// 画廊页面 URL: {host}s/{pToken}/{gid}-{page+1}
    public static func pageUrl(gid: Int64, index: Int, pToken: String, site: EhSite) -> String {
        "\(host(for: site))s/\(pToken)/\(gid)-\(index + 1)"
    }

    /// 添加收藏 URL
    public static func addFavoritesUrl(gid: Int64, token: String, site: EhSite) -> String {
        "\(host(for: site))gallerypopups.php?gid=\(gid)&t=\(token)&act=addfav"
    }

    /// 归档下载 URL
    /// 对齐 Android: or 为空时不包含 &or= 参数
    public static func downloadArchiveUrl(gid: Int64, token: String, or: String?, site: EhSite) -> String {
        var url = "\(host(for: site))archiver.php?gid=\(gid)&token=\(token)"
        if let or = or, !or.isEmpty {
            url += "&or=\(or)"
        }
        return url
    }

    /// 缩略图前缀
    public static func thumbPrefix(for site: EhSite) -> String {
        site == .exHentai ? "https://exhentai.org/t/" : "https://ehgt.org/"
    }

    /// 标签定义 wiki URL
    public static func tagDefinitionUrl(tag: String) -> String {
        "https://ehwiki.org/wiki/\(tag.replacingOccurrences(of: " ", with: "_"))"
    }
}
