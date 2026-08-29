//
//  LaunchTabTests.swift
//  ehviewer appleTests
//
//  「启动页面」设置决定冷启动落在哪个底部标签。
//
//  底部内容是 ForEach(bottomTabs) { .opacity(selectedTab == tab ? 1 : 0) }：
//  selectedTab 一旦落在 bottomTabs 之外，没有任何图层匹配，全部 opacity 0——
//  整屏黑，只剩浮起导航条，而且每次冷启动都这样。
//
//  这不是假想：「热门」「排行」并进首页顶部切页之后，fromLaunchPage 仍然返回
//  .popular / .toplist，把启动页面设成这两项的用户一直在看黑屏。
//

import Testing
@testable import ehviewer_apple

@MainActor
struct LaunchTabTests {

    /// 任何「启动页面」取值都必须落在底部栏里，包括没定义过的值
    @Test func everyLaunchPageMapsToABottomTab() {
        for page in -1...10 {
            let tab = MainTabView.Tab.fromLaunchPage(page)
            #expect(MainTabView.Tab.bottomTabs.contains(tab),
                    "启动页面 \(page) 映射到 \(tab.rawValue)，它不在底部栏里 → 冷启动黑屏")
        }
    }

    /// 热门与排行不再是独立标签页，应当落到首页（切页由 initialBrowseSource 决定）
    @Test func popularAndToplistLandOnHome() {
        #expect(MainTabView.Tab.fromLaunchPage(1) == .home)
        #expect(MainTabView.Tab.fromLaunchPage(2) == .home)
    }

    /// 其余几项仍然各自对应自己的标签
    @Test func remainingPagesKeepTheirTabs() {
        #expect(MainTabView.Tab.fromLaunchPage(0) == .home)
        #expect(MainTabView.Tab.fromLaunchPage(3) == .favorites)
        #expect(MainTabView.Tab.fromLaunchPage(4) == .downloads)
        #expect(MainTabView.Tab.fromLaunchPage(5) == .history)
    }
}
