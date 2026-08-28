//
//  EhTheme.swift
//  ehviewer apple
//
//  设计系统 — 颜色
//
//  取值来自「暗房」设计稿的 Design Tokens，深浅两套一一对应。
//
//  这里用平台动态色（UIColor/NSColor 的 dynamic provider）而不是在每个视图里读
//  `@Environment(\.colorScheme)` 再三元选值。原因有三：
//
//    1. 动态色在任意嵌套层级都成立，包括 UIKit 桥接的部分（KeyCommandCatcher、
//       ZoomableImageView 等）——环境值传不进去那些地方
//    2. `.preferredColorScheme` 强制主题时会一并生效，不需要额外接线
//    3. 视图里少一层三元表达式，body 更薄
//

import SwiftUI

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// MARK: - 动态色构造

extension Color {
    /// 按明暗自动取值的颜色。参数为 0xRRGGBB 与不透明度。
    static func ehDynamic(
        light: UInt32, lightAlpha: Double = 1,
        dark: UInt32, darkAlpha: Double = 1
    ) -> Color {
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(rgb: dark, alpha: darkAlpha)
                : UIColor(rgb: light, alpha: lightAlpha)
        })
        #else
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark
                ? NSColor(rgb: dark, alpha: darkAlpha)
                : NSColor(rgb: light, alpha: lightAlpha)
        })
        #endif
    }

    /// 深浅同色，仅指定一次
    static func ehFixed(_ rgb: UInt32, alpha: Double = 1) -> Color {
        .ehDynamic(light: rgb, lightAlpha: alpha, dark: rgb, darkAlpha: alpha)
    }
}

#if canImport(UIKit)
private extension UIColor {
    convenience init(rgb: UInt32, alpha: Double) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: CGFloat(alpha)
        )
    }
}
#else
private extension NSColor {
    convenience init(rgb: UInt32, alpha: Double) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: CGFloat(alpha)
        )
    }
}
#endif

// MARK: - 色板

enum EhColor {

    // ── 背景 ──────────────────────────────────────

    /// 页面底色。深色 #0C0C0E / 浅色 #FFFFFF
    static let background = Color.ehDynamic(light: 0xFFFFFF, dark: 0x0C0C0E)

    /// 分组式页面的底色（设置、我的）。浅色下比 background 更灰，深色下与之相同
    static let groupedBackground = Color.ehDynamic(light: 0xF2F2F7, dark: 0x0C0C0E)

    /// 卡面 / 分组容器。深色 #17171B / 浅色 #FFFFFF
    static let card = Color.ehDynamic(light: 0xFFFFFF, dark: 0x17171B)

    /// 填充控件底（胶囊、chip、未选中的 segmented）
    static let fill = Color.ehDynamic(
        light: 0x767680, lightAlpha: 0.12,
        dark: 0x767680, darkAlpha: 0.16
    )

    /// 缩略图占位。深色 #1D1D21 / 浅色 #F0F0F3
    static let thumbnailPlaceholder = Color.ehDynamic(light: 0xF0F0F3, dark: 0x1D1D21)

    /// Sheet 底。深色 #1A1A1E / 浅色 #FFFFFF
    static let sheetBackground = Color.ehDynamic(light: 0xFFFFFF, dark: 0x1A1A1E)

    // ── 浮起玻璃 ───────────────────────────────────
    //
    // 导航条与阅读器工具栏的底色。叠在 `.ultraThinMaterial` 之上使用：
    // 材质负责模糊，这一层负责压暗/提亮到设计稿的观感。

    static let glass = Color.ehDynamic(
        light: 0xFAFAFC, lightAlpha: 0.90,
        dark: 0x2C2C30, darkAlpha: 0.86
    )

    /// 玻璃层的描边
    static let glassStroke = Color.ehDynamic(
        light: 0x3C3C43, lightAlpha: 0.08,
        dark: 0xEBEBF5, darkAlpha: 0.10
    )

    // ── 分隔线 ─────────────────────────────────────

    /// 列表行之间的 hairline
    static let hairline = Color.ehDynamic(
        light: 0x3C3C43, lightAlpha: 0.10,
        dark: 0xEBEBF5, darkAlpha: 0.08
    )

    /// 分组容器内部的分隔线，比 hairline 再弱一档
    static let hairlineInset = Color.ehDynamic(
        light: 0x3C3C43, lightAlpha: 0.08,
        dark: 0xEBEBF5, darkAlpha: 0.07
    )

    /// 卡片描边（浅色下需要，深色下几乎不可见）
    static let cardStroke = Color.ehDynamic(
        light: 0x3C3C43, lightAlpha: 0.08,
        dark: 0xEBEBF5, darkAlpha: 0.06
    )

    // ── 文字 ───────────────────────────────────────

    static let label = Color.ehDynamic(light: 0x1C1C1E, dark: 0xFFFFFF)

    static let secondaryLabel = Color.ehDynamic(
        light: 0x3C3C43, lightAlpha: 0.55,
        dark: 0xEBEBF5, darkAlpha: 0.45
    )

    static let tertiaryLabel = Color.ehDynamic(
        light: 0x3C3C43, lightAlpha: 0.40,
        dark: 0xEBEBF5, darkAlpha: 0.35
    )

    // ── 强调色 ─────────────────────────────────────
    //
    // 琥珀 #FFB340 在浅色背景上对比度不足（约 1.8:1），因此浅色模式下
    // **文字与描边**改用加深的 #A85A00；**填充块**仍用 #FFB340，其上文字用 #241800。
    // 深色模式下两者都用 #FFB340。

    /// 用于文字、图标、描边、下划线
    static let accent = Color.ehDynamic(light: 0xA85A00, dark: 0xFFB340)

    /// 用于填充（主按钮、选中块、开关轨、进度条）
    static let accentFill = Color.ehFixed(0xFFB340)

    /// 叠在 accentFill 之上的文字色
    static let onAccentFill = Color.ehDynamic(light: 0x241800, dark: 0x0C0C0E)

    /// 强调色的淡底（「继续阅读」条的渐隐背景等）
    static let accentWash = Color.ehFixed(0xFFB340, alpha: 0.14)

    // ── 语义色 ─────────────────────────────────────

    static let success = Color.ehDynamic(light: 0x248A3D, dark: 0x32D74B)
    static let warning = Color.ehDynamic(light: 0xC77700, dark: 0xFF9F0A)
    static let danger  = Color.ehDynamic(light: 0xD70015, dark: 0xFF453A)
    static let info    = Color.ehDynamic(light: 0x007AFF, dark: 0x0A84FF)

    // ── 控件 ───────────────────────────────────────

    /// 开关关闭时的轨道色
    static let switchTrackOff = Color.ehDynamic(
        light: 0x767680, lightAlpha: 0.16,
        dark: 0x767680, darkAlpha: 0.32
    )
}

// MARK: - 主题设置

/// 外观设置的三个选项，对应「设置 · 外观」的三张卡片。
///
/// rawValue 直接对应已有的 `AppSettings.theme`（0 跟随系统 / 1 浅色 / 2 深色，
/// 对齐 Android 的 `Settings.KEY_THEME`）——不要另立一份设置，
/// `RootView.computeColorScheme()` 读的就是它。
enum EhAppTheme: Int, CaseIterable, Identifiable {
    case system = 0
    case light = 1
    case dark = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light:  return "浅色"
        case .dark:   return "深色"
        }
    }

    /// 传给 `.preferredColorScheme`；`nil` 表示跟随系统
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

// MARK: - 阅读器配色

/// 阅读器工具条的颜色。**不跟随明暗模式**。
///
/// 阅读器底色恒为纯黑，工具条却在用跟随主题的 EhColor：浅色模式下
/// 黑画面上贴着亮白面板、深色文字，对比刺眼且与画面完全不搭。
/// 这里全部固定成「深色底 + 浅色字」。
enum EhReaderChrome {
    static let label = Color.white.opacity(0.95)
    static let secondaryLabel = Color.white.opacity(0.65)
    static let tertiaryLabel = Color.white.opacity(0.42)
    static let fill = Color.white.opacity(0.14)
}
