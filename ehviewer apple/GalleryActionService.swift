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

    /// 添加云端收藏 (Fix B-3: 失败时抛出错误，让调用方回滚)
    func addFavorite(gid: Int64, token: String, slot: Int) async throws {
        do {
            try await EhAPI.shared.addFavorites(gid: gid, token: token, dstCat: slot)
        } catch {
            // 对齐 Android add_to_favorite_failure
            EhToast.failure("添加收藏失败")
            throw error
        }
        EhToast.success("已添加至收藏")
        AppSettings.shared.recentFavCat = slot
        NotificationCenter.default.post(name: .galleryFavoriteChanged,
                                        object: nil,
                                        userInfo: ["gid": gid, "favorited": true, "slot": slot])
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
            NotificationCenter.default.post(name: .galleryFavoriteChanged,
                                            object: nil,
                                            userInfo: ["gid": gallery.gid, "favorited": true, "slot": -1])
            EhToast.success("已添加至本地收藏")
            return true
        } catch {
            debugLog("[GalleryActionService] Add local favorite failed: \(error)")
            EhToast.failure("添加收藏失败")
            return false
        }
    }

    /// 取消收藏 (Fix B-3: 失败时抛出错误，让调用方回滚)
    func removeFavorite(gid: Int64, token: String) async throws {
        do {
            try await EhAPI.shared.addFavorites(gid: gid, token: token, dstCat: -1)
        } catch {
            // addFavorite 有成功/失败提示，这里一条都没有：
            // 取消收藏看起来永远像是「点了没反应」
            EhToast.failure("取消收藏失败")
            throw error
        }
        try? EhDatabase.shared.deleteLocalFavorite(gid: gid)
        EhToast.success("已取消收藏")
        NotificationCenter.default.post(name: .galleryFavoriteChanged,
                                        object: nil,
                                        userInfo: ["gid": gid, "favorited": false])
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

    /// 快速下载 (Fix A-1: 已失败/已暂停的任务允许重新启动)
    ///
    /// 提示与状态缓存写在这里而不是各调用方：列表、历史、收藏、详情页
    /// 都会调它，此前只有详情页做了反馈，其余三处点下去屏幕毫无变化。
    func startDownload(gallery: GalleryInfo, label: String? = nil) async {
        // 没显式指定标签时用默认标签（可能是 nil = 默认分组）
        let resolved = label ?? (AppSettings.shared.hasDefaultDownloadLabel
                                 ? AppSettings.shared.defaultDownloadLabel : nil)
        await DownloadManager.shared.startDownload(gallery: gallery, label: resolved)
        NotificationCenter.default.post(name: .galleryDownloadChanged, object: nil,
                                        userInfo: ["gid": gallery.gid, "downloading": true])
        // 对齐 Android added_to_download_list
        EhToast.success("已添加至下载列表")
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
}
