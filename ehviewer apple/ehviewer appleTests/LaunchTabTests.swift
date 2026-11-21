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

import Combine
import CoreFoundation
import CoreGraphics
import Foundation
import SwiftUI
import Testing
#if os(iOS)
import UIKit
#endif
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

    @Test func chromeRespondsToAvailableWidthWithoutDependingOnSizeClass() {
        let narrow = ResponsiveLayout(size: .init(width: 610, height: 780), horizontalSizeClass: .regular)
        let expanded = ResponsiveLayout(size: .init(width: 820, height: 780), horizontalSizeClass: .regular)
        let sameWidthCompact = ResponsiveLayout(size: .init(width: 820, height: 780), horizontalSizeClass: .compact)
        #expect(!ResponsiveLayout.usesTabSidebar(width: narrow.width))
        #expect(ResponsiveLayout.usesTabSidebar(width: expanded.width))
        #expect(ResponsiveLayout.usesTabSidebar(width: sameWidthCompact.width))
    }

    @Test func wideOnlyTabRemainsMountedWhenNarrowingAndAfterSelectingAnotherTab() {
        typealias Tab = MainTabView.Tab
        #expect(Tab.adaptiveContentTabs(visitedExtras: [], selected: .home) == Tab.bottomTabs)
        let selected = Tab.adaptiveContentTabs(visitedExtras: [], selected: .subscription)
        #expect(selected.contains(.subscription))
        #expect(!selected.contains(.settings))
        #expect(Tab.adaptiveContentTabs(visitedExtras: [.subscription], selected: .home) == selected)
    }

    @Test func quickSearchDrawerFitsNarrowWindows() {
        #expect(ResponsiveLayout.quickSearchDrawerWidth(in: 250) == 226)
        #expect(ResponsiveLayout.quickSearchDrawerWidth(in: 390) == 280)
        #expect(ResponsiveLayout.quickSearchDrawerWidth(in: 0) == 0)
    }
}

#if os(iOS)
@MainActor
private final class TabBarPreferenceProbe: ObservableObject {
    @Published var homeIsActive = true
    @Published var width: CGFloat = 800
    var hidesTabBar = false
    var homeAppearCount = 0
}

@MainActor
private struct TabBarPreferenceFixture: View {
    @ObservedObject var probe: TabBarPreferenceProbe

    var body: some View {
        GeometryReader { geometry in
            HStack {
                if ResponsiveLayout.usesTabSidebar(width: geometry.size.width) {
                    Color.clear.frame(width: ResponsiveLayout.tabSidebarWidth)
                }
                ZStack {
                    Color.blue
                        .ehHidesTabBar()
                        .onAppear { probe.homeAppearCount += 1 }
                        .opacity(probe.homeIsActive ? 1 : 0)
                        .ehTabBarDriver(active: probe.homeIsActive)
                    Color.red
                        .opacity(probe.homeIsActive ? 0 : 1)
                        .ehTabBarDriver(active: !probe.homeIsActive)
                }
            }
        }
        .frame(width: probe.width, height: 240)
        .onPreferenceChange(EhHidesTabBarKey.self) { probe.hidesTabBar = $0 }
    }
}

@MainActor
struct RetainedTabBarTests {
    @Test func inactiveDetailCannotHideBottomNavigationAfterNarrowing() async throws {
        let probe = TabBarPreferenceProbe()
        let host = UIHostingController(rootView: TabBarPreferenceFixture(probe: probe))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }

        func flushLayout() async throws {
            for _ in 0..<8 {
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        try await flushLayout()
        #expect(probe.hidesTabBar)
        #expect(probe.homeAppearCount == 1)

        // Wide sidebar selects Downloads, then the device folds with Home detail retained.
        probe.homeIsActive = false
        probe.width = 390
        try await flushLayout()
        #expect(!probe.hidesTabBar)
        #expect(probe.homeAppearCount == 1)

        // Returning Home restores the still-mounted detail and its own preference.
        probe.width = 800
        probe.homeIsActive = true
        try await flushLayout()
        #expect(probe.hidesTabBar)
        #expect(probe.homeAppearCount == 1)
    }
}
#endif
