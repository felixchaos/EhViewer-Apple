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
//    - 重复点击当前首页标签回到顶部 → 由当前窗口的首页列表处理
//    - 安全区避让 → 用 safeAreaInset 挂载，内容自动获得正确的底部内边距
//    - 无障碍 → 显式给出 label / traits，并保证 44pt 点按目标
//

#if os(iOS)

import SwiftUI

/// 让被推入的页面声明「这一屏不要底部导航条」。
///
/// 系统 TabView 有 `.toolbar(.hidden, for: .tabBar)`，自绘的浮条没有等价物。
/// 用 preference 从子视图向上传递：详情页、阅读器这类沉浸式页面挂一下即可，
/// 不需要把状态提到 MainTabView 再层层传下去。
struct EhHidesTabBarKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

private struct EhFloatingTabBarClearanceKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// End-of-scroll clearance for a retained NavigationStack whose native
    /// scroll viewport can extend behind the window's floating controls.
    var ehFloatingTabBarClearance: CGFloat {
        get { self[EhFloatingTabBarClearanceKey.self] }
        set { self[EhFloatingTabBarClearanceKey.self] = newValue }
    }
}

private struct EhTabBarDriverActiveKey: EnvironmentKey {
    static let defaultValue = true
}

private extension EnvironmentValues {
    var ehTabBarDriverActive: Bool {
        get { self[EhTabBarDriverActiveKey.self] }
        set { self[EhTabBarDriverActiveKey.self] = newValue }
    }
}

extension View {
    /// Retained background stacks keep their routes but cannot hide active navigation.
    func ehTabBarDriver(active: Bool) -> some View {
        environment(\.ehTabBarDriverActive, active)
            .transformPreference(EhHidesTabBarKey.self) { hides in
                if !active { hides = false }
            }
    }

    /// A retained route may suspend its own driver without enabling an inactive parent tab.
    func ehSuspendTabBarDriver(_ suspended: Bool) -> some View {
        modifier(EhSuspendTabBarDriverModifier(suspended: suspended))
    }

    /// 在这一屏隐藏底部浮起导航条
    func ehHidesTabBar(_ hidden: Bool = true) -> some View {
        preference(key: EhHidesTabBarKey.self, value: hidden)
    }
}

private struct EhSuspendTabBarDriverModifier: ViewModifier {
    @Environment(\.ehTabBarDriverActive) private var parentActive
    let suspended: Bool

    func body(content: Content) -> some View {
        content.ehTabBarDriver(active: parentActive && !suspended)
    }
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace-floating-tabs")
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
        isEnabled: Bool = true,
        onReselect: ((Tab) -> Void)? = nil
    ) -> some View {
        modifier(EhFloatingTabBarModifier(items: items, selection: selection, isEnabled: isEnabled, onReselect: onReselect))
    }
}


/// Holds only the active scroll driver's decision for this window. Inactive
/// retained tabs cannot clear another list's decision when they disappear.
@MainActor @Observable
final class EhTabBarScrollVisibility {
    private struct Hidden: Equatable {
        let owner: UUID
        let fillsWindow: Bool
    }

    private var hidden: Hidden?
    var hiddenOwner: UUID? { hidden?.owner }
    var fillsWindow: Bool { hidden?.fillsWindow == true }

    func setHidden(_ shouldHide: Bool, owner: UUID, fillsWindow: Bool = false) {
        if shouldHide {
            let next = Hidden(owner: owner, fillsWindow: fillsWindow)
            if hidden != next { hidden = next }
        } else if hiddenOwner == owner {
            hidden = nil
        }
    }

    func reset() {
        if hidden != nil { hidden = nil }
    }
}

private struct EhTabBarScrollVisibilityKey: EnvironmentKey {
    static let defaultValue: EhTabBarScrollVisibility? = nil
}

extension EnvironmentValues {
    var ehTabBarScrollVisibility: EhTabBarScrollVisibility? {
        get { self[EhTabBarScrollVisibilityKey.self] }
        set { self[EhTabBarScrollVisibilityKey.self] = newValue }
    }
}

extension View {
    /// Hide when advancing through a list and reveal on reverse scrolling.
    func ehTabBarAutoHide(enabled: Bool = true, fillsWindow: Bool = false) -> some View {
        modifier(EhTabBarAutoHideModifier(enabled: enabled, fillsWindow: fillsWindow))
    }
}

extension View {
    /// Keep the normal status-bar boundary and horizontal workspace boundary;
    /// only the active collapsed Browse surface can extend past the top inset.
    func ehWorkspaceChromeClip(topOverflow: CGFloat, bottomOverflow: CGFloat) -> some View {
        modifier(EhWorkspaceChromeClipModifier(topOverflow: topOverflow, bottomOverflow: bottomOverflow))
    }
}

private struct EhWorkspaceChromeClipModifier: ViewModifier {
    let topOverflow: CGFloat
    let bottomOverflow: CGFloat
    @Environment(\.ehTabBarScrollVisibility) private var visibility
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let fillsWindow = visibility?.fillsWindow == true
        content.clipShape(EhWorkspaceChromeClipShape(topOverflow: fillsWindow ? topOverflow : 0,
                                                     bottomOverflow: bottomOverflow))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: fillsWindow)
    }
}

private struct EhWorkspaceChromeClipShape: Shape {
    var topOverflow: CGFloat
    let bottomOverflow: CGFloat

    var animatableData: CGFloat {
        get { topOverflow }
        set { topOverflow = newValue }
    }

    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY - topOverflow,
                    width: rect.width, height: rect.height + topOverflow + bottomOverflow))
    }
}

private struct EhTabBarAutoHideModifier: ViewModifier {
    let enabled: Bool
    let fillsWindow: Bool
    @Environment(\.ehTabBarDriverActive) private var driverIsActive
    @Environment(\.ehTabBarScrollVisibility) private var visibility
    @State private var owner = UUID()
    @State private var lastOffset: CGFloat?
    @State private var isUserScrolling = false

    private struct ScrollSample: Equatable {
        let offset: CGFloat
        let viewportHeight: CGFloat
        let topInset: CGFloat
        let bottomInset: CGFloat

        func sameLayout(as other: Self) -> Bool {
            abs(viewportHeight - other.viewportHeight) < 1 &&
                abs(topInset - other.topInset) < 1 && abs(bottomInset - other.bottomInset) < 1
        }
    }

    private var active: Bool { enabled && driverIsActive && visibility != nil }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.onScrollGeometryChange(for: ScrollSample.self) { geometry in
                // Bound overscroll; releasing a bounce must not count as
                // scrolling in the opposite direction.
                let maxOffset = max(0, geometry.contentSize.height + geometry.contentInsets.top
                                    + geometry.contentInsets.bottom - geometry.containerSize.height)
                return ScrollSample(offset: min(max(0, geometry.contentOffset.y + geometry.contentInsets.top), maxOffset),
                                    viewportHeight: geometry.containerSize.height, topInset: geometry.contentInsets.top,
                                    bottomInset: geometry.contentInsets.bottom)
            } action: { old, next in
                recordOffset(next.offset, previous: old.offset, viewportChanged: !next.sameLayout(as: old))
            }
            .onScrollPhaseChange { _, phase in
                isUserScrolling = phase == .interacting || phase == .decelerating
                if !isUserScrolling { lastOffset = nil }
            }
            .onChange(of: active) { _, _ in clear() }
            .onDisappear { clear() }
        } else {
            content
        }
    }

    private func recordOffset(_ offset: CGFloat, previous: CGFloat, viewportChanged: Bool) {
        guard active else { return }
        if offset < 40 {
            lastOffset = offset
            visibility?.setHidden(false, owner: owner)
            return
        }
        // Ignore programmatic reselect/restore and layout shifts caused by
        // collapsing the header or changing the container's insets.
        guard isUserScrolling && !viewportChanged else {
            lastOffset = offset
            return
        }
        let delta = offset - (lastOffset ?? previous)
        guard abs(delta) > 12 else { return }
        lastOffset = offset
        visibility?.setHidden(delta > 0, owner: owner, fillsWindow: fillsWindow)
    }

    private func clear() {
        lastOffset = nil
        visibility?.setHidden(false, owner: owner)
    }
}

private struct EhHomeReselectKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

extension EnvironmentValues {
    /// The floating tab bar and Browse Home share this signal only within a window.
    var ehHomeReselect: UUID? {
        get { self[EhHomeReselectKey.self] }
        set { self[EhHomeReselectKey.self] = newValue }
    }
}

/// Only the root Browse Home list opts in; retained inactive tabs never scroll.
struct EhCompactHomeScrollOnReselect: ViewModifier {
    static let topAnchor = "eh-compact-home-list-top"
    @Environment(\.ehTabBarDriverActive) private var isActive
    @Environment(\.ehHomeReselect) private var reselect

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content.onChange(of: reselect) { _, _ in
                guard isActive else { return }
                // Scroll the current list without changing its identity, source or request state.
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo(Self.topAnchor, anchor: .top)
                }
            }
        }
    }
}

private struct EhFloatingTabBarModifier<Tab: Hashable>: ViewModifier {
    let items: [EhFloatingTabBar<Tab>.Item]
    @Binding var selection: Tab
    let isEnabled: Bool
    var onReselect: ((Tab) -> Void)?

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHiddenByDestination = false
    @State private var scrollVisibility = EhTabBarScrollVisibility()

    private var enablesScrollChrome: Bool { isEnabled && !voiceOverEnabled }
    private var shouldHide: Bool {
        !isEnabled || isHiddenByDestination || (enablesScrollChrome && scrollVisibility.hiddenOwner != nil)
    }

    func body(content: Content) -> some View {
        content
            .environment(\.ehFloatingTabBarClearance,
                         isEnabled ? EhSize.tabBarHeight + EhSize.tabBarBottomInset : 0)
            .environment(\.ehTabBarScrollVisibility, enablesScrollChrome ? scrollVisibility : nil)
            .onPreferenceChange(EhHidesTabBarKey.self) { hidden in
                isHiddenByDestination = hidden
                if hidden { scrollVisibility.reset() }
            }
            .onChange(of: selection) { _, _ in scrollVisibility.reset() }
            .onChange(of: enablesScrollChrome) { _, _ in scrollVisibility.reset() }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !shouldHide {
                    EhFloatingTabBar(items: items, selection: $selection, onReselect: onReselect)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            // 键盘弹出时不要把导航条顶起来——它应该留在原地被键盘盖住。
            // 必须作用在 safeAreaInset 的**结果**上：被键盘推动的是这个容器，
            // 加在内层的浮条自身没有效果。
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .background {
                EhColor.background.ignoresSafeArea(.container, edges: .bottom)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: shouldHide)
    }
}

#else
import SwiftUI

extension View {
    // The Mac shell has no floating tab bar.
    func ehSuspendTabBarDriver(_ suspended: Bool) -> some View { self }
}

#endif
