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

    /// 对应的列表模式。
    ///
    /// 排行榜此前不走 GalleryListView（另有一套「名次 + 一行文字」的视图），
    /// 结果那一页和 App 里其它画廊列表完全不是一个东西。
    /// toplist.php 返回的本来就是标准画廊列表表格，所以现在统一走这里。
    func listMode(toplistPeriod: Int) -> GalleryListView.ListMode {
        switch self {
        case .home:         return .home
        case .subscription: return .subscription
        case .popular:      return .popular
        case .toplist:      return .toplist(period: toplistPeriod)
        }
    }
}

struct BrowseHomeView: View {
    @State private var source: BrowseSource
    /// 排行榜的时间范围（toplist.php 的 tl）。默认全部时间。
    @State private var toplistPeriod = 15

    init(initial: BrowseSource = .home) {
        _source = State(initialValue: initial)
    }

    var body: some View {
        // 切页条由 GalleryListView 渲染在自己的搜索栏下方，
        // 这样「搜索 → 切页 → 列表」的纵向顺序与设计稿一致。
        GalleryListView(
            mode: source.listMode(toplistPeriod: toplistPeriod),
            browseSource: $source,
            toplistPeriod: source == .toplist ? $toplistPeriod : nil
        )
        // 数据源或时间范围变了就重建：每个源有各自的分页游标与筛选条件，
        // 复用同一个 ViewModel 会把上一个源的游标带到下一个源。
        .id("\(source.rawValue)-\(source == .toplist ? toplistPeriod : 0)")
    }
}
