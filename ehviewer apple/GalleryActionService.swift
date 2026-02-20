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

    /// 快速收藏 — 使用默认收藏夹 (对齐 Android: onModifyFavorite with defaultFavSlot)
    /// - 默认 slot >= 0: 直接添加到云端
    /// - 默认 slot == -1: 添加到本地
    /// - 默认 slot == -2: 返回 false，调用方应弹出选择器
    /// - Returns: true 表示已执行操作, false 表示需要弹出选择器
    @discardableResult
    func quickFavorite(gallery: GalleryInfo) async -> Bool {
        let defaultSlot = AppSettings.shared.defaultFavSlot
        if defaultSlot >= 0 && defaultSlot <= 9 {
            do {
                try await addFavorite(gid: gallery.gid, token: gallery.token, slot: defaultSlot)
            } catch {
                return false
            }
            return true
        } else if defaultSlot == -1 {
            addLocalFavorite(gallery: gallery)
            return true
        }
        return false // 需要弹出选择器
    }

    /// 添加云端收藏 (Fix B-3: 失败时抛出错误，让调用方回滚)
    func addFavorite(gid: Int64, token: String, slot: Int) async throws {
        try await EhAPI.shared.addFavorites(gid: gid, token: token, dstCat: slot)
        AppSettings.shared.recentFavCat = slot
        NotificationCenter.default.post(name: .galleryFavoriteChanged,
                                        object: nil,
                                        userInfo: ["gid": gid, "favorited": true, "slot": slot])
    }

    /// 添加本地收藏 (对齐 Android FAV_CAT_LOCAL = -1)
    func addLocalFavorite(gallery: GalleryInfo) {
        var record = LocalFavoriteRecord(
            gid: gallery.gid, token: gallery.token, title: gallery.bestTitle,
            category: gallery.category.rawValue, pages: gallery.pages, date: Date()
        )
        record.titleJpn = gallery.titleJpn
        record.thumb = gallery.thumb
        record.posted = gallery.posted
        record.uploader = gallery.uploader
        record.rating = gallery.rating
        do {
            try EhDatabase.shared.insertLocalFavorite(record)
            NotificationCenter.default.post(name: .galleryFavoriteChanged,
                                            object: nil,
                                            userInfo: ["gid": gallery.gid, "favorited": true, "slot": -1])
        } catch {
            debugLog("[GalleryActionService] Add local favorite failed: \(error)")
        }
    }

    /// 取消收藏 (Fix B-3: 失败时抛出错误，让调用方回滚)
    func removeFavorite(gid: Int64, token: String) async throws {
        try await EhAPI.shared.addFavorites(gid: gid, token: token, dstCat: -1)
        try? EhDatabase.shared.deleteLocalFavorite(gid: gid)
        NotificationCenter.default.post(name: .galleryFavoriteChanged,
                                        object: nil,
                                        userInfo: ["gid": gid, "favorited": false])
    }

    // MARK: - 下载

    /// 快速下载 (Fix A-1: 已失败/已暂停的任务允许重新启动)
    func startDownload(gallery: GalleryInfo) async {
        await DownloadManager.shared.startDownload(gallery: gallery)
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
}
