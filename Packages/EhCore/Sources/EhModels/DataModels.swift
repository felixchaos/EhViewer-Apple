import Foundation

// MARK: - 下载信息 (对应 Android DownloadInfo.java)

public struct DownloadInfo: Identifiable, Sendable, Codable {
    public var id: Int64 { gallery.gid }

    public var gallery: GalleryInfo

    public var state: DownloadState
    public var legacy: Int       // 遗留未完成数
    public var time: Date        // 排序时间
    public var label: String?    // 下载标签/分组
    public var archiveUri: String?

    // 运行时状态 (不持久化)
    public var speed: Int64      // bytes/sec
    public var remaining: Int64  // 剩余秒数
    public var finished: Int     // 已完成页数
    public var downloaded: Int   // 已下载页数
    public var total: Int        // 总页数

    public init(
        gallery: GalleryInfo = GalleryInfo(),
        state: DownloadState = .none,
        legacy: Int = 0,
        time: Date = .now,
        label: String? = nil,
        archiveUri: String? = nil,
        speed: Int64 = 0,
        remaining: Int64 = 0,
        finished: Int = 0,
        downloaded: Int = 0,
        total: Int = 0
    ) {
        self.gallery = gallery
        self.state = state
        self.legacy = legacy
        self.time = time
        self.label = label
        self.archiveUri = archiveUri
        self.speed = speed
        self.remaining = remaining
        self.finished = finished
        self.downloaded = downloaded
        self.total = total
    }
}

public enum DownloadState: Int, Sendable, Codable {
    case invalid  = -1
    case none     = 0
    case waiting  = 1
    case download = 2
    case finish   = 3
    case failed   = 4
    case update   = 5
}

// MARK: - 下载标签

public struct DownloadLabel: Identifiable, Sendable, Codable {
    public var id: Int64?
    public var label: String
    public var time: Date

    public init(id: Int64? = nil, label: String, time: Date = .now) {
        self.id = id
        self.label = label
        self.time = time
    }
}

// MARK: - Spider 信息 (对应 Android SpiderInfo.java, .ehviewer 文件格式)

public struct SpiderInfo: Sendable {
    public static let version = 2

    public var startPage: Int
    public var gid: Int64
    public var token: String
    public var pages: Int
    public var previewPages: Int
    public var previewPerPage: Int
    public var pTokenMap: [Int: String]  // page index → pToken

    public init(
        startPage: Int = 0,
        gid: Int64 = 0,
        token: String = "",
        pages: Int = 0,
        previewPages: Int = 0,
        previewPerPage: Int = 0,
        pTokenMap: [Int: String] = [:]
    ) {
        self.startPage = startPage
        self.gid = gid
        self.token = token
        self.pages = pages
        self.previewPages = previewPages
        self.previewPerPage = previewPerPage
        self.pTokenMap = pTokenMap
    }

    // MARK: 序列化 (.ehviewer 文件格式)

    /// 序列化为 .ehviewer 文件内容
    public func serialize() -> String {
        var lines: [String] = []
        lines.append("VERSION\(Self.version)")
        lines.append(String(format: "%08x", max(startPage, 0)))
        lines.append("\(gid)")
        lines.append(token)
        lines.append("1")  // deprecated mode
        lines.append("\(previewPages)")
        lines.append("\(previewPerPage)")
        lines.append("\(pages)")

        for (index, pToken) in pTokenMap.sorted(by: { $0.key < $1.key }) {
            if pToken != "failed" {
                lines.append("\(index) \(pToken)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 从 .ehviewer 文件内容反序列化
    public static func deserialize(from content: String) -> SpiderInfo? {
        let lines = content.components(separatedBy: .newlines)
        guard !lines.isEmpty else { return nil }

        var info = SpiderInfo()
        var lineIndex = 0

        // 版本检测
        let isV2 = lines[0].hasPrefix("VERSION")
        if isV2 {
            lineIndex = 1
        }

        guard lines.count > lineIndex + 5 else { return nil }

        // startPage (hex)
        info.startPage = Int(lines[lineIndex], radix: 16) ?? 0
        lineIndex += 1

        // gid
        info.gid = Int64(lines[lineIndex]) ?? 0
        lineIndex += 1

        // token
        info.token = lines[lineIndex]
        lineIndex += 1

        // deprecated mode (skip)
        lineIndex += 1

        // previewPages
        info.previewPages = Int(lines[lineIndex]) ?? 0
        lineIndex += 1

        // previewPerPage (V2 only)
        if isV2 {
            info.previewPerPage = Int(lines[lineIndex]) ?? 0
            lineIndex += 1
        }

        // pages
        info.pages = Int(lines[lineIndex]) ?? 0
        lineIndex += 1

        // pTokenMap
        while lineIndex < lines.count {
            let line = lines[lineIndex]
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2, let index = Int(parts[0]) {
                info.pTokenMap[index] = String(parts[1])
            }
            lineIndex += 1
        }

        return info
    }
}

// MARK: - 种子信息 (对应 Android client/data/TorrentInfo.java)

/// 画廊种子条目
/// 上游 2026-04-30「种子下载列表添加上传时间」把 `Pair<String,String>` 换成了带 posted 的结构体
public struct TorrentInfo: Sendable, Identifiable, Hashable {
    public var id: String { url }
    /// 种子下载地址 (已去掉 `?p=`，保证可再分发)
    public let url: String
    /// 种子文件名
    public let name: String
    /// 上传时间 (页面上的 "Posted:" 字段)，解析不到时为空串
    public let posted: String

    public init(url: String, name: String, posted: String = "") {
        self.url = url
        self.name = name
        self.posted = posted
    }
}

// MARK: - 可编辑评论 (对应 Android client/parser/GetEditCommentParser.Result)

/// `geteditcomment` API 返回的评论原文
public struct EditableComment: Sendable {
    public let id: Int64
    /// 评论原始文本 (含 BBCode，不是渲染后的 HTML)
    public let comment: String

    public init(id: Int64, comment: String) {
        self.id = id
        self.comment = comment
    }
}

// MARK: - 浏览历史

public struct HistoryInfo: Identifiable, Sendable, Codable {
    public var id: Int64 { gallery.gid }
    public var gallery: GalleryInfo
    public var time: Date
    public var mode: Int  // 0=list, 1=detail

    public init(gallery: GalleryInfo = GalleryInfo(), time: Date = .now, mode: Int = 0) {
        self.gallery = gallery
        self.time = time
        self.mode = mode
    }
}

// MARK: - 快速搜索

public struct QuickSearch: Identifiable, Sendable, Codable {
    public var id: Int64?
    public var name: String?
    public var mode: Int
    public var category: Int
    public var keyword: String?
    public var advanceSearch: Int
    public var minRating: Int
    public var pageFrom: Int
    public var pageTo: Int
    public var time: Date

    public init(
        id: Int64? = nil, name: String? = nil, mode: Int = 0,
        category: Int = 0, keyword: String? = nil, advanceSearch: Int = 0,
        minRating: Int = 0, pageFrom: Int = -1, pageTo: Int = -1, time: Date = .now
    ) {
        self.id = id; self.name = name; self.mode = mode
        self.category = category; self.keyword = keyword
        self.advanceSearch = advanceSearch; self.minRating = minRating
        self.pageFrom = pageFrom; self.pageTo = pageTo; self.time = time
    }
}

// MARK: - 过滤器

public struct EhFilter: Identifiable, Sendable, Codable {
    public var id: Int64?
    public var mode: FilterMode
    public var text: String
    public var isEnabled: Bool

    public init(id: Int64? = nil, mode: FilterMode = .title, text: String = "", isEnabled: Bool = true) {
        self.id = id; self.mode = mode; self.text = text; self.isEnabled = isEnabled
    }
}

public enum FilterMode: Int, Sendable, Codable, CaseIterable {
    case title = 0
    case uploader = 1
    case tag = 2
    case tagNamespace = 3
    case commenter = 4
    case comment = 5
}

// MARK: - 排行榜数据

public struct TopListDetail: Sendable {
    public var lists: [TopListCategory]

    public init(lists: [TopListCategory] = []) {
        self.lists = lists
    }
}

public struct TopListCategory: Sendable {
    public var name: String
    public var allTime: [TopListItem]
    public var pastYear: [TopListItem]
    public var pastMonth: [TopListItem]
    public var yesterday: [TopListItem]

    public init(name: String = "", allTime: [TopListItem] = [],
                pastYear: [TopListItem] = [], pastMonth: [TopListItem] = [],
                yesterday: [TopListItem] = []) {
        self.name = name; self.allTime = allTime; self.pastYear = pastYear
        self.pastMonth = pastMonth; self.yesterday = yesterday
    }
}

public struct TopListItem: Sendable {
    public var text: String
    public var href: String?

    public init(text: String = "", href: String? = nil) {
        self.text = text; self.href = href
    }
}

// MARK: - 归档数据

public struct ArchiverData: Sendable {
    public var funds: String?
    public var originalCost: String?
    public var originalSize: String?
    public var originalUrl: String?
    public var resampleCost: String?
    public var resampleSize: String?
    public var resampleUrl: String?

    public init() {}
}

// MARK: - 配额信息

public struct HomeDetail: Sendable {
    public var currentUsed: Int
    public var totalLimit: Int
    public var resetCost: Int

    public init(currentUsed: Int = 0, totalLimit: Int = 0, resetCost: Int = 0) {
        self.currentUsed = currentUsed
        self.totalLimit = totalLimit
        self.resetCost = resetCost
    }
}

// MARK: - API 返回结果类型 (跨包共享)

public struct GalleryListResult: Sendable {
    public var galleries: [GalleryInfo]
    public var pages: Int
    public var nextPage: Int?
    public var resultCount: String?
    /// searchnav 模式下的导航链接
    public var prevHref: String?
    public var nextHref: String?
    public var noWatchedTags: Bool

    public init(galleries: [GalleryInfo] = [], pages: Int = 0,
                nextPage: Int? = nil, resultCount: String? = nil,
                prevHref: String? = nil, nextHref: String? = nil,
                noWatchedTags: Bool = false) {
        self.galleries = galleries; self.pages = pages
        self.nextPage = nextPage; self.resultCount = resultCount
        self.prevHref = prevHref; self.nextHref = nextHref
        self.noWatchedTags = noWatchedTags
    }
}

public struct GalleryPageResult: Sendable {
    public var imageUrl: String
    public var skipHathKey: String?
    public var originImageUrl: String?
    public var showKey: String?

    public init(imageUrl: String = "", skipHathKey: String? = nil,
                originImageUrl: String? = nil, showKey: String? = nil) {
        self.imageUrl = imageUrl; self.skipHathKey = skipHathKey
        self.originImageUrl = originImageUrl; self.showKey = showKey
    }
}

public struct RateResult: Sendable {
    public var rating: Float
    public var ratingCount: Int

    public init(rating: Float = 0, ratingCount: Int = 0) {
        self.rating = rating; self.ratingCount = ratingCount
    }
}

public struct VoteCommentResult: Sendable {
    public var score: Int
    public var vote: Int

    public init(score: Int = 0, vote: Int = 0) {
        self.score = score; self.vote = vote
    }
}

// MARK: - 用户资料 (对应 Android ProfileParser.Result)

public struct ProfileResult: Sendable {
    public var displayName: String?
    public var avatar: String?

    public init(displayName: String? = nil, avatar: String? = nil) {
        self.displayName = displayName; self.avatar = avatar
    }
}

// MARK: - 用户标签 (对应 Android UserTag.java / UserTagList.java)

public struct UserTag: Sendable, Identifiable, Codable {
    public var id: String { userTagId }
    public var userTagId: String
    public var tagName: String
    public var watched: Bool
    public var hidden: Bool
    public var color: String?
    public var tagWeight: Int

    public init(
        userTagId: String = "", tagName: String = "",
        watched: Bool = false, hidden: Bool = false,
        color: String? = nil, tagWeight: Int = 0
    ) {
        self.userTagId = userTagId; self.tagName = tagName
        self.watched = watched; self.hidden = hidden
        self.color = color; self.tagWeight = tagWeight
    }

    /// 构建添加标签的 POST body (对应 Android TagPushParam.addTagParam)
    public func addTagParam() -> String {
        var parts: [String] = []
        parts.append("tagname_new=\(tagName)")
        parts.append("tagwatch_new=\(watched ? "on" : "")")
        parts.append("taghide_new=\(hidden ? "on" : "")")
        parts.append("tagcolor_new=\(color ?? "")")
        parts.append("tagweight_new=\(tagWeight)")
        parts.append("usertag_action=add")
        return parts.joined(separator: "&")
    }

    /// 构建删除标签的 POST body (对应 Android UserTag.deleteParam)
    public func deleteParam() -> String {
        let id = userTagId.hasPrefix("usertag_") ? String(userTagId.dropFirst(8)) : userTagId
        return "usertag_action=rename&modify_usertag=\(id)"
    }
}

public struct UserTagList: Sendable {
    public var userTags: [UserTag]

    public init(userTags: [UserTag] = []) {
        self.userTags = userTags
    }
}

// MARK: - EH 新闻 (对应 Android EhNewsDetail)

public struct EhNewsDetail: Sendable {
    public var rawHtml: String

    public init(rawHtml: String = "") {
        self.rawHtml = rawHtml
    }
}

// MARK: - 黑名单 (对应 Android BlackList.java)

public struct BlackListEntry: Identifiable, Sendable, Codable {
    public var id: Int64?
    public var badgayname: String
    public var reason: String?
    public var angrywith: String?
    public var addTime: String?
    public var mode: Int?

    public init(id: Int64? = nil, badgayname: String = "", reason: String? = nil,
                angrywith: String? = nil, addTime: String? = nil, mode: Int? = nil) {
        self.id = id; self.badgayname = badgayname; self.reason = reason
        self.angrywith = angrywith; self.addTime = addTime; self.mode = mode
    }
}

// MARK: - 阅读书签 (对应 Android BookmarkInfo.java)

public struct BookmarkInfo: Identifiable, Sendable, Codable {
    public var id: Int64 { gallery.gid }
    public var gallery: GalleryInfo
    public var page: Int
    public var time: Date

    public init(gallery: GalleryInfo = GalleryInfo(), page: Int = 0, time: Date = .now) {
        self.gallery = gallery; self.page = page; self.time = time
    }
}

// MARK: - 下载目录名映射 (对应 Android DownloadDirname.java)

public struct DownloadDirname: Sendable, Codable {
    public var gid: Int64
    public var dirname: String

    public init(gid: Int64 = 0, dirname: String = "") {
        self.gid = gid; self.dirname = dirname
    }
}

// MARK: - 画廊标签缓存 (对应 Android GalleryTags.java)

public struct GalleryTagsCache: Sendable, Codable {
    public var gid: Int64
    public var rows: String?
    public var artist: String?
    public var cosplayer: String?
    public var character: String?
    public var female: String?
    public var group: String?
    public var language: String?
    public var male: String?
    public var misc: String?
    public var mixed: String?
    public var other: String?
    public var parody: String?
    public var reclass: String?
    public var createTime: Date?
    public var updateTime: Date?

    public init(gid: Int64 = 0) {
        self.gid = gid
    }
}

// MARK: - 归档列表结果 (对应 Android ArchiveParser.parse 返回值)

public struct ArchiveListResult: Sendable {
    /// H@H 下载表单 or 参数
    public var paramOr: String
    /// 归档列表: [(res ID, 名称)]
    public var archives: [(String, String)]

    public init(paramOr: String = "", archives: [(String, String)] = []) {
        self.paramOr = paramOr; self.archives = archives
    }
}
