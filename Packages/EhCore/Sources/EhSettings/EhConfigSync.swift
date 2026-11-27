//
//  EhConfigSync.swift
//  EhSettings
//
//  把本地设置同步成服务端的 uconfig Cookie
//
//  E-Hentai 的「图片分辨率 / 排除语言 / 排除标签命名空间 / 默认分类 / 预览尺寸」
//  都不是 URL 参数，而是存在服务端的用户配置里，通过 `uconfig` Cookie 下发。
//  这也是为什么这几个设置项以前在设置页里点了完全没反应 ——
//  `EhConfig` 早就写好了序列化逻辑，只是从来没有人把它写进 Cookie。
//

import Foundation

@MainActor
public enum EhConfigSync {

    private static let cookieName = EhConfig.keyUconfig
    private static let domains = [".e-hentai.org", ".exhentai.org"]

    // This is both the restore-change check and the mapping used to publish a
    // configuration. Download quality is deliberately not part of it.
    struct Preferences: Equatable {
        var imageSize: String
        var excludedLanguages: String
        var excludedNamespaces: Int
        var defaultCategories: Int
        var previewSize: String
        var galleryTitle: String

        @MainActor
        init(settings: AppSettings) {
            imageSize = settings.imageResolution.rawValue
            excludedLanguages = settings.excludedLanguages ?? ""
            excludedNamespaces = settings.excludedTagNamespaces
            defaultCategories = settings.defaultCategories
            previewSize = settings.thumbResolution == 0 ? EhConfig.previewSizeNormal : EhConfig.previewSizeLarge
            galleryTitle = settings.showJpnTitle ? EhConfig.galleryTitleJapanese : EhConfig.galleryTitleDefault
        }
    }

    /// 把当前 AppSettings 映射进 EhConfig 并写入 uconfig Cookie
    public static func apply() {
        let preferences = Preferences(settings: .shared)
        let config = EhConfig.shared
        config.imageSize = preferences.imageSize
        config.excludedLanguages = preferences.excludedLanguages
        config.excludedNamespaces = preferences.excludedNamespaces
        config.defaultCategories = preferences.defaultCategories
        config.previewSize = preferences.previewSize
        config.galleryTitle = preferences.galleryTitle

        config.setDirty()
        writeCookie(config.uconfig())
    }

    private static func writeCookie(_ value: String) {
        guard !value.isEmpty else { return }
        for domain in domains {
            guard let cookie = HTTPCookie(properties: [
                .name: cookieName,
                .value: value,
                .domain: domain,
                .path: "/",
                // uconfig 是长期配置，给一年
                .expires: Date().addingTimeInterval(365 * 24 * 3600),
            ]) else { continue }
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }
}
