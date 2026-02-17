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
        case popular = "热门"
        case toplist = "排行榜"
        case favorites = "收藏"
        case downloads = "下载"
        case history = "历史"
        case settings = "设置"
        case more = "更多"

        var icon: String {
            switch self {
            case .home: return "house"
            case .popular: return "flame"
            case .toplist: return "chart.bar"
            case .favorites: return "heart"
            case .downloads: return "arrow.down.circle"
            case .history: return "clock"
            case .settings: return "gear"
            case .more: return "ellipsis.circle"
            }
        }

        /// iOS 底部默认显示的标签页 (对齐 Android: 首页/收藏/下载/设置/更多)
        static var defaultBottomTabs: [Tab] { [.home, .favorites, .downloads, .settings, .more] }

        /// "更多"菜单中的标签页
        static var moreTabs: [Tab] { [.popular, .toplist, .history] }

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

        /// iPhone 底部导航可达性检查 — 不在底部栏的 tab 降级为 .home
        static func bottomTabSafe(_ tab: Tab) -> Tab {
            defaultBottomTabs.contains(tab) ? tab : .home
        }
    }

    var body: some View {
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
                // iPhone / iPad 竖屏: 底部标签栏
                TabView(selection: $selectedTab) {
                    ForEach(Tab.defaultBottomTabs, id: \.self) { tab in
                        tabContent(tab)
                            .tabItem {
                                Label(tab.rawValue, systemImage: tab.icon)
                            }
                            .tag(tab)
                    }
                }
                .onAppear {
                    // 启动页面在底部导航不存在时降级
                    selectedTab = Tab.bottomTabSafe(selectedTab)
                }
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
                selectedTab = Tab.bottomTabSafe(selectedTab)
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
            GalleryListView(mode: .home)
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
            // "更多"标签页: 列出剩余功能入口 (对齐 Android DrawerLayout 更多菜单)
            MoreTabView(onNavigate: { tab in selectedTab = tab })
        }
    }
}

#Preview {
    MainTabView()
        .environment(AppState())
}
