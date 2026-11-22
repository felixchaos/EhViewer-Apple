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
    @State private var toplistPeriod = 15
    @State private var search = GalleryBrowseSearch(query: "")

    private var selection: Binding<BrowseSource> {
        Binding(get: { route.selection }, set: { route.select($0) })
    }

    var body: some View {
        let origin = route.origin
        let isShowingSearch = route.isShowingSearch
        ZStack {
            list(for: origin)
                .id(OriginIdentity(source: origin, period: origin == .toplist ? toplistPeriod : 0))
                .opacity(isShowingSearch ? 0 : 1)
                .allowsHitTesting(!isShowingSearch)
                .accessibilityHidden(isShowingSearch)
                .ehSuspendTabBarDriver(isShowingSearch)

            if isShowingSearch {
                list(for: .search)
                    .id(search)
            }
        }
    }

    private func list(for source: BrowseSource) -> some View {
        GalleryListView(
            mode: source.listMode(toplistPeriod: toplistPeriod, searchQuery: search.query),
            browseSource: selection,
            toplistPeriod: source == .toplist ? $toplistPeriod : nil,
            initialBrowseSearch: source == .search ? search : nil,
            onSearchSubmit: { submitted in
                search = submitted
                route.setSearchResultsVisible(submitted.showsResults)
            }
        )
    }

    private struct OriginIdentity: Hashable {
        let source: BrowseSource
        let period: Int
    }
}
