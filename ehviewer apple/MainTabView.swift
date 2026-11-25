//
//  MainTabView.swift
//  ehviewer apple
//
//  主导航: TabView (iOS) / 三栏 NavigationSplitView (macOS)
//

import SwiftUI
import EhModels
import EhSettings

private struct EhWorkspaceBatchSelectionKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

extension View {
    func ehWorkspaceBatchSelection(_ selecting: Bool) -> some View {
        preference(key: EhWorkspaceBatchSelectionKey.self, value: selecting)
    }
}

/// Window-local stack. A push keeps the previous shell mounted with the
/// same identity so it can restore its exact tab, scroll and detail state.
struct MainTabView: View {
    typealias Tab = MainTab
    @State private var workspaces = [WorkspaceLayer()]
    @State private var outgoingLayer: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var active: WorkspaceLayer { workspaces.last! }

    var body: some View {
        GeometryReader { geometry in
            #if os(iOS)
            let compact = !ResponsiveLayout.usesTabSidebar(width: geometry.size.width)
            #else
            let compact = false
            #endif
            let distance = compact && !reduceMotion ? geometry.size.width : 0
            ZStack {
                ForEach(workspaces) { workspace in
                    let current = workspace.id == active.id
                    VStack(spacing: 0) {
                        if let route = workspace.route {
                            if current || outgoingLayer == workspace.id {
                                workspaceHeader(route,
                                                depth: workspaces.firstIndex { $0.id == workspace.id } ?? 0,
                                                canGoBack: current && workspace.canGoBack)
                                    .accessibilityHidden(!current)
                            } else {
                                // Match the visible header's layout to keep the
                                // retained list at the same viewport/scroll anchor.
                                Color.clear.frame(height: 44)
                                Divider().hidden()
                            }
                        }
                        MainTabWorkspace(workspace: workspace)
                    }
                    .background(EhColor.background)
                    .offset(x: current ? 0 : -distance * 0.26)
                    .opacity(current || outgoingLayer == workspace.id ? 1 : 0)
                    .zIndex(Double(workspaces.firstIndex { $0.id == workspace.id } ?? 0))
                    .allowsHitTesting(current)
                    .accessibilityElement(children: .contain)
                    .accessibilityHidden(!current)
                    .ehSuspendTabBarDriver(!current)
                    .environment(\.ehWorkspaceIsActive, current)
                    .environment(\.ehTagWorkspaceNavigation, TagWorkspaceNavigation { route in
                        guard active.id == workspace.id else { return }
                        push(route)
                    })
                    .transition(distance > 0 ? .offset(x: distance) : .opacity)
                }
            }
            .clipped()
            #if os(iOS)
            // One stable chrome instance; only the workspace layers above it move.
            .ehFloatingTabBar(
                items: MainTab.bottomTabs.map {
                    .init(value: $0, title: $0.rawValue, symbol: $0.icon, selectedSymbol: $0.filledIcon)
                },
                selection: Binding(get: { active.navigation.selection }, set: { active.navigation.select($0) }),
                isEnabled: compact,
                onReselect: { tab in
                    if tab == .home { active.homeReselect = UUID() }
                }
            )
            #endif
        }
    }

    private func push(_ route: TagWorkspaceRoute) {
        if reduceMotion {
            workspaces.append(WorkspaceLayer(route: route))
            return
        }
        let departing = active.id
        outgoingLayer = departing
        withAnimation(.easeInOut(duration: 0.28), completionCriteria: .logicallyComplete) {
            workspaces.append(WorkspaceLayer(route: route))
        } completion: {
            if outgoingLayer == departing { outgoingLayer = nil }
        }
    }

    private func transition(_ action: () -> Void) {
        if reduceMotion { action() }
        else { withAnimation(.easeInOut(duration: 0.28), action) }
    }

    private func workspaceHeader(_ route: TagWorkspaceRoute, depth: Int, canGoBack: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if canGoBack {
                    Button {
                        guard workspaces.count > 1, active.canGoBack else { return }
                        transition { workspaces.removeLast() }
                    } label: {
                        Image(systemName: "chevron.backward")
                            .font(.headline)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("返回上一工作区")
                    .accessibilityIdentifier("workspace-back")
                } else {
                    // An inactive shell or one displaying an inner detail
                    // must not advertise a second, non-actionable AX Back.
                    Color.clear.frame(width: 44, height: 44)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(route.title).font(.subheadline.weight(.semibold))
                    Text(route.tags.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("workspace-tags")
                }
                Spacer(minLength: 8)
                Text("\(depth + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("工作区第 \(depth + 1) 层")
                    .accessibilityIdentifier("workspace-depth")
            }
            .padding(.trailing, 16)
            Divider()
        }
        .background(EhColor.background)
    }
}

@MainActor @Observable
private final class WorkspaceLayer: Identifiable {
    let id = UUID()
    let route: TagWorkspaceRoute?
    let entryTab: MainTab?
    var navigation: MainTabNavigation
    var canGoBack = true
    #if os(iOS)
    var homeReselect: UUID?
    #endif

    init(route: TagWorkspaceRoute? = nil) {
        self.route = route
        #if os(macOS)
        var initialNavigation = MainTabNavigation(launchPage: AppSettings.shared.launchPage, usesHomeBrowseContainer: false)
        #else
        var initialNavigation = MainTabNavigation(launchPage: AppSettings.shared.launchPage)
        #endif
        if let route {
            let initial: MainTab
            switch route.origin.scope {
            case .cloudFavorites, .localFavorites, .allFavorites: initial = .favorites
            case .history: initial = .history
            case .downloads: initial = .downloads
            case .watched: initial = .subscription
            case .loadedPopular: initial = .popular
            case .loadedToplist: initial = .toplist
            case .browse: initial = .home
            }
            initialNavigation.select(initial)
            entryTab = initialNavigation.selection
        } else {
            entryTab = nil
        }
        navigation = initialNavigation
    }
}

private struct MainTabWorkspace: View {
    @Bindable var workspace: WorkspaceLayer
    @Environment(\.ehWorkspaceIsActive) private var workspaceIsActive
    @State private var isBatchSelecting = false
    /// 剪贴板打开画廊 (iOS sheet 展示)
    @State private var clipboardGallery: GalleryInfo?
    #if os(macOS)
    @State private var selectedGalleries: [Tab: GalleryInfo] = [:]
    @State private var selectedGalleryOrigins: [Tab: WorkspaceGalleryDestination] = [:]
    @State private var mountedMacTabs: Set<Tab> = []
    #endif

    typealias Tab = MainTab

    private var selectedTab: Tab { workspace.navigation.selection }

    private var tabSelection: Binding<Tab> {
        Binding(get: { workspace.navigation.selection }, set: { workspace.navigation.select($0) })
    }

    #if os(iOS)
    @State private var directReaderGallery: GalleryInfo?
    @State private var mountedTabs: Set<Tab> = []
    @State private var nestedNavigation = false
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
            .disabled(isBatchSelecting)
            .accessibilityHidden(isBatchSelecting)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } content: {
            ZStack {
                ForEach(macTabs, id: \.self) { tab in
                    macLayer(tab) {
                        NavigationStack { macOSContentView(for: tab) }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 350, ideal: 480)
        } detail: {
            ZStack {
                ForEach(macTabs, id: \.self) { tab in
                    macLayer(tab) {
                        NavigationStack {
                            if let gallery = selectedGalleries[tab] {
                                if let origin = selectedGalleryOrigins[tab], origin.gallery.gid == gallery.gid {
                                    origin.view()
                                } else {
                                    GalleryDetailView(gallery: gallery).id(gallery.gid)
                                }
                            } else {
                                ContentUnavailableView("选择画廊", systemImage: "photo.stack",
                                                       description: Text("从列表选择一个画廊"))
                            }
                        }
                    }
                }
            }
        }
        .onPreferenceChange(EhWorkspaceBatchSelectionKey.self) { isBatchSelecting = $0 }
        .onChange(of: isBatchSelecting) { _, selecting in workspace.canGoBack = !selecting }
        .onChange(of: selectedTab, initial: true) { _, tab in
            mountedMacTabs.insert(tab)
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToHome)) { _ in
            guard workspaceIsActive, !isBatchSelecting else { return }
            workspace.navigation.select(.home)
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToPopular)) { _ in
            guard workspaceIsActive, !isBatchSelecting else { return }
            workspace.navigation.select(.popular)
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToTopList)) { _ in
            guard workspaceIsActive, !isBatchSelecting else { return }
            workspace.navigation.select(.toplist)
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToFavorites)) { _ in
            guard workspaceIsActive, !isBatchSelecting else { return }
            workspace.navigation.select(.favorites)
        }
        // 全局强调色：链接、开关、选中态一次性统一到琥珀，
        // 不必逐个视图替换散落的 .blue / .accentColor
        .tint(EhColor.accent)
        .onReceive(NotificationCenter.default.publisher(for: .openGalleryFromClipboard)) { notification in
            guard workspaceIsActive, !isBatchSelecting, let gallery = MainTabNavigation.clipboardGallery(from: notification) else { return }
            selectedGalleryOrigins[selectedTab] = nil
            selectedGalleries[selectedTab] = gallery
        }
        #else
        GeometryReader { geometry in
            let showsSidebar = ResponsiveLayout.usesTabSidebar(width: geometry.size.width)
            HStack(spacing: 0) {
                if showsSidebar {
                    adaptiveSidebar
                        .disabled(isBatchSelecting)
                        .accessibilityHidden(isBatchSelecting)
                    Divider()
                }

                // Keep the same stacks and their state when the navigation controls move.
                ZStack {
                    ForEach(workspace.navigation.retainedTabs.filter { mountedTabs.contains($0) || $0 == selectedTab }, id: \.self) { tab in
                        tabLayer(tab) { tabContent(tab) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.ehHomeReselect, workspace.homeReselect)
                .onPreferenceChange(EhWorkspaceBatchSelectionKey.self) { isBatchSelecting = $0 }
                .onChange(of: selectedTab, initial: true) { _, tab in mountedTabs.insert(tab) }
            }
            .allowsHitTesting(directReaderGallery == nil && clipboardGallery == nil)
            .accessibilityHidden(directReaderGallery != nil || clipboardGallery != nil)
            .ehSuspendTabBarDriver(directReaderGallery != nil || clipboardGallery != nil)
            .overlay {
                if let gallery = clipboardGallery {
                    NavigationStack {
                        GalleryDetailView(gallery: gallery)
                            .id(gallery.gid)
                            .overlay(alignment: .topTrailing) {
                                Button("关闭") { clipboardGallery = nil }
                                    .padding(12)
                            }
                            .ehWorkspaceGalleryDestination()
                    }
                    .background(EhColor.background)
                }
            }
            .overlay {
                if let gallery = directReaderGallery {
                    // Stay in the owning root so closing native context UI and opening
                    // a reader do not compete for the same presentation controller.
                    ImageReaderView(gid: gallery.gid, token: gallery.token, pages: gallery.pages,
                                    galleryHint: gallery,
                                    onRequestClose: { directReaderGallery = nil })
                        .id(gallery.gid)
                }
            }
        }
        // 全局强调色：链接、开关、选中态一次性统一到琥珀，
        // 不必逐个视图替换散落的 .blue / .accentColor
        .tint(EhColor.accent)
        .onPreferenceChange(EhHidesTabBarKey.self) { nestedNavigation = $0 }
        // The tab bar belongs to the window, outside this workspace's reader
        // overlay. Hide that shared bar without unmounting the source tab.
        .transformPreference(EhHidesTabBarKey.self) { hidesTabBar in
            hidesTabBar = hidesTabBar || directReaderGallery != nil
        }
        .onChange(of: !nestedNavigation && !isBatchSelecting && directReaderGallery == nil && clipboardGallery == nil,
                  initial: true) { _, canGoBack in workspace.canGoBack = canGoBack }
        .onReceive(NotificationCenter.default.publisher(for: .openGalleryFromClipboard)) { notification in
            guard workspaceIsActive, !isBatchSelecting,
                  let gallery = MainTabNavigation.clipboardGallery(from: notification) else { return }
            clipboardGallery = gallery
        }
        #endif
    }

    #if os(macOS)
    private var macTabs: [Tab] {
        Tab.sidebarTabs.filter { $0 == selectedTab || mountedMacTabs.contains($0) }
    }

    private func macLayer<Content: View>(_ tab: Tab, @ViewBuilder content: () -> Content) -> some View {
        let active = selectedTab == tab
        return content()
            .opacity(active ? 1 : 0)
            .allowsHitTesting(active)
            .accessibilityElement(children: .contain)
            .accessibilityHidden(!active)
            .environment(\.ehWorkspaceIsActive, workspaceIsActive && active)
            .transformPreference(EhWorkspaceBatchSelectionKey.self) { if !active { $0 = false } }
    }

    @ViewBuilder
    private func macOSContentView(for tab: Tab) -> some View {
        let selection = Binding<GalleryInfo?>(get: { selectedGalleries[tab] }, set: { selectedGalleries[tab] = $0 })
        let selectOrigin: (WorkspaceGalleryDestination) -> Void = { selectedGalleryOrigins[tab] = $0 }
        if let route = workspace.route, workspace.entryTab == tab {
            if tab == .favorites {
                FavoritesView(workspaceRoute: route, selection: selection, selectedOrigin: selectOrigin)
            } else if tab == .history {
                HistoryView(workspaceRoute: route)
            } else if tab == .downloads {
                DownloadsView(workspaceRoute: route)
            } else {
                GalleryListView(workspace: route, selection: selection, selectedOrigin: selectOrigin)
            }
        } else {
        switch tab {
        case .home:
            GalleryListView(mode: .home, selection: selection, selectedOrigin: selectOrigin)
        case .subscription:
            GalleryListView(mode: .subscription, selection: selection, selectedOrigin: selectOrigin)
        case .popular:
            GalleryListView(mode: .popular, selection: selection, selectedOrigin: selectOrigin)
        case .toplist:
            GalleryListView(mode: .toplist(period: 15), selection: selection, selectedOrigin: selectOrigin)
        case .favorites:
            FavoritesView(selection: selection, selectedOrigin: selectOrigin)
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
    }
    #endif

    #if os(iOS)
    private var adaptiveSidebar: some View {
        let sidebarSelection = workspace.navigation.sidebarSelection
        return List {
            ForEach(Tab.sidebarTabs, id: \.self) { tab in
                Button {
                    workspace.navigation.selectFromSidebar(tab)
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
            .environment(\.ehWorkspaceIsActive, workspaceIsActive && selectedTab == tab)
            .ehTabBarDriver(active: selectedTab == tab)
            .transformPreference(EhWorkspaceBatchSelectionKey.self) { selecting in
                if selectedTab != tab { selecting = false }
            }
    }

    #endif

    @ViewBuilder
    private func tabContent(_ tab: Tab) -> some View {
        if let route = workspace.route, workspace.entryTab == tab {
            if tab == .favorites {
                FavoritesView(workspaceRoute: route)
            } else if tab == .history {
                HistoryView(workspaceRoute: route)
            } else if tab == .downloads {
                DownloadsView(workspaceRoute: route)
            } else {
                #if os(iOS)
                BrowseHomeView(route: $workspace.navigation.browse, workspaceRoute: route,
                               onRequestDirectRead: { directReaderGallery = $0 })
                #else
                BrowseHomeView(route: $workspace.navigation.browse, workspaceRoute: route)
                #endif
            }
        } else {
        switch tab {
        case .home:
            // 浏览容器：顶部横向切页承载首页/订阅/热门/排行
            #if os(iOS)
            BrowseHomeView(route: $workspace.navigation.browse, onRequestDirectRead: { directReaderGallery = $0 })
            #else
            BrowseHomeView(route: $workspace.navigation.browse)
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
            MoreTabView(onNavigate: { tab in workspace.navigation.select(tab) })
        case .profile:
            ProfileHomeView()
        }
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
