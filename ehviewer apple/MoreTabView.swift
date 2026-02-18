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

    var body: some View {
        NavigationStack {
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
            // ★ 画廊列表中的 NavigationLink(value: GalleryInfo) 需要此 destination
            .navigationDestination(for: GalleryInfo.self) { gallery in
                GalleryDetailView(gallery: gallery)
                    .id(gallery.gid)
            }
            // ★ 画廊详情中点击标签的 NavigationLink(value: TagSearchDestination) 需要此 destination
            .navigationDestination(for: TagSearchDestination.self) { dest in
                GalleryListView(mode: .tag(keyword: dest.tag), isPushed: true)
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
