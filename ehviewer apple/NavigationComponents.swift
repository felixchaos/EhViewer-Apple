//
//  NavigationComponents.swift
//  ehviewer apple
//
//  全局导航规范组件:
//  1. AppBackButton — 统一返回按钮 (Chevron 圆形半透明)
//  2. EdgeSwipeBackModifier — 恢复边缘滑动返回手势
//  3. NavigationBarCompact — 强制 inline 标题栏修饰符
//

import SwiftUI

#if os(iOS)
import UIKit
#endif

// MARK: - 1. 统一返回按钮 (对齐 Android Toolbar NavigationIcon)

/// 全局统一返回按钮 — 所有二级及深层页面使用同一样式
///
/// 样式: Chevron 图标 + 半透明圆形背景
/// 位置: 左上角叠加 (overlay alignment: .topLeading)
///
/// 使用方式:
/// ```swift
/// .overlay(alignment: .topLeading) {
///     AppBackButton { dismiss() }
/// }
/// ```
struct AppBackButton: View {
    let action: () -> Void
    
    /// 背景风格: 当页面有深色/图片背景时使用 dark, 普通页面用 light
    var style: Style = .dark
    
    enum Style {
        case dark   // 白色图标 + 黑色半透明背景 (用于图片/深色背景上)
        case light  // 系统颜色 + 浅色材质背景 (用于普通列表页)
    }
    
    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(style == .dark ? .white : Color.primary)
                .padding(8)
                .background(
                    style == .dark
                        ? AnyShapeStyle(.black.opacity(0.5))
                        : AnyShapeStyle(.ultraThinMaterial)
                )
                .clipShape(Circle())
        }
        .accessibilityLabel("返回")
    }
}

// MARK: - 2. 边缘滑动返回手势修复

/// 修复 SwiftUI 隐藏原生返回按钮后边缘滑动返回手势失效的问题
///
/// 原理: 在 UINavigationController 上重新启用 interactivePopGestureRecognizer
/// 并将其 delegate 替换为自定义实现，确保在任何自定义导航栏下都能滑动返回
///
/// 使用方式:
/// ```swift
/// NavigationStack {
///     content
/// }
/// .enableEdgeSwipeBack()
/// ```
#if os(iOS)
struct EdgeSwipeBackModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(EdgeSwipeBackHelper())
    }
}

/// UIKit 辅助视图 — 查找最近的 UINavigationController 并启用滑动返回
private struct EdgeSwipeBackHelper: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        EdgeSwipeBackViewController()
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

private class EdgeSwipeBackViewController: UIViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        enableInteractivePopGesture()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        enableInteractivePopGesture()
    }
    
    private func enableInteractivePopGesture() {
        guard let nav = navigationController else { return }
        // 仅在有多个视图控制器时启用 (栈顶不需要)
        guard nav.viewControllers.count > 1 else { return }
        // 如果 delegate 已被清除或是系统默认的，替换为允许手势的 delegate
        if nav.interactivePopGestureRecognizer?.isEnabled == false {
            nav.interactivePopGestureRecognizer?.isEnabled = true
        }
        // 确保手势识别器的 delegate 不会阻止手势
        if nav.interactivePopGestureRecognizer?.delegate !== nav {
            nav.interactivePopGestureRecognizer?.delegate = nav
        }
    }
}

// MARK: - UINavigationController + InteractivePopGesture

/// 让 UINavigationController 自身作为滑动返回手势的 delegate
/// 这样即使隐藏了原生返回按钮，边缘滑动返回依然有效
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // 导航栈只有一个 VC 时禁止滑动 (没有上一页可返回)
        viewControllers.count > 1
    }
    
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // 允许与其他手势同时识别，避免冲突
        false
    }
}
#endif

// MARK: - 3. View 扩展

extension View {
    /// 启用边缘滑动返回手势 (修复隐藏原生返回按钮后手势失效)
    @ViewBuilder
    func enableEdgeSwipeBack() -> some View {
        #if os(iOS)
        self.modifier(EdgeSwipeBackModifier())
        #else
        self
        #endif
    }
    
    /// 紧凑导航栏修饰符 — 强制 inline 标题 + 隐藏大标题空间
    @ViewBuilder
    func compactNavigationBar() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
