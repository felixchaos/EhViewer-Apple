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

    /// 把当前 AppSettings 映射进 EhConfig 并写入 uconfig Cookie
    ///
    /// 需要在 App 启动、以及任何相关设置变更后调用。
    public static func apply() {
        let settings = AppSettings.shared
        let config = EhConfig.shared

        // 图片分辨率 (xr)
        config.imageSize = settings.imageResolution.rawValue

        // 排除语言 (xl) —— 形如 "1x-2x-3"，服务端自己解析
        config.excludedLanguages = settings.excludedLanguages ?? ""

        // 排除标签命名空间 (xns) —— 位掩码
        config.excludedNamespaces = settings.excludedTagNamespaces

        // 默认分类 (cats) —— 位掩码，语义是"要排除的分类"
        config.defaultCategories = settings.defaultCategories

        // 预览尺寸 (tp): 0 = 普通, 其它 = 大图
        config.previewSize = settings.thumbResolution == 0
            ? EhConfig.previewSizeNormal
            : EhConfig.previewSizeLarge

        // 标题语言跟随"显示日文标题"设置
        config.galleryTitle = settings.showJpnTitle
            ? EhConfig.galleryTitleJapanese
            : EhConfig.galleryTitleDefault

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
