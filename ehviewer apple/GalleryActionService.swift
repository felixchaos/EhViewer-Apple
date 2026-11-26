//
//  GalleryActionService.swift
//  ehviewer apple
//
//  统一画廊操作服务 — 收藏/下载/分享/复制链接的唯一真相源
//  所有 View 通过此服务执行操作，禁止在 Button(action:) 中直接写业务逻辑
//

import SwiftUI
import EhModels
import EhAPI
import EhSettings
import EhDatabase
import EhDownload

// MARK: - 画廊操作服务 (Single Source of Truth)

@Observable
@MainActor
final class GalleryActionService {
    static let shared = GalleryActionService()
    private init() {}

    // MARK: - 收藏

    struct FavoriteState: Equatable {
        var local: Bool
        var cloud: Bool
        var isFavorited: Bool { local || cloud }
    }

    func favoriteState(gid: Int64, cloud: Bool) -> FavoriteState {
        Self.favoriteState(cloud: cloud, readLocal: { try EhDatabase.shared.containsLocalFavorite(gid: gid) })
    }

    static func favoriteState(cloud: Bool, readLocal: () throws -> Bool) -> FavoriteState {
        FavoriteState(local: (try? readLocal()) ?? false, cloud: cloud)
    }

    enum FavoriteLocation: Equatable { case local, cloud }

    /// Prefer removing a local copy without touching the network. If both copies
    /// exist the cloud favorite stays intact and remains selected.
    static func removePreferredFavorite(
        readLocal: () throws -> Bool, removeLocal: () throws -> Void,
        removeCloud: () async throws -> Void
    ) async throws -> FavoriteLocation {
        if try readLocal() {
            try removeLocal()
            return .local
        }
        try await removeCloud()
        return .cloud
    }

    /// 快速收藏的三种结局。
    ///
    /// 此前这里返回 Bool，把「没设默认收藏夹」和「网络失败」压成了同一个
    /// false，于是收藏请求失败时界面会弹出收藏夹选择器——用户以为是要选
    /// 文件夹，选完又失败一次。两件事必须分开。
    enum QuickFavoriteOutcome {
        case done
        case needsPicker
        case failed
    }

    /// 快速收藏 — 使用默认收藏夹 (对齐 Android: onModifyFavorite with defaultFavSlot)
    /// - 默认 slot >= 0: 直接添加到云端
    /// - 默认 slot == -1: 添加到本地
    /// - 默认 slot == -2: 需要弹出选择器
    func quickFavorite(gallery: GalleryInfo) async -> QuickFavoriteOutcome {
        let defaultSlot = AppSettings.shared.defaultFavSlot
        if defaultSlot >= 0 && defaultSlot <= 9 {
            do {
                try await addFavorite(gid: gallery.gid, token: gallery.token, slot: defaultSlot)
                return .done
            } catch {
                return .failed
            }
        } else if defaultSlot == -1 {
            return addLocalFavorite(gallery: gallery) ? .done : .failed
        }
        return .needsPicker
    }

    var cloudFavoriteContext: CloudFavoriteContext { GalleryStatusCache.shared.cloudFavoriteContext }

    func isCurrentCloudFavoriteContext(_ context: CloudFavoriteContext) -> Bool {
        cloudFavoriteContext == context
    }

    /// Shared by detail actions and batches; only publish a successful mutation
    /// to the account/site whose snapshot it belongs to.
    func mutateCloudFavorite(
        gid: Int64, token: String, slot: Int, context: CloudFavoriteContext,
        onCommit: () -> Void = {}
    ) async throws {
        try await context.perform(current: { self.cloudFavoriteContext }, request: {
            try await EhAPI.shared.addFavorites(gid: gid, token: token, dstCat: slot)
        }, commit: {
            self.recordCloudFavorite(gid: gid, slot: slot)
            onCommit()
        })
    }

    /// 添加云端收藏，失败时由调用方保留原收藏状态。
    func addFavorite(gid: Int64, token: String, slot: Int, context: CloudFavoriteContext? = nil) async throws {
        let context = context ?? cloudFavoriteContext
        do {
            try await mutateCloudFavorite(gid: gid, token: token, slot: slot, context: context) {
                EhToast.success("已添加至收藏")
                AppSettings.shared.recentFavCat = slot
            }
        } catch {
            if isCurrentCloudFavoriteContext(context) { EhToast.failure("添加收藏失败") }
            throw error
        }
    }

    /// 添加本地收藏 (对齐 Android FAV_CAT_LOCAL = -1)
    @discardableResult
    func addLocalFavorite(gallery: GalleryInfo) -> Bool {
        var record = LocalFavoriteRecord(
            gid: gallery.gid, token: gallery.token, title: gallery.bestTitle,
            category: gallery.category.rawValue, pages: gallery.pages, date: Date()
        )
        record.titleJpn = gallery.titleJpn
        record.thumb = gallery.thumb
        record.posted = gallery.posted
        record.uploader = gallery.uploader
        record.rating = gallery.rating
        record.simpleTags = gallery.simpleTags
        record.simpleLanguage = gallery.simpleLanguage
        do {
            try EhDatabase.shared.insertLocalFavorite(record)
            postFavoriteUpdate(gid: gallery.gid, local: true)
            EhToast.success("已添加至本地收藏")
            return true
        } catch {
            debugLog("[GalleryActionService] Add local favorite failed: \(error)")
            EhToast.failure("添加收藏失败")
            return false
        }
    }

    @discardableResult
    func removeFavorite(gid: Int64, token: String, context: CloudFavoriteContext? = nil) async throws -> FavoriteLocation {
        let context = context ?? cloudFavoriteContext
        do {
            return try await Self.removePreferredFavorite(
                readLocal: { try EhDatabase.shared.containsLocalFavorite(gid: gid) },
                removeLocal: {
                    try self.removeLocalFavorite(gid: gid)
                    EhToast.success("已移出本地收藏")
                },
                removeCloud: {
                    try await self.mutateCloudFavorite(gid: gid, token: token, slot: -1, context: context) {
                        EhToast.success("已取消云端收藏")
                    }
                }
            )
        } catch {
            if isCurrentCloudFavoriteContext(context) { EhToast.failure("取消收藏失败") }
            throw error
        }
    }

    func removeLocalFavorite(gid: Int64) throws {
        try EhDatabase.shared.deleteLocalFavorite(gid: gid)
        postFavoriteUpdate(gid: gid, local: false)
    }

    /// A single notification for an atomic bulk import, without one reload per row.
    func localFavoritesDidImport() {
        GalleryStatusCache.shared.reloadLocalFavorites()
        NotificationCenter.default.post(name: .galleryFavoriteChanged, object: nil,
                                        userInfo: ["localBulk": true])
    }

    func recordCloudFavorite(gid: Int64, slot: Int) {
        if var cached = GalleryCache.shared.getDetail(gid: gid) {
            cached.isFavorited = slot >= 0
            cached.info.favoriteSlot = slot
            GalleryCache.shared.putDetail(cached)
        }
        GalleryCache.shared.clearListCache()
        postFavoriteUpdate(gid: gid, cloudSlot: slot)
    }

    private func postFavoriteUpdate(gid: Int64, local: Bool? = nil, cloudSlot: Int? = nil) {
        var data: [String: Any] = ["gid": gid]
        if let local { data["local"] = local }
        if let cloudSlot { data["cloudSlot"] = cloudSlot }
        NotificationCenter.default.post(name: .galleryFavoriteChanged, object: nil, userInfo: data)
    }

    // MARK: - 下载

    /// 下载前要不要先问标签。对齐 Android CommonOperations.startDownload：
    /// 设了默认标签 → 直接下；一个标签都没建过 → 直接下；否则弹选择器。
    ///
    /// iOS 端此前完全没有这一步：建了下载标签也没用，所有本子一律进默认组。
    func downloadLabelChoiceNeeded() -> Bool {
        if AppSettings.shared.hasDefaultDownloadLabel { return false }
        let labels = (try? EhDatabase.shared.getAllDownloadLabels()) ?? []
        return !labels.isEmpty
    }

    /// Show the committed queue result rather than assuming every request enqueued a task.
    func startDownload(gallery: GalleryInfo, label: String? = nil, quality: DownloadQuality? = nil) async {
        let resolved = label ?? (AppSettings.shared.hasDefaultDownloadLabel
                                 ? AppSettings.shared.defaultDownloadLabel : nil)
        let outcome = await DownloadManager.shared.startDownload(gallery: gallery, label: resolved, quality: quality)
        switch outcome {
        case .enqueued, .resumed:
            NotificationCenter.default.post(name: .galleryDownloadChanged, object: nil,
                                            userInfo: ["gid": gallery.gid, "downloading": true])
            EhToast.success(outcome == .enqueued ? "已加入下载队列" : "已恢复下载任务")
        case .alreadyWaiting:
            EhToast.info("任务已在下载队列中")
        case .alreadyDownloading:
            EhToast.info("任务正在下载")
        case .alreadyFinished:
            EhToast.info("已完成下载")
        case .offlineImport:
            EhToast.info("离线导入项目不支持下载")
        case .unavailable:
            EhToast.failure("无法开始下载")
        }
    }

    /// 当前是否在计费网络上，且用户开了"移动网络下载前提醒"
    /// (对齐 Android Settings.KEY_CELLULAR_NETWORK_WARNING)
    var shouldWarnAboutCellular: Bool {
        guard AppSettings.shared.cellularNetworkWarning else { return false }
        return NetworkReachability.isConstrainedOrCellular
    }

    // MARK: - 分享/复制

    /// 获取画廊 URL
    func galleryURL(gid: Int64, token: String) -> String {
        let site = Self.siteBaseURL
        return "\(site)g/\(gid)/\(token)/"
    }

    /// 复制画廊链接到剪贴板
    func copyLink(gid: Int64, token: String) {
        let url = galleryURL(gid: gid, token: token)
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        #else
        UIPasteboard.general.string = url
        #endif
        EhToast.success("已复制链接")
    }

    // MARK: - 站点工具

    /// 统一站点 URL — 替代分散在 4 个文件中的 getSite() 重复代码
    /// 对齐 Android: 尊重用户的站点选择，只要已登录 (有 memberId + passHash) 就允许使用 ExHentai
    /// ⚠️ 旧逻辑要求 igneous cookie 才放行 ExHentai，但 igneous 只有首次访问 exhentai.org 后才会种下
    ///    这造成了鸡生蛋的死循环 — 用户无法首次访问 exhentai.org 获取 igneous
    ///    Sad Panda 检测已在 EhAPI.checkResponse 中处理，access 失败时会自动回退
    static var siteBaseURL: String {
        switch AppSettings.shared.gallerySite {
        case .exHentai:
            // 检查是否有登录 Cookie (对齐 Android: 只要登录就允许访问 ExHentai)
            let cookies = HTTPCookieStorage.shared.cookies(for: URL(string: "https://exhentai.org")!) ?? []
            let hasAuth = cookies.contains { $0.name == "ipb_member_id" } &&
                          cookies.contains { $0.name == "ipb_pass_hash" }
            return hasAuth ? "https://exhentai.org/" : "https://e-hentai.org/"
        case .eHentai:
            return "https://e-hentai.org/"
        }
    }

    /// 站点切换通知 — 切换站点后通知列表刷新
    static let siteChangedNotification = Notification.Name("gallerySiteChanged")
}

// MARK: - 通知名称

extension Notification.Name {
    /// 画廊收藏状态变化 (userInfo: gid, favorited, slot?)
    static let galleryFavoriteChanged = Notification.Name("galleryFavoriteChanged")
    /// 画廊下载状态变化 (userInfo: gid, downloading)
    ///
    /// 此前只有收藏有通知，下载没有：点了下载之后下载页、列表行全都不动，
    /// 得杀进程重进才看得到。
    static let galleryDownloadChanged = Notification.Name("galleryDownloadChanged")
    /// 浏览/阅读历史变化 (userInfo: gid)
    static let galleryHistoryChanged = Notification.Name("galleryHistoryChanged")
    static let continueReadingProgressSaved = Notification.Name("continueReadingProgressSaved")
}
