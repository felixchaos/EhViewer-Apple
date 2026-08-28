//
//  MainTabView.swift
//  ehviewer apple
//
//  主导航: TabView (iOS) / 三栏 NavigationSplitView (macOS)
//

import SwiftUI
import EhModels
import EhSettings

struct MainTabView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedTab: Tab = Tab.fromLaunchPage(AppSettings.shared.launchPage)
    /// 剪贴板打开画廊 (iOS sheet 展示)
    @State private var clipboardGallery: GalleryInfo?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    #if os(macOS)
    @State private var selectedGallery: GalleryInfo?
    /// 标签导航路径 — 支持从 Detail 列点击标签推入新画廊列表到 Content 列
    @State private var contentPath = NavigationPath()
    #endif

    enum Tab: String, CaseIterable {
        case home = "首页"
        case subscription = "订阅"
        case popular = "热门"
        case toplist = "排行榜"
        case favorites = "收藏"
        case downloads = "下载"
        case history = "历史"
        case settings = "设置"
        case more = "更多"
        case profile = "我的"

        var icon: String {
            switch self {
            case .home: return "house"
            case .subscription: return "bell"
            case .popular: return "flame"
            case .toplist: return "chart.bar"
            case .favorites: return "heart"
            case .downloads: return "arrow.down.circle"
            case .history: return "clock"
            case .settings: return "gear"
            case .more: return "ellipsis.circle"
            case .profile: return "person.crop.circle"
            }
        }

        /// 固定的底部默认标签页。
        /// 「热门」「排行」已提到首页顶部的横向切页，不再占用底部位置；
        /// 「设置」并入「我的」，底部因此空出一格给「历史」。
        private static let defaultBottomTabs: [Tab] = [.home, .favorites, .downloads, .history, .profile]

        /// iPhone 底部显示的标签页 — 根据启动页面设置动态调整
        /// 如果启动页不在默认底部栏中 (热门/排行榜/历史)，替换首页位置
        static var bottomTabs: [Tab] {
            let launchTab = fromLaunchPage(AppSettings.shared.launchPage)
            guard !defaultBottomTabs.contains(launchTab) else { return defaultBottomTabs }
            var tabs = defaultBottomTabs
            tabs[0] = launchTab  // 替换 .home
            return tabs
        }

        /// "更多"菜单中的标签页 — 不在底部栏且非 .more 的标签
        static var moreTabs: [Tab] {
            let bottom = Set(bottomTabs)
            return allCases.filter { $0 != .more && $0 != .profile && !bottom.contains($0) }
        }

        /// 浮起导航条的图标（选中态用实心变体）
        var filledIcon: String {
            switch self {
            case .home: return "house.fill"
            case .favorites: return "heart.fill"
            case .downloads: return "arrow.down.circle.fill"
            case .history: return "clock.fill"
            case .profile: return "person.crop.circle.fill"
            default: return icon
            }
        }

        /// 启动页面设置映射
        static func fromLaunchPage(_ page: Int) -> Tab {
            switch page {
            case 1: return .popular
            case 2: return .toplist
            case 3: return .favorites
            case 4: return .downloads
            case 5: return .history
            default: return .home
            }
        }
    }

    var body: some View {
        let _ = NSLog("[RENDER] MainTabView body")
        #if DEBUG
        let _ = Self._printChanges()  // ★ 诊断: 精确显示哪个属性触发了 body 重新求值
        #endif
        #if os(macOS)
        NavigationSplitView {
            List(Tab.allCases.filter { $0 != .more }, id: \.self, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.icon)
            }
            .navigationTitle("EhViewer")
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } content: {
            NavigationStack(path: $contentPath) {
                macOSContentView(for: selectedTab)
                    .navigationDestination(for: TagSearchDestination.self) { dest in
                        // 标签点击推入的画廊列表 (对齐 Android: onTagClick → GalleryListScene)
                        GalleryListView(mode: .tag(keyword: dest.tag), selection: $selectedGallery)
                    }
            }
            .id(selectedTab)
            .navigationSplitViewColumnWidth(min: 350, ideal: 480)
        } detail: {
            NavigationStack {
                if let gallery = selectedGallery {
                    GalleryDetailView(gallery: gallery)
                        .id(gallery.gid)
                } else {
                    ContentUnavailableView("选择画廊", systemImage: "photo.stack", description: Text("从列表选择一个画廊"))
                }
            }
            .environment(\.tagNavigationAction, TagNavigationAction { tag in
                contentPath.append(TagSearchDestination(tag: tag))
            })
        }
        .onChange(of: selectedTab) { _, newTab in
            selectedGallery = nil
            contentPath = NavigationPath()
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToHome)) { _ in
            selectedTab = .home
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToPopular)) { _ in
            selectedTab = .popular
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToTopList)) { _ in
            selectedTab = .toplist
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToFavorites)) { _ in
            selectedTab = .favorites
        }
        .onReceive(NotificationCenter.default.publisher(for: .openGalleryFromClipboard)) { notification in
            guard let userInfo = notification.userInfo,
                  let gid = userInfo["gid"] as? Int64,
                  let token = userInfo["token"] as? String else { return }
            let gallery = GalleryInfo(gid: gid, token: token)
            selectedGallery = gallery
        }
        #else
        // iOS: iPad regular → 侧边栏 NavigationSplitView, iPhone → 底部 TabView
        Group {
            if horizontalSizeClass == .regular {
                // iPad 横屏 / 外接键盘: 侧边栏导航
                NavigationSplitView {
                    List {
                        ForEach(Tab.allCases.filter { $0 != .more }, id: \.self) { tab in
                            Button {
                                selectedTab = tab
                            } label: {
                                HStack {
                                    Label(tab.rawValue, systemImage: tab.icon)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(selectedTab == tab ? Color.accentColor.opacity(0.15) : nil)
                        }
                    }
                    .listStyle(.sidebar)
                    .navigationTitle("EhViewer")
                } detail: {
                    tabContent(selectedTab)
                        .id(selectedTab)
                }
            } else {
                // iPhone / iPad 竖屏: 浮起玻璃导航条
                //
                // 不再用系统 TabView：设计需要一条离开屏幕边缘、带圆角与模糊的浮条，
                // 而 TabBar 的外观定制到不了这个程度。代价是要自己补回系统行为，
                // 见 EhFloatingTabBar 的说明（安全区避让、重复点击回顶、无障碍）。
                ZStack {
                    ForEach(Tab.bottomTabs, id: \.self) { tab in
                        tabContent(tab)
                            // 保留全部页面的视图状态：切走的页面只是隐藏，
                            // 不销毁，回来时滚动位置与已加载数据都还在
                            .opacity(selectedTab == tab ? 1 : 0)
                            .allowsHitTesting(selectedTab == tab)
                            .accessibilityHidden(selectedTab != tab)
                    }
                }
                .ehFloatingTabBar(
                    items: Tab.bottomTabs.map {
                        .init(value: $0, title: $0.rawValue, symbol: $0.icon, selectedSymbol: $0.filledIcon)
                    },
                    selection: $selectedTab,
                    onReselect: { tab in
                        NotificationCenter.default.post(
                            name: .ehScrollToTop, object: nil, userInfo: ["tab": tab.rawValue]
                        )
                    }
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openGalleryFromClipboard)) { notification in
            guard let userInfo = notification.userInfo,
                  let gid = userInfo["gid"] as? Int64,
                  let token = userInfo["token"] as? String else { return }
            clipboardGallery = GalleryInfo(gid: gid, token: token)
        }
        .sheet(item: $clipboardGallery) { gallery in
            NavigationStack {
                GalleryDetailView(gallery: gallery)
                    .id(gallery.gid)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") { clipboardGallery = nil }
                        }
                    }
            }
        }
        .onChange(of: horizontalSizeClass) { _, newSizeClass in
            // iPad 旋转切换时确保选中标签有效
            if newSizeClass == .compact {
                if !Tab.bottomTabs.contains(selectedTab) {
                    selectedTab = .more
                }
            }
        }
        #endif
    }

    #if os(macOS)
    @ViewBuilder
    private func macOSContentView(for tab: Tab) -> some View {
        switch tab {
        case .home:
            GalleryListView(mode: .home, selection: $selectedGallery)
        case .subscription:
            GalleryListView(mode: .subscription, selection: $selectedGallery)
        case .popular:
            GalleryListView(mode: .popular, selection: $selectedGallery)
        case .toplist:
            TopListView()
        case .favorites:
            FavoritesView(selection: $selectedGallery)
        case .downloads:
            DownloadsView()
        case .history:
            HistoryView()
        case .settings:
            SettingsView()
        case .more:
            // macOS 不使用 "更多" 标签，不应出现
            EmptyView()
        }
    }
    #endif

    @ViewBuilder
    private func tabContent(_ tab: Tab) -> some View {
        switch tab {
        case .home:
            // 浏览容器：顶部横向切页承载首页/订阅/热门/排行
            BrowseHomeView()
        case .subscription:
            GalleryListView(mode: .subscription)
        case .popular:
            GalleryListView(mode: .popular)
        case .toplist:
            TopListView()
        case .favorites:
            FavoritesView()
        case .downloads:
            DownloadsView()
        case .history:
            HistoryView()
        case .settings:
            SettingsView()
        case .more:
            // 保留给 iPad/macOS 侧边栏的兼容路径；iPhone 底部栏已改用 .profile
            MoreTabView(onNavigate: { tab in selectedTab = tab })
        case .profile:
            ProfileHomeView()
        }
    }
}

#Preview {
    MainTabView()
        .environment(AppState())
}
