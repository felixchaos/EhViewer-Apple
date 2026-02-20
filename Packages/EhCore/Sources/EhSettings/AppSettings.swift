import Foundation

// MARK: - 全局设置系统 (对应 Android Settings.java)
//
// 审计说明 S-1:
// 原设计中所有属性均标记 @ObservationIgnored，导致 @Observable 完全失效。
// SwiftUI View 读取这些属性时不会被 observation tracking 捕获，设置变化不触发 UI 刷新。
//
// 修复策略:
// - 需要实时 UI 联动的属性 (listMode, showJpnTitle, isLogin 等) 改为支持 observation
//   使用 access/withMutation 包裹 UserDefaults 读写，让 @Observable 正常追踪
// - 不影响 UI 的纯后台配置 (downloadTimeout, downloadDelay 等) 保持 @ObservationIgnored
//   避免不必要的 View 重绘

@Observable
public final class AppSettings: @unchecked Sendable {
    public static let shared = AppSettings()

    // ──────────────────────────────────────────
    // MARK: - 辅助方法: UserDefaults 读写 + Observation 桥接
    // ──────────────────────────────────────────
    
    /// 读取 UserDefaults 并触发 observation access
    @ObservationIgnored
    private let _defaults = UserDefaults.standard

    // MARK: - 站点选择 (UI 联动)
    public var gallerySite: EhSite {
        get {
            access(keyPath: \.gallerySite)
            return EhSite(rawValue: _defaults.integer(forKey: "gallery_site")) ?? .eHentai
        }
        set {
            guard newValue.rawValue != _defaults.integer(forKey: "gallery_site") else { return }
            withMutation(keyPath: \.gallerySite) {
                _defaults.set(newValue.rawValue, forKey: "gallery_site")
            }
        }
    }

    // MARK: - 网络
    // 注意: Domain Fronting 在 iOS/macOS 的 URLSession 中无法正确工作
    // (URL 域名替换为 IP 会破坏 TLS SNI，导致 Cloudflare 返回错误证书)
    // Android OkHttp 的 Dns 接口在 socket 层替换 IP 不影响 TLS，但 URLSession 无此机制
    // 因此该选项默认关闭，依赖系统 DNS / 代理 / VPN 解析域名
    @ObservationIgnored
    public var domainFronting: Bool {
        get { _defaults.object(forKey: "domain_fronting") as? Bool ?? false }
        set { _defaults.set(newValue, forKey: "domain_fronting") }
    }

    @ObservationIgnored
    public var dnsOverHttps: Bool {
        get { _defaults.bool(forKey: "dns_over_https") }
        set { _defaults.set(newValue, forKey: "dns_over_https") }
    }

    @ObservationIgnored
    public var builtInHosts: Bool {
        get { _defaults.object(forKey: "built_in_hosts") as? Bool ?? false }
        set { _defaults.set(newValue, forKey: "built_in_hosts") }
    }

    // MARK: - 下载
    @ObservationIgnored
    public var multiThreadDownload: Int {
        get { max(1, min(10, _defaults.integer(forKey: "multi_thread_download"))) }
        set { _defaults.set(max(1, min(10, newValue)), forKey: "multi_thread_download") }
    }

    @ObservationIgnored
    public var preloadImage: Int {
        get { _defaults.object(forKey: "preload_image") as? Int ?? 5 }
        set { _defaults.set(newValue, forKey: "preload_image") }
    }

    @ObservationIgnored
    public var downloadDelay: Int {
        get { _defaults.integer(forKey: "download_delay") }
        set { _defaults.set(newValue, forKey: "download_delay") }
    }

    @ObservationIgnored
    public var downloadTimeout: Int {
        get { _defaults.object(forKey: "download_timeout") as? Int ?? 60 }
        set { _defaults.set(newValue, forKey: "download_timeout") }
    }

    @ObservationIgnored
    public var downloadOriginImage: Bool {
        get { _defaults.bool(forKey: "download_origin_image") }
        set { _defaults.set(newValue, forKey: "download_origin_image") }
    }

    /// 图片分辨率 (对应 Android EhConfig.IMAGE_SIZE_*)
    /// "a" = 自动, "780", "980", "1280", "1600", "2400"
    @ObservationIgnored
    public var imageResolution: ImageResolution {
        get {
            let raw = _defaults.string(forKey: "image_resolution") ?? "a"
            return ImageResolution(rawValue: raw) ?? .auto
        }
        set { _defaults.set(newValue.rawValue, forKey: "image_resolution") }
    }

    // MARK: - 缓存
    @ObservationIgnored
    public var readCacheSize: Int {
        get {
            let v = _defaults.object(forKey: "read_cache_size") as? Int ?? 320
            return max(40, min(640, v))
        }
        set { _defaults.set(max(40, min(640, newValue)), forKey: "read_cache_size") }
    }

    // MARK: - 外观 (UI 联动)
    public var listMode: ListMode {
        get {
            access(keyPath: \.listMode)
            return ListMode(rawValue: _defaults.integer(forKey: "list_mode")) ?? .list
        }
        set {
            guard newValue.rawValue != _defaults.integer(forKey: "list_mode") else { return }
            withMutation(keyPath: \.listMode) {
                _defaults.set(newValue.rawValue, forKey: "list_mode")
            }
        }
    }

    public var showJpnTitle: Bool {
        get {
            access(keyPath: \.showJpnTitle)
            return _defaults.bool(forKey: "show_jpn_title")
        }
        set {
            guard newValue != _defaults.bool(forKey: "show_jpn_title") else { return }
            withMutation(keyPath: \.showJpnTitle) {
                _defaults.set(newValue, forKey: "show_jpn_title")
            }
        }
    }

    // MARK: - 用户身份 (UI 联动)
    public var isLogin: Bool {
        get {
            access(keyPath: \.isLogin)
            return _defaults.bool(forKey: "is_login")
        }
        set {
            guard newValue != _defaults.bool(forKey: "is_login") else { return }
            withMutation(keyPath: \.isLogin) {
                _defaults.set(newValue, forKey: "is_login")
            }
        }
    }

    public var displayName: String? {
        get {
            access(keyPath: \.displayName)
            return _defaults.string(forKey: "display_name")
        }
        set {
            guard newValue != _defaults.string(forKey: "display_name") else { return }
            withMutation(keyPath: \.displayName) {
                _defaults.set(newValue, forKey: "display_name")
            }
        }
    }

    public var userId: String? {
        get {
            access(keyPath: \.userId)
            return _defaults.string(forKey: "user_id")
        }
        set {
            guard newValue != _defaults.string(forKey: "user_id") else { return }
            withMutation(keyPath: \.userId) {
                _defaults.set(newValue, forKey: "user_id")
            }
        }
    }

    public var avatar: String? {
        get {
            access(keyPath: \.avatar)
            return _defaults.string(forKey: "avatar")
        }
        set {
            guard newValue != _defaults.string(forKey: "avatar") else { return }
            withMutation(keyPath: \.avatar) {
                _defaults.set(newValue, forKey: "avatar")
            }
        }
    }

    // MARK: - 外观 (UI 联动)
    public var theme: Int {
        get {
            access(keyPath: \.theme)
            return _defaults.integer(forKey: "theme")
        }
        set {
            guard newValue != _defaults.integer(forKey: "theme") else { return }
            withMutation(keyPath: \.theme) {
                _defaults.set(newValue, forKey: "theme")
            }
        }
    }

    public var launchPage: Int {
        get {
            access(keyPath: \.launchPage)
            return _defaults.integer(forKey: "launch_page")
        }
        set {
            guard newValue != _defaults.integer(forKey: "launch_page") else { return }
            withMutation(keyPath: \.launchPage) {
                _defaults.set(newValue, forKey: "launch_page")
            }
        }
    }

    @ObservationIgnored
    public var thumbSize: Int {
        get { _defaults.object(forKey: "thumb_size") as? Int ?? 1 }
        set { _defaults.set(newValue, forKey: "thumb_size") }
    }

    public var showGalleryPages: Bool {
        get {
            access(keyPath: \.showGalleryPages)
            return _defaults.bool(forKey: "show_gallery_pages")
        }
        set {
            guard newValue != _defaults.bool(forKey: "show_gallery_pages") else { return }
            withMutation(keyPath: \.showGalleryPages) {
                _defaults.set(newValue, forKey: "show_gallery_pages")
            }
        }
    }

    public var showTagTranslations: Bool {
        get {
            access(keyPath: \.showTagTranslations)
            return _defaults.object(forKey: "show_tag_translations") as? Bool ?? true
        }
        set {
            let current = _defaults.object(forKey: "show_tag_translations") as? Bool ?? true
            guard newValue != current else { return }
            withMutation(keyPath: \.showTagTranslations) {
                _defaults.set(newValue, forKey: "show_tag_translations")
            }
        }
    }

    public var showGalleryComment: Bool {
        get {
            access(keyPath: \.showGalleryComment)
            return _defaults.object(forKey: "show_gallery_comment") as? Bool ?? true
        }
        set {
            let current = _defaults.object(forKey: "show_gallery_comment") as? Bool ?? true
            guard newValue != current else { return }
            withMutation(keyPath: \.showGalleryComment) {
                _defaults.set(newValue, forKey: "show_gallery_comment")
            }
        }
    }

    public var showGalleryRating: Bool {
        get {
            access(keyPath: \.showGalleryRating)
            return _defaults.object(forKey: "show_gallery_rating") as? Bool ?? true
        }
        set {
            let current = _defaults.object(forKey: "show_gallery_rating") as? Bool ?? true
            guard newValue != current else { return }
            withMutation(keyPath: \.showGalleryRating) {
                _defaults.set(newValue, forKey: "show_gallery_rating")
            }
        }
    }

    public var showReadProgress: Bool {
        get {
            access(keyPath: \.showReadProgress)
            return _defaults.object(forKey: "show_read_progress") as? Bool ?? true
        }
        set {
            let current = _defaults.object(forKey: "show_read_progress") as? Bool ?? true
            guard newValue != current else { return }
            withMutation(keyPath: \.showReadProgress) {
                _defaults.set(newValue, forKey: "show_read_progress")
            }
        }
    }

    /// 大屏幕列表布局模式 (对齐 Android: 0=自适应双栏, 1=全宽单列表)
    @ObservationIgnored
    public var wideScreenListMode: Int {
        get { _defaults.integer(forKey: "wide_screen_list_mode") }
        set { _defaults.set(newValue, forKey: "wide_screen_list_mode") }
    }

    @ObservationIgnored
    public var showEhEvents: Bool {
        get { _defaults.object(forKey: "show_eh_events") as? Bool ?? true }
        set { _defaults.set(newValue, forKey: "show_eh_events") }
    }

    @ObservationIgnored
    public var showEhLimits: Bool {
        get { _defaults.object(forKey: "show_eh_limits") as? Bool ?? true }
        set { _defaults.set(newValue, forKey: "show_eh_limits") }
    }

    // MARK: - 过滤 / 搜索
    @ObservationIgnored
    public var defaultCategories: Int {
        get { _defaults.object(forKey: "default_categories") as? Int ?? 0x3FF }
        set { _defaults.set(newValue, forKey: "default_categories") }
    }

    @ObservationIgnored
    public var excludedTagNamespaces: Int {
        get { _defaults.integer(forKey: "excluded_tag_namespaces") }
        set { _defaults.set(newValue, forKey: "excluded_tag_namespaces") }
    }

    @ObservationIgnored
    public var excludedLanguages: String? {
        get { _defaults.string(forKey: "excluded_languages") }
        set { _defaults.set(newValue, forKey: "excluded_languages") }
    }

    @ObservationIgnored
    public var cellularNetworkWarning: Bool {
        get { _defaults.bool(forKey: "cellular_network_warning") }
        set { _defaults.set(newValue, forKey: "cellular_network_warning") }
    }

    // MARK: - 阅读器
    @ObservationIgnored
    public var readingDirection: Int {
        get { _defaults.object(forKey: "reading_direction") as? Int ?? 1 }
        set { _defaults.set(newValue, forKey: "reading_direction") }
    }

    @ObservationIgnored
    public var pageScaling: Int {
        get { _defaults.object(forKey: "page_scaling") as? Int ?? 3 }
        set { _defaults.set(newValue, forKey: "page_scaling") }
    }

    @ObservationIgnored
    public var startPosition: Int {
        get { _defaults.integer(forKey: "start_position") }
        set { _defaults.set(newValue, forKey: "start_position") }
    }

    @ObservationIgnored
    public var keepScreenOn: Bool {
        get { _defaults.bool(forKey: "keep_screen_on") }
        set { _defaults.set(newValue, forKey: "keep_screen_on") }
    }

    @ObservationIgnored
    public var readingFullscreen: Bool {
        get { _defaults.object(forKey: "reading_fullscreen") as? Bool ?? true }
        set { _defaults.set(newValue, forKey: "reading_fullscreen") }
    }

    @ObservationIgnored
    public var showClock: Bool {
        get { _defaults.object(forKey: "gallery_show_clock") as? Bool ?? true }
        set { _defaults.set(newValue, forKey: "gallery_show_clock") }
    }

    @ObservationIgnored
    public var showProgress: Bool {
        get { _defaults.object(forKey: "gallery_show_progress") as? Bool ?? true }
        set { _defaults.set(newValue, forKey: "gallery_show_progress") }
    }

    @ObservationIgnored
    public var showBattery: Bool {
        get { _defaults.object(forKey: "gallery_show_battery") as? Bool ?? true }
        set { _defaults.set(newValue, forKey: "gallery_show_battery") }
    }

    @ObservationIgnored
    public var customScreenLightness: Bool {
        get { _defaults.bool(forKey: "custom_screen_lightness") }
        set { _defaults.set(newValue, forKey: "custom_screen_lightness") }
    }

    @ObservationIgnored
    public var screenLightness: Int {
        get { _defaults.object(forKey: "screen_lightness") as? Int ?? 50 }
        set { _defaults.set(newValue, forKey: "screen_lightness") }
    }

    // MARK: - 阅读器 (新增)

    /// 音量键翻页
    @ObservationIgnored
    public var volumePage: Bool {
        get { _defaults.bool(forKey: "volume_page") }
        set { _defaults.set(newValue, forKey: "volume_page") }
    }

    /// 反转音量键
    @ObservationIgnored
    public var reverseVolumePage: Bool {
        get { _defaults.bool(forKey: "reverse_volume_page") }
        set { _defaults.set(newValue, forKey: "reverse_volume_page") }
    }

    /// 显示页面间距
    @ObservationIgnored
    public var showPageInterval: Bool {
        get { _defaults.bool(forKey: "show_page_interval") }
        set { _defaults.set(newValue, forKey: "show_page_interval") }
    }

    /// 屏幕旋转 (0=跟随系统, 1=竖屏, 2=横屏)
    @ObservationIgnored
    public var screenRotation: Int {
        get { _defaults.integer(forKey: "screen_rotation") }
        set { _defaults.set(newValue, forKey: "screen_rotation") }
    }

    /// 自动翻页延迟 (秒)
    @ObservationIgnored
    public var autoPageInterval: Int {
        get { _defaults.object(forKey: "auto_page_interval") as? Int ?? 5 }
        set { _defaults.set(newValue, forKey: "auto_page_interval") }
    }

    /// 色彩滤镜 (护眼模式)
    @ObservationIgnored
    public var colorFilter: Bool {
        get { _defaults.bool(forKey: "color_filter") }
        set { _defaults.set(newValue, forKey: "color_filter") }
    }

    /// 色彩滤镜颜色
    @ObservationIgnored
    public var colorFilterColor: Int {
        get { _defaults.object(forKey: "color_filter_color") as? Int ?? 0x20000000 }
        set { _defaults.set(newValue, forKey: "color_filter_color") }
    }

    // MARK: - 收藏
    @ObservationIgnored
    public var recentFavCat: Int {
        get { _defaults.object(forKey: "recent_fav_cat") as? Int ?? -1 }
        set { _defaults.set(newValue, forKey: "recent_fav_cat") }
    }

    @ObservationIgnored
    public var defaultFavSlot: Int {
        get { _defaults.object(forKey: "default_favorite_2") as? Int ?? -2 }
        set { _defaults.set(newValue, forKey: "default_favorite_2") }
    }

    /// 收藏夹名称 (0-9)
    public func favCatName(_ index: Int) -> String {
        _defaults.string(forKey: "fav_cat_\(index)") ?? "Favorites \(index)"
    }

    public func setFavCatName(_ index: Int, _ name: String) {
        _defaults.set(name, forKey: "fav_cat_\(index)")
    }

    /// 收藏夹计数 (0-9)
    public func favCount(_ index: Int) -> Int {
        _defaults.integer(forKey: "fav_count_\(index)")
    }

    public func setFavCount(_ index: Int, _ count: Int) {
        _defaults.set(count, forKey: "fav_count_\(index)")
    }

    // MARK: - 下载
    @ObservationIgnored
    public var recentDownloadLabel: String? {
        get { _defaults.string(forKey: "recent_download_label") }
        set { _defaults.set(newValue, forKey: "recent_download_label") }
    }

    @ObservationIgnored
    public var hasDefaultDownloadLabel: Bool {
        get { _defaults.bool(forKey: "has_default_download_label") }
        set { _defaults.set(newValue, forKey: "has_default_download_label") }
    }

    @ObservationIgnored
    public var defaultDownloadLabel: String? {
        get { _defaults.string(forKey: "default_download_label") }
        set { _defaults.set(newValue, forKey: "default_download_label") }
    }

    /// 是否启用灵动岛 (Live Activity) 显示下载进度 (仅 iOS)
    @ObservationIgnored
    public var showLiveActivity: Bool {
        get { _defaults.object(forKey: "show_live_activity") as? Bool ?? true }
        set { _defaults.set(newValue, forKey: "show_live_activity") }
    }

    // MARK: - 首次启动引导
    
    /// 是否需要显示 18+ 警告 (首次启动时显示) — UI 联动
    public var showWarning: Bool {
        get {
            access(keyPath: \.showWarning)
            return _defaults.object(forKey: "show_warning") as? Bool ?? true
        }
        set {
            let current = _defaults.object(forKey: "show_warning") as? Bool ?? true
            guard newValue != current else { return }
            withMutation(keyPath: \.showWarning) {
                _defaults.set(newValue, forKey: "show_warning")
            }
        }
    }
    
    /// 是否已选择站点 (首次启动引导) — UI 联动
    public var hasSelectedSite: Bool {
        get {
            access(keyPath: \.hasSelectedSite)
            return _defaults.bool(forKey: "has_selected_site")
        }
        set {
            guard newValue != _defaults.bool(forKey: "has_selected_site") else { return }
            withMutation(keyPath: \.hasSelectedSite) {
                _defaults.set(newValue, forKey: "has_selected_site")
            }
        }
    }

    /// 是否跳过登录 (游客模式) — UI 联动
    public var skipSignIn: Bool {
        get {
            access(keyPath: \.skipSignIn)
            return _defaults.bool(forKey: "skip_sign_in")
        }
        set {
            guard newValue != _defaults.bool(forKey: "skip_sign_in") else { return }
            withMutation(keyPath: \.skipSignIn) {
                _defaults.set(newValue, forKey: "skip_sign_in")
            }
        }
    }

    // MARK: - 隐私安全 (UI 联动)
    public var enableSecurity: Bool {
        get {
            access(keyPath: \.enableSecurity)
            return _defaults.bool(forKey: "enable_secure")
        }
        set {
            guard newValue != _defaults.bool(forKey: "enable_secure") else { return }
            withMutation(keyPath: \.enableSecurity) {
                _defaults.set(newValue, forKey: "enable_secure")
            }
        }
    }
    
    /// 安全延迟时间 (秒) - 应用进入后台后多久需要重新认证
    @ObservationIgnored
    public var securityDelay: Int {
        get { _defaults.object(forKey: "security_delay") as? Int ?? 0 }
        set { _defaults.set(newValue, forKey: "security_delay") }
    }

    // MARK: - 高级
    @ObservationIgnored
    public var saveParseErrorBody: Bool {
        get { _defaults.bool(forKey: "save_parse_error_body") }
        set { _defaults.set(newValue, forKey: "save_parse_error_body") }
    }

    @ObservationIgnored
    public var historyInfoSize: Int {
        get { max(100, _defaults.object(forKey: "history_info_size") as? Int ?? 100) }
        set { _defaults.set(max(100, newValue), forKey: "history_info_size") }
    }

    // MARK: - Android 对齐: 附加设置

    /// 详情页信息大小 (对齐 Android Settings.KEY_DETAIL_SIZE; 0=normal, 1=large)
    @ObservationIgnored
    public var detailSize: Int {
        get { _defaults.integer(forKey: "detail_size") }
        set { _defaults.set(newValue, forKey: "detail_size") }
    }

    /// 缩略图分辨率 (对齐 Android Settings.KEY_THUMB_RESOLUTION; 0=normal, 1=large)
    @ObservationIgnored
    public var thumbResolution: Int {
        get { _defaults.integer(forKey: "thumb_resolution") }
        set { _defaults.set(newValue, forKey: "thumb_resolution") }
    }

    /// 修复缩略图链接 (对齐 Android Settings.KEY_FIX_THUMB_URL)
    @ObservationIgnored
    public var fixThumbUrl: Bool {
        get { _defaults.bool(forKey: "fix_thumb_url") }
        set { _defaults.set(newValue, forKey: "fix_thumb_url") }
    }

    /// 内置 ExHentai Hosts (对齐 Android Settings.KEY_BUILT_IN_HOSTS_EX)
    @ObservationIgnored
    public var builtExHosts: Bool {
        get { _defaults.object(forKey: "built_ex_hosts") as? Bool ?? false }
        set { _defaults.set(newValue, forKey: "built_ex_hosts") }
    }

    /// 媒体扫描 (对齐 Android Settings.KEY_MEDIA_SCAN)
    @ObservationIgnored
    public var mediaScan: Bool {
        get { _defaults.bool(forKey: "media_scan") }
        set { _defaults.set(newValue, forKey: "media_scan") }
    }

    /// 导航栏主题色 (对齐 Android Settings.KEY_APPLY_NAV_BAR_THEME_COLOR)
    @ObservationIgnored
    public var applyNavBarThemeColor: Bool {
        get { _defaults.bool(forKey: "apply_nav_bar_theme_color") }
        set { _defaults.set(newValue, forKey: "apply_nav_bar_theme_color") }
    }

    private init() {
        // 注册默认值
        _defaults.register(defaults: [
            "gallery_site": EhSite.eHentai.rawValue,
            "domain_fronting": false,   // iOS URLSession 域名前置不可靠，默认禁用
            "built_in_hosts": false,    // iOS URLSession 域名前置不可靠，默认禁用
            "multi_thread_download": 3,
            "preload_image": 5,
            "download_timeout": 60,
            "read_cache_size": 320,
            // 新增默认值
            "show_tag_translations": true,
            "show_gallery_comment": true,
            "show_gallery_rating": true,
            "show_read_progress": true,
            "show_eh_events": true,
            "show_eh_limits": true,
            "default_categories": 0x3FF,
            "reading_direction": 1,    // RTL
            "page_scaling": 3,         // FIT
            "reading_fullscreen": true,
            "gallery_show_clock": true,
            "gallery_show_progress": true,
            "gallery_show_battery": true,
            "screen_lightness": 50,
            "recent_fav_cat": -1,
            "default_favorite_2": -2,
            "thumb_size": 1,
            "image_size": "auto",
            "history_info_size": 100,
            "show_live_activity": true,
        ])
    }
}

public enum ListMode: Int, Sendable, CaseIterable {
    case list = 0
    case grid = 1
}

/// 图片分辨率选项 (对应 Android EhConfig.IMAGE_SIZE_*)
public enum ImageResolution: String, Sendable, CaseIterable, Identifiable {
    case auto = "a"      // 自动
    case x780 = "780"    // 780px
    case x980 = "980"    // 980px
    case x1280 = "1280"  // 1280px
    case x1600 = "1600"  // 1600px
    case x2400 = "2400"  // 2400px

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: return "自动"
        case .x780: return "780x"
        case .x980: return "980x"
        case .x1280: return "1280x"
        case .x1600: return "1600x"
        case .x2400: return "2400x"
        }
    }
}
