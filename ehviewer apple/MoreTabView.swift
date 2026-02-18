//
//  MoreTabView.swift
//  ehviewer apple
//
//  "更多"标签页 — iOS 底部菜单的第4个标签
//  包含: 热门、排行榜、历史、设置
//  (对齐 Android DrawerLayout 中非底部固定的菜单项)
//

import SwiftUI
import EhSettings

struct MoreTabView: View {
    let onNavigate: (MainTabView.Tab) -> Void
    /// 启动页面指定的非底部 tab — 自动导航到该页面
    var initialTab: MainTabView.Tab? = nil

    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    ForEach(MainTabView.Tab.moreTabs, id: \.self) { tab in
                        NavigationLink(value: tab) {
                            Label(tab.rawValue, systemImage: tab.icon)
                        }
                    }
                }
            }
            .navigationTitle("更多")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationDestination(for: MainTabView.Tab.self) { tab in
                morePageContent(tab)
            }
        }
        .task {
            // 启动页面自动导航: 用户设置了热门/排行榜/历史作为启动页 → 直接推入
            if let tab = initialTab, path.isEmpty {
                path.append(tab)
            }
        }
    }

    @ViewBuilder
    private func morePageContent(_ tab: MainTabView.Tab) -> some View {
        switch tab {
        case .popular:
            GalleryListView(mode: .popular, isPushed: true)
        case .toplist:
            TopListView(isPushed: true)
        case .history:
            HistoryView(isPushed: true)
        case .settings:
            SettingsView(isPushed: true)
        default:
            EmptyView()
        }
    }
}
