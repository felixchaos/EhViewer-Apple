//
//  BrowseHomeView.swift
//  ehviewer apple
//
//  浏览容器 — 首页/订阅/热门/排行 的横向切页宿主
//
//  这四个入口取的是同一类内容的不同数据源，此前「热门」和「排行」要经
//  「更多」标签页二级跳转才能到达，路径比它们的使用频率长。现在提到同一层级，
//  横向一划即可切换。
//

import SwiftUI
import EhModels

extension BrowseSource {
    var title: String {
        switch self {
        case .home:         return "首页"
        case .search:       return "搜索"
        case .subscription: return "订阅"
        case .popular:      return "热门"
        case .toplist:      return "排行"
        }
    }

    /// 对应的列表模式。
    ///
    /// 排行榜此前不走 GalleryListView（另有一套「名次 + 一行文字」的视图），
    /// 结果那一页和 App 里其它画廊列表完全不是一个东西。
    /// toplist.php 返回的本来就是标准画廊列表表格，所以现在统一走这里。
    func listMode(toplistPeriod: Int, searchQuery: String) -> GalleryListView.ListMode {
        switch self {
        case .home:         return .home
        case .search:       return .search(keyword: searchQuery)
        case .subscription: return .subscription
        case .popular:      return .popular
        case .toplist:      return .toplist(period: toplistPeriod)
        }
    }
}

struct BrowseHomeView: View {
    /// The originating list stays mounted while its search results are visible.
    @Binding var route: BrowseHomeRoute
    var onRequestDirectRead: ((GalleryInfo) -> Void)? = nil
    let workspaceRoute: TagWorkspaceRoute?
    @State private var toplistPeriod = 15
    @State private var search = GalleryBrowseSearch(query: "")
    @State private var replayGeneration = 0
    @State private var visitedOrigins: Set<BrowseSource> = []

    init(route: Binding<BrowseHomeRoute>, workspaceRoute: TagWorkspaceRoute? = nil,
         onRequestDirectRead: ((GalleryInfo) -> Void)? = nil) {
        _route = route
        self.workspaceRoute = workspaceRoute
        self.onRequestDirectRead = onRequestDirectRead
        _toplistPeriod = State(initialValue: workspaceRoute?.origin.toplistPeriod ?? 15)
    }

    private func scopedRoute(for source: BrowseSource) -> TagWorkspaceRoute? {
        guard let workspaceRoute else { return nil }
        switch (workspaceRoute.origin.scope, source) {
        case (.browse, .home), (.watched, .subscription), (.loadedPopular, .popular):
            return workspaceRoute
        case (.loadedToplist, .toplist) where workspaceRoute.origin.toplistPeriod ?? 15 == toplistPeriod:
            return workspaceRoute
        default:
            // Explicitly selecting a different source is ordinary navigation
            // inside this workspace, not an implicit broadening of its seed.
            return nil
        }
    }

    private var selection: Binding<BrowseSource> {
        Binding(get: { route.selection }, set: { route.select($0) })
    }

    var body: some View {
        let origin = route.origin
        let isShowingSearch = route.isShowingSearch
        ZStack {
            ForEach(BrowseSource.allCases.filter { source in
                source != .search && (source == origin || visitedOrigins.contains(source))
            }, id: \.self) { source in
                let visible = source == origin && !isShowingSearch
                list(for: source)
                    .id(OriginIdentity(source: source, period: source == .toplist ? toplistPeriod : 0))
                    .opacity(visible ? 1 : 0)
                    .zIndex(visible ? 1 : 0)
                    .allowsHitTesting(visible)
                    .accessibilityHidden(!visible)
                    .ehSuspendTabBarDriver(!visible)
                    .environment(\.ehBrowseOriginIsCurrent, source == origin)
            }

            if isShowingSearch {
                list(for: .search)
                    .id(SearchIdentity(search: search, replayGeneration: replayGeneration))
                    .zIndex(2)
            }
        }
        .onChange(of: origin, initial: true) { _, current in
            visitedOrigins.insert(current)
        }
        .onReceive(NotificationCenter.default.publisher(for: GalleryActionService.siteChangedNotification)) { _ in
            // Keeping an old site's rows would misrepresent the selected site.
            // Reopen inactive sources lazily instead of requesting them all now.
            visitedOrigins = [origin]
        }
    }

    @ViewBuilder
    private func list(for source: BrowseSource) -> some View {
        if let workspace = scopedRoute(for: source) {
            GalleryListView(workspace: workspace, onRequestDirectRead: onRequestDirectRead,
                            browseSource: selection, toplistPeriod: source == .toplist ? $toplistPeriod : nil)
        } else {
        GalleryListView(
            mode: source.listMode(toplistPeriod: toplistPeriod, searchQuery: search.query),
            browseSource: selection,
            toplistPeriod: source == .toplist ? $toplistPeriod : nil,
            initialBrowseSearch: source == .search ? search : nil,
            onSearchSubmit: showSearch,
            onSearchReplay: { preset in
                // Even the same preset reopens at page one when explicitly replayed.
                replayGeneration &+= 1
                showSearch(preset)
            },
            onRequestDirectRead: onRequestDirectRead
        )
        }
    }

    private func showSearch(_ submitted: GalleryBrowseSearch) {
        search = submitted
        route.setSearchResultsVisible(submitted.showsResults)
    }

    private struct SearchIdentity: Hashable {
        let search: GalleryBrowseSearch
        let replayGeneration: Int
    }

    private struct OriginIdentity: Hashable {
        let source: BrowseSource
        let period: Int
    }
}


private struct EhBrowseOriginIsCurrentKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var ehBrowseOriginIsCurrent: Bool {
        get { self[EhBrowseOriginIsCurrentKey.self] }
        set { self[EhBrowseOriginIsCurrentKey.self] = newValue }
    }
}
