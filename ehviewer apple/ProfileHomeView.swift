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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: EhSpacing.section) {
                    accountCard
                    quickGrid
                    settingsList
                }
                .padding(.horizontal, EhSpacing.page)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .background(EhColor.groupedBackground)
            .navigationTitle("我的")
            .scrollContentBackground(.hidden)
            .navigationDestination(for: ProfileRoute.self) { route in
                route.destination
            }
            .navigationDestination(for: GalleryInfo.self) { gallery in
                GalleryDetailView(gallery: gallery).id(gallery.gid)
            }
            .task { await loadSummary() }
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

                NavigationLink(value: ProfileRoute.account) {
                    Text("账号")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(EhColor.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .overlay(Capsule().strokeBorder(EhColor.accent.opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(EhSpacing.page)

            EhHairline(inset: EhSpacing.page)

            HStack(alignment: .top, spacing: 0) {
                statColumn(
                    title: "图片配额",
                    value: quotaValueText,
                    footnote: quotaFootnote,
                    progress: quotaProgress
                )
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
            quickEntry(.filters, symbol: "line.3.horizontal.decrease.circle", title: "筛选器")
            quickEntry(.hosts, symbol: "globe", title: "Hosts")
            quickEntry(.news, symbol: "envelope", title: "站内公告")
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

    private var displayName: String {
        AppSettings.shared.displayName ?? (appState.isSignedIn ? "已登录" : "未登录")
    }

    private var initial: String {
        String(displayName.prefix(1)).uppercased()
    }

    private var siteStatusText: String {
        let site = AppSettings.shared.gallerySite == .exHentai ? "ExHentai" : "E-Hentai"
        return "\(site) · \(appState.isSignedIn ? "已登录" : "访客")"
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
    case appearance, listAndThumbnail, downloads, reading, privacy, network, tagDatabase

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
