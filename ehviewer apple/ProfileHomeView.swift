//
//  ProfileHomeView.swift
//  ehviewer apple
//
//  「我的」— 取代原「更多」标签页
//
//  原「更多」只是把底部栏放不下的入口平铺成一个 List，本身不承载任何信息。
//  改成聚合页后，账号状态、图片配额、存储占用这些「随时想瞄一眼」的信息
//  不必再进二级页；热门与排行则提到了首页顶部的横向切页，不再属于这里。
//

import SwiftUI
import EhModels
import EhAPI
import EhSettings
import EhDownload

struct ProfileHomeView: View {
    @Environment(AppState.self) private var appState

    @State private var quota: HomeDetail?
    @State private var cacheBytes: Int64 = 0
    @State private var downloadCount: Int = 0
    @State private var downloadBytes: Int64 = 0
    @State private var isLoadingQuota = false
    @State private var showLogin = false
    private var updateChecker: AppUpdateChecker { .shared }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: EhSpacing.section) {
                    EhPageHeader(title: "我的")
                        .padding(.horizontal, -EhSpacing.page)  // 页头自带页边距

                    // 更新提示放「我的」而不是首页：首页是每天要看很多次的地方，
                    // 一条常驻横幅会一直占位；而用户找版本相关的东西本来就会来这里
                    if let info = updateChecker.updateAvailable {
                        UpdateBanner(info: info)
                    }
                    accountCard
                    quickGrid
                    settingsList
                }
                .padding(.horizontal, EhSpacing.page)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .background(EhColor.groupedBackground)
            #if os(iOS)
            // 浮起导航条只在 iOS 存在，macOS 是侧边栏
            .ehTabBarAutoHide()
            #endif
            .ehCompactHeader()
            .scrollContentBackground(.hidden)
            .navigationDestination(for: ProfileRoute.self) { route in
                // 二级页一律隐藏底部浮条：它们是设置/管理类页面，
                // 没有平级切换的需要，而浮条会盖住列表最后一行与底部按钮
                route.destination
                    #if os(iOS)
                    .ehHidesTabBar()
                    #endif
            }
            .navigationDestination(for: GalleryInfo.self) { gallery in
                GalleryDetailView(gallery: gallery).id(gallery.gid)
            }
            .sheet(isPresented: $showLogin) {
                LoginView()
                    .environment(appState)
            }
            .task {
                await loadSummary()
                updateChecker.checkOnLaunchIfNeeded()
            }
            .refreshable { await loadSummary() }
        }
    }

    // MARK: - 账号卡

    private var accountCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // 头像用昵称首字母，避免为一个装饰性元素引入一次网络请求
                Text(initial)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(EhColor.accent)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(EhColor.fill))

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(EhFont.title)
                        .foregroundStyle(EhColor.label)
                    Text(siteStatusText)
                        .font(EhFont.meta)
                        .foregroundStyle(EhColor.secondaryLabel)
                }

                Spacer()

                // 未登录（含访客）时这里必须是「登录」并真的能进登录页——
                // 此前不论登录与否都指向账号资料页，访客点进去是一片空白
                if appState.isSignedIn {
                    NavigationLink(value: ProfileRoute.account) {
                        capsuleLabel("账号", filled: false)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button { showLogin = true } label: {
                        capsuleLabel("登录", filled: true)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(EhSpacing.page)

            EhHairline(inset: EhSpacing.page)

            HStack(alignment: .top, spacing: 0) {
                // 配额受 showEhLimits 控制（对齐 Android show_eh_limits）。
                // 这个设置一直只有声明、没有任何地方读它，配额卡片无条件显示。
                if AppSettings.shared.showEhLimits {
                    statColumn(
                        title: "图片配额",
                        value: quotaValueText,
                        footnote: quotaFootnote,
                        progress: quotaProgress
                    )
                }
                statColumn(
                    title: "缓存",
                    value: Self.formatBytes(cacheBytes),
                    footnote: nil,
                    progress: nil
                )
                statColumn(
                    title: "已下载",
                    value: "\(downloadCount) 本",
                    footnote: Self.formatBytes(downloadBytes),
                    progress: nil
                )
            }
            .padding(.horizontal, EhSpacing.page)
            .padding(.vertical, 14)
        }
        .ehCard()
    }

    private func statColumn(
        title: String, value: String, footnote: String?, progress: Double?
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(EhFont.footnote)
                .foregroundStyle(EhColor.tertiaryLabel)
            Text(value)
                .font(EhFont.mono(17, weight: .semibold))
                .foregroundStyle(EhColor.label)
            if let progress {
                ZStack(alignment: .leading) {
                    Capsule().fill(EhColor.fill)
                    Capsule()
                        .fill(progress > 0.85 ? EhColor.danger : EhColor.accentFill)
                        .frame(width: 62 * max(0, min(1, progress)))
                }
                .frame(width: 62, height: 3)
            }
            if let footnote {
                Text(footnote)
                    .font(EhFont.footnote)
                    .foregroundStyle(EhColor.tertiaryLabel)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 四宫格快捷入口

    private var quickGrid: some View {
        HStack(spacing: 10) {
            // 「我的标签」→「订阅标签」：顶部切页叫「订阅」，这里管理的正是
            // 它背后的标签列表，两处用同一个词才对得上
            quickEntry(.myTags, symbol: "bell", title: "订阅标签")
            // 「过滤器」而非「筛选器」：这里管理的是**屏蔽**规则（把不想看的挡掉），
            // 「筛选」在中文里更像是从结果里挑出想要的，方向相反。
            // 图标同样换成表示"挡掉"的斜杠眼，不用漏斗。
            quickEntry(.filters, symbol: "eye.slash", title: "过滤器")
            quickEntry(.hosts, symbol: "globe", title: "Hosts")
            // 站内公告受 showEhEvents 控制（对齐 Android show_eh_events）
            if AppSettings.shared.showEhEvents {
                quickEntry(.news, symbol: "envelope", title: "站内公告")
            }
        }
    }

    private func quickEntry(_ route: ProfileRoute, symbol: String, title: String) -> some View {
        NavigationLink(value: route) {
            VStack(spacing: 7) {
                // 固定 22×22 的图标框 + 统一字重。不同 SF Symbol 的字形高度差别
                // 很大（line.3.horizontal.decrease 明显矮一截），只给 font size
                // 不给框，四个格子的图标就会一个比一个小
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .regular))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(EhColor.accent)
                    .frame(width: 22, height: 22)
                Text(title)
                    .font(EhFont.footnote)
                    .foregroundStyle(EhColor.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 66)
            .ehCard()
        }
        .buttonStyle(.plain)
    }

    // MARK: - 设置入口

    private var settingsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("设置").ehSectionHeader()
                .padding(.leading, 4)

            VStack(spacing: 0) {
                ForEach(Array(SettingsEntry.all.enumerated()), id: \.element.route) { index, entry in
                    NavigationLink(value: entry.route) {
                        HStack(spacing: 12) {
                            Image(systemName: entry.symbol)
                                .font(.system(size: 15))
                                .foregroundStyle(entry.tint)
                                .frame(width: 22)
                            Text(entry.title)
                                .font(EhFont.body)
                                .foregroundStyle(EhColor.label)
                            Spacer()
                            if let value = entry.value() {
                                Text(value)
                                    .font(EhFont.meta)
                                    .foregroundStyle(EhColor.tertiaryLabel)
                            }
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(EhColor.tertiaryLabel)
                        }
                        .padding(.horizontal, EhSpacing.page)
                        .frame(height: EhSize.minTapTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if index < SettingsEntry.all.count - 1 {
                        EhHairline(inset: EhSpacing.page + 34)
                    }
                }
            }
            .ehCard()
        }
    }

    // MARK: - 数据

    private func capsuleLabel(_ title: String, filled: Bool) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(filled ? EhColor.onAccentFill : EhColor.accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background {
                if filled {
                    Capsule().fill(EhColor.accentFill)
                } else {
                    Capsule().strokeBorder(EhColor.accent.opacity(0.5), lineWidth: 1)
                }
            }
    }

    private var displayName: String {
        if appState.isSignedIn {
            return AppSettings.shared.displayName ?? "已登录"
        }
        return appState.isGuest ? "访客" : "未登录"
    }

    private var initial: String {
        String(displayName.prefix(1)).uppercased()
    }

    private var siteStatusText: String {
        let site = AppSettings.shared.gallerySite == .exHentai ? "ExHentai" : "E-Hentai"
        if appState.isSignedIn { return "\(site) · 已登录" }
        return "\(site) · 登录后可用收藏与配额"
    }

    private var quotaValueText: String {
        guard let quota, quota.totalLimit > 0 else { return isLoadingQuota ? "…" : "—" }
        return "\(quota.totalLimit - quota.currentUsed)"
    }

    private var quotaFootnote: String? {
        guard let quota, quota.totalLimit > 0 else { return nil }
        return "剩余 / \(quota.totalLimit)"
    }

    private var quotaProgress: Double? {
        guard let quota, quota.totalLimit > 0 else { return nil }
        return Double(quota.currentUsed) / Double(quota.totalLimit)
    }

    private func loadSummary() async {
        // 配额只在已登录时有意义，未登录请求会白跑一次网络
        if appState.isSignedIn {
            isLoadingQuota = true
            quota = try? await EhAPI.shared.getHomeDetail()
            isLoadingQuota = false
        }
        // 目录遍历是同步 IO，放到后台线程，别卡住这一屏的首次渲染
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let downloadDir = await DownloadManager.shared.downloadDirectory
        downloadCount = await DownloadManager.shared.getAllTasks().count

        let sizes = await Task.detached(priority: .utility) {
            (cache: Self.directorySize(cacheDir), downloads: Self.directorySize(downloadDir))
        }.value
        cacheBytes = sizes.cache
        downloadBytes = sizes.downloads
    }

    private static func directorySize(_ url: URL?) -> Int64 {
        guard let url,
              let e = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
              ) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            let size = (try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize
            total += Int64(size ?? 0)
        }
        return total
    }

    static func formatBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}

// MARK: - 路由

enum ProfileRoute: Hashable {
    case account, myTags, filters, hosts, news
    case appearance, listAndThumbnail, downloads, reading, favorites, privacy, network, tagDatabase

    @ViewBuilder
    var destination: some View {
        switch self {
        case .account:          ProfileView()
        case .myTags:           MyTagsView()
        case .filters:          FilterView()
        case .hosts:            HostsView()
        case .news:             EhNewsView()
        // 设置二级页用 scope 过滤同一个 SettingsView。
        // （SecurityView 是启动时的锁屏认证页，不是隐私设置页，别混用。）
        case .appearance:       SettingsView(scope: .appearance)
        case .listAndThumbnail: SettingsView(scope: .listThumbnail)
        case .downloads:        SettingsView(scope: .downloads)
        case .reading:          SettingsView(scope: .reading)
        case .favorites:        SettingsView(scope: .favorites)
        case .privacy:          SettingsView(scope: .privacy)
        case .network:          SettingsView(scope: .network)
        case .tagDatabase:      SettingsView(scope: .tagDatabase)
        }
    }
}

private struct SettingsEntry {
    let route: ProfileRoute
    let symbol: String
    let title: String
    let tint: Color
    let value: () -> String?

    static let all: [SettingsEntry] = [
        .init(route: .appearance, symbol: "circle.lefthalf.filled", title: "外观", tint: EhColor.info) {
            EhAppTheme(rawValue: AppSettings.shared.theme)?.title
        },
        .init(route: .listAndThumbnail, symbol: "square.grid.2x2", title: "列表与缩略图", tint: EhColor.info) {
            ["小", "中", "大"][safe: AppSettings.shared.thumbSize] ?? nil
        },
        .init(route: .downloads, symbol: "arrow.down.circle", title: "下载", tint: EhColor.success) { nil },
        .init(route: .reading, symbol: "book", title: "阅读", tint: EhColor.accent) { nil },
        // 默认收藏夹在这里改：收藏对话框里勾了「记住」之后，
        // 用户需要一个地方能改回「每次询问」
        .init(route: .favorites, symbol: "heart", title: "收藏", tint: EhColor.danger) {
            let slot = AppSettings.shared.defaultFavSlot
            if slot == -2 { return "每次询问" }
            if slot == -1 { return "本地收藏" }
            return AppSettings.shared.favCatName(slot)
        },
        .init(route: .privacy, symbol: "lock", title: "隐私与锁定", tint: EhColor.danger) { nil },
        .init(route: .network, symbol: "network", title: "网络与容灾", tint: EhColor.warning) { nil },
        .init(route: .tagDatabase, symbol: "character.book.closed", title: "标签翻译数据库", tint: EhColor.info) { nil },
    ]
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - 更新提示

/// 有新版本时显示在「我的」顶部。
///
/// 放这里而不是首页：首页是每天要看很多次的地方，一条常驻横幅会一直占位；
/// 而用户找版本相关的东西本来就会来这一屏。
///
/// 关于「热更新」：iOS 在内核层强制代码签名，进程只能执行签名过的页，
/// 下载来的原生代码加载不进去，因此 SwiftUI App 没有真正的热补丁。
/// 「装一次之后自动更新」由 AltStore / SideStore 的源订阅实现
/// （见仓库根目录的 source.json），这条横幅负责的是另一半——
/// 主动告知，以及给没订阅源的人一个直达下载页的入口。
struct UpdateBanner: View {
    @Environment(\.openURL) private var openURL
    let info: AppUpdateInfo

    var body: some View {
        HStack(spacing: EhSpacing.row) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(EhColor.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text("有新版本 \(info.version)")
                    .font(EhFont.body.weight(.semibold))
                    .foregroundStyle(EhColor.label)
                Text("订阅了 AltStore / SideStore 源会自动更新，也可以手动下载")
                    .font(EhFont.footnote)
                    .foregroundStyle(EhColor.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button {
                openURL(info.releaseURL)
            } label: {
                Text("查看")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(EhColor.onAccentFill)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(EhColor.accentFill))
            }
            .buttonStyle(.plain)

            Button {
                AppUpdateChecker.shared.updateAvailable = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(EhColor.tertiaryLabel)
            }
            .buttonStyle(.plain)
        }
        .padding(EhSpacing.page)
        .ehCard()
    }
}
