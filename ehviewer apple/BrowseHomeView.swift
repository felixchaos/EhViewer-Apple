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

/// 顶部切页的四个数据源
enum BrowseSource: String, CaseIterable, Hashable {
    case home
    case subscription
    case popular
    case toplist

    var title: String {
        switch self {
        case .home:         return "首页"
        case .subscription: return "订阅"
        case .popular:      return "热门"
        case .toplist:      return "排行"
        }
    }

    /// 对应的列表模式。排行榜有自己的视图（周期分段 + 排名列），不走 GalleryListView。
    var listMode: GalleryListView.ListMode? {
        switch self {
        case .home:         return .home
        case .subscription: return .subscription
        case .popular:      return .popular
        case .toplist:      return nil
        }
    }
}

struct BrowseHomeView: View {
    @State private var source: BrowseSource

    init(initial: BrowseSource = .home) {
        _source = State(initialValue: initial)
    }

    var body: some View {
        Group {
            if let mode = source.listMode {
                // 切页条由 GalleryListView 渲染在自己的搜索栏下方，
                // 这样「搜索 → 切页 → 列表」的纵向顺序与设计稿一致。
                GalleryListView(mode: mode, browseSource: $source)
                    // 数据源变了就重建：每个源有各自的分页游标与筛选条件，
                    // 复用同一个 ViewModel 会把上一个源的游标带到下一个源。
                    .id(source)
            } else {
                // 排行榜没有搜索框，切页条直接置顶
                VStack(spacing: 0) {
                    EhTopTabs(
                        items: BrowseSource.allCases.map { ($0, $0.title) },
                        selection: $source
                    )
                    .padding(.top, 4)
                    TopListView()
                }
            }
        }
    }
}
