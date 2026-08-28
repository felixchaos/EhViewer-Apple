//
//  EhFloatingTabBar.swift
//  ehviewer apple
//
//  浮起玻璃导航条 — 取代 iPhone 上的系统 TabBar
//
//  仅用于 iPhone（compact 宽度）。iPad regular 与 macOS 保持 NavigationSplitView
//  的侧边栏：底部标签栏这个形态在大屏上是错的，横向空间应该给内容而不是导航。
//
//  自绘导航条会丢掉系统 TabView 的一些免费行为，这里逐项补回：
//    - 重复点击当前标签回到顶部 → 经 `.ehScrollToTop` 通知，各页自行订阅
//    - 安全区避让 → 用 safeAreaInset 挂载，内容自动获得正确的底部内边距
//    - 无障碍 → 显式给出 label / traits，并保证 44pt 点按目标
//

#if os(iOS)

import SwiftUI

extension Notification.Name {
    /// 重复点击已选中的标签时发出，携带 userInfo["tab"] = 标签的 rawValue
    static let ehScrollToTop = Notification.Name("EhScrollToTop")
}

struct EhFloatingTabBar<Tab: Hashable>: View {
    struct Item {
        let value: Tab
        let title: String
        let symbol: String
        let selectedSymbol: String

        init(value: Tab, title: String, symbol: String, selectedSymbol: String? = nil) {
            self.value = value
            self.title = title
            self.symbol = symbol
            self.selectedSymbol = selectedSymbol ?? symbol + ".fill"
        }
    }

    let items: [Item]
    @Binding var selection: Tab
    /// 重复点击当前项时回调（用于回到顶部）
    var onReselect: ((Tab) -> Void)? = nil

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.value) { item in
                let isSelected = selection == item.value
                Button {
                    if isSelected {
                        onReselect?(item.value)
                    } else {
                        selection = item.value
                        Haptics.tap()
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: isSelected ? item.selectedSymbol : item.symbol)
                            .font(.system(size: 19, weight: .regular))
                            .symbolRenderingMode(.hierarchical)
                        Text(item.title)
                            .font(EhFont.tiny)
                    }
                    .foregroundStyle(isSelected ? EhColor.accent : EhColor.secondaryLabel)
                    .frame(maxWidth: .infinity)
                    .frame(height: EhSize.tabBarHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .frame(height: EhSize.tabBarHeight)
        .ehGlass(cornerRadius: EhSize.tabBarRadius)
        .padding(.horizontal, EhSize.tabBarSideInset)
        .padding(.bottom, EhSize.tabBarBottomInset)
    }
}

extension View {
    /// 把浮起导航条挂到底部安全区。
    ///
    /// 用 `safeAreaInset` 而不是 `overlay`：前者会把导航条的高度计入内容的安全区，
    /// 列表滚到底时最后一行不会被导航条盖住，也不需要在每个页面手工加 padding。
    func ehFloatingTabBar<Tab: Hashable>(
        items: [EhFloatingTabBar<Tab>.Item],
        selection: Binding<Tab>,
        onReselect: ((Tab) -> Void)? = nil
    ) -> some View {
        self.safeAreaInset(edge: .bottom, spacing: 0) {
            EhFloatingTabBar(items: items, selection: selection, onReselect: onReselect)
        }
    }
}

#endif
