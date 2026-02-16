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
            await addFavorite(gid: gallery.gid, token: gallery.token, slot: defaultSlot)
            return true
        } else if defaultSlot == -1 {
            addLocalFavorite(gallery: gallery)
            return true
        }
        return false // 需要弹出选择器
    }

    /// 添加云端收藏 (对齐 Android EhEngine.addFavorites)
    func addFavorite(gid: Int64, token: String, slot: Int) async {
        do {
            try await EhAPI.shared.addFavorites(gid: gid, token: token, dstCat: slot)
            AppSettings.shared.recentFavCat = slot
            NotificationCenter.default.post(name: .galleryFavoriteChanged,
                                            object: nil,
                                            userInfo: ["gid": gid, "favorited": true, "slot": slot])
        } catch {
            print("[GalleryActionService] Add favorite failed: \(error)")
        }
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
            print("[GalleryActionService] Add local favorite failed: \(error)")
        }
    }

    /// 取消收藏 — 同时移除云端和本地 (对齐 Android: 取消收藏清除所有源)
    func removeFavorite(gid: Int64, token: String) async {
        do {
            try await EhAPI.shared.addFavorites(gid: gid, token: token, dstCat: -1)
            try? EhDatabase.shared.deleteLocalFavorite(gid: gid)
            NotificationCenter.default.post(name: .galleryFavoriteChanged,
                                            object: nil,
                                            userInfo: ["gid": gid, "favorited": false])
        } catch {
            print("[GalleryActionService] Remove favorite failed: \(error)")
        }
    }

    // MARK: - 下载

    /// 快速下载 — 检查状态后启动 (对齐 Android CommonOperations.startDownload)
    func startDownload(gallery: GalleryInfo) async {
        let state = await DownloadManager.shared.getTaskState(gid: gallery.gid)
        if state != DownloadManager.stateInvalid {
            // 已在下载队列
            return
        }
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
    /// 包含 ExHentai cookie 验证回退逻辑 (对齐 Android: 检查 igneous cookie)
    static var siteBaseURL: String {
        switch AppSettings.shared.gallerySite {
        case .exHentai:
            let cookies = HTTPCookieStorage.shared.cookies(for: URL(string: "https://exhentai.org")!) ?? []
            let hasEX = cookies.contains { $0.name == "igneous" && !$0.value.isEmpty && $0.value != "mystery" }
            return hasEX ? "https://exhentai.org/" : "https://e-hentai.org/"
        case .eHentai:
            return "https://e-hentai.org/"
        }
    }
}

// MARK: - 通知名称

extension Notification.Name {
    /// 画廊收藏状态变化 (userInfo: gid, favorited, slot?)
    static let galleryFavoriteChanged = Notification.Name("galleryFavoriteChanged")
}
