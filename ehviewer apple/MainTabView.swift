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
    #if os(macOS)
    @State private var navigation = MainTabNavigation(
        launchPage: AppSettings.shared.launchPage, usesHomeBrowseContainer: false
    )
    #else
    @State private var navigation = MainTabNavigation(launchPage: AppSettings.shared.launchPage)
    @State private var homeReselect: UUID?
    #endif
    /// 剪贴板打开画廊 (iOS sheet 展示)
    @State private var clipboardGallery: GalleryInfo?
    #if os(macOS)
    @State private var selectedGallery: GalleryInfo?
    /// 标签导航路径 — 支持从 Detail 列点击标签推入新画廊列表到 Content 列
    @State private var contentPath = NavigationPath()
    #endif

    typealias Tab = MainTab

    private var selectedTab: Tab { navigation.selection }

    private var tabSelection: Binding<Tab> {
        Binding(get: { navigation.selection }, set: { navigation.select($0) })
    }

    #if os(iOS)
    @State private var directReaderGallery: GalleryInfo?
    #endif

    var body: some View {
        let _ = NSLog("[RENDER] MainTabView body")
        #if DEBUG
        let _ = Self._printChanges()  // ★ 诊断: 精确显示哪个属性触发了 body 重新求值
        #endif
        #if os(macOS)
        NavigationSplitView {
            List(Tab.sidebarTabs, id: \.self, selection: tabSelection) { tab in
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
            navigation.select(.home)
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToPopular)) { _ in
            navigation.select(.popular)
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToTopList)) { _ in
            navigation.select(.toplist)
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToFavorites)) { _ in
            navigation.select(.favorites)
        }
        // 全局强调色：链接、开关、选中态一次性统一到琥珀，
        // 不必逐个视图替换散落的 .blue / .accentColor
        .tint(EhColor.accent)
        .onReceive(NotificationCenter.default.publisher(for: .openGalleryFromClipboard)) { notification in
            guard let gallery = MainTabNavigation.clipboardGallery(from: notification) else { return }
            selectedGallery = gallery
        }
        #else
        GeometryReader { geometry in
            let showsSidebar = ResponsiveLayout.usesTabSidebar(width: geometry.size.width)
            HStack(spacing: 0) {
                if showsSidebar {
                    adaptiveSidebar
                    Divider()
                }

                // Keep the same stacks and their state when the navigation controls move.
                ZStack {
                    ForEach(navigation.retainedTabs, id: \.self) { tab in
                        tabLayer(tab) { tabContent(tab) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.ehHomeReselect, homeReselect)
                .ehFloatingTabBar(
                    items: Tab.bottomTabs.map {
                        .init(value: $0, title: $0.rawValue, symbol: $0.icon, selectedSymbol: $0.filledIcon)
                    },
                    selection: tabSelection,
                    isEnabled: !showsSidebar,
                    onReselect: { tab in
                        if tab == .home { homeReselect = UUID() }
                    }
                )
            }
            .allowsHitTesting(directReaderGallery == nil)
            .accessibilityHidden(directReaderGallery != nil)
            .overlay {
                if let gallery = directReaderGallery {
                    // Stay in the owning root so closing native context UI and opening
                    // a reader do not compete for the same presentation controller.
                    ImageReaderView(gid: gallery.gid, token: gallery.token, pages: gallery.pages,
                                    fallbackTitle: gallery.suitableTitle(preferJpn: AppSettings.shared.showJpnTitle),
                                    onRequestClose: { directReaderGallery = nil })
                        .id(gallery.gid)
                }
            }
        }
        // 全局强调色：链接、开关、选中态一次性统一到琥珀，
        // 不必逐个视图替换散落的 .blue / .accentColor
        .tint(EhColor.accent)
        .onReceive(NotificationCenter.default.publisher(for: .openGalleryFromClipboard)) { notification in
            guard let gallery = MainTabNavigation.clipboardGallery(from: notification) else { return }
            clipboardGallery = gallery
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
                    .navigationDestination(for: GalleryInfo.self) { result in
                        GalleryDetailView(gallery: result)
                            .id(result.gid)
                    }
                    .ehPushedTagSearchDestination()
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
            GalleryListView(mode: .toplist(period: 15), selection: $selectedGallery)
        case .favorites:
            FavoritesView(selection: $selectedGallery)
        case .downloads:
            DownloadsView()
        case .history:
            HistoryView()
        case .settings:
            SettingsView()
        case .profile:
            // macOS 侧边栏平铺全部入口，「我的」的聚合价值不存在；
            // 账号与配额在设置页里已有位置
            ProfileView()
        case .more:
            // macOS 不使用 "更多" 标签，不应出现
            EmptyView()
        }
    }
    #endif

    #if os(iOS)
    private var adaptiveSidebar: some View {
        let sidebarSelection = navigation.sidebarSelection
        return List {
            ForEach(Tab.sidebarTabs, id: \.self) { tab in
                Button {
                    navigation.selectFromSidebar(tab)
                } label: {
                    Label(tab.rawValue, systemImage: tab.icon)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(sidebarSelection == tab ? Color.accentColor.opacity(0.15) : nil)
                .accessibilityAddTraits(sidebarSelection == tab ? .isSelected : [])
            }
        }
        .listStyle(.sidebar)
        .frame(width: ResponsiveLayout.tabSidebarWidth)
        .accessibilityIdentifier("adaptive-tab-sidebar")
    }

    /// 保留全部页面的视图状态：切走的页面只是隐藏而不销毁，
    /// 回来时滚动位置与已加载数据都还在。
    @ViewBuilder
    private func tabLayer<Content: View>(
        _ tab: Tab, @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .opacity(selectedTab == tab ? 1 : 0)
            .allowsHitTesting(selectedTab == tab)
            .accessibilityHidden(selectedTab != tab)
            .ehTabBarDriver(active: selectedTab == tab)
    }

    #endif

    @ViewBuilder
    private func tabContent(_ tab: Tab) -> some View {
        switch tab {
        case .home:
            // 浏览容器：顶部横向切页承载首页/订阅/热门/排行
            #if os(iOS)
            BrowseHomeView(route: $navigation.browse, onRequestDirectRead: { directReaderGallery = $0 })
            #else
            BrowseHomeView(route: $navigation.browse)
            #endif
        case .subscription, .popular, .toplist:
            // These sidebar shortcuts are aliases of the retained Home stack on iOS.
            EmptyView()
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
            MoreTabView(onNavigate: { tab in navigation.select(tab) })
        case .profile:
            ProfileHomeView()
        }
    }
}

extension MainTab {
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
}

#Preview {
    MainTabView()
        .environment(AppState())
}
