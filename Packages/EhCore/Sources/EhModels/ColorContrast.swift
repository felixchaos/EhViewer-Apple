//
//  ColorContrast.swift
//  EhModels
//
//  分类色的可读性调整
//
//  Android 的分类色是给「白字 + 实心填充块」设计的。新界面里这些颜色还要当作
//  小号文字直接画在背景上，此时有两处读不清：
//
//    - 深色底：Image Set 的靛蓝 #3F51B5 相对 #0C0C0E 的对比度约 2.5:1
//    - 浅色底：Artist CG 的黄 #FBC02D 相对 #FFFFFF 的对比度约 1.7:1
//
//  这里只推亮度、不动色相与饱和度——分类色是识别标识，色相变了就不是它了。
//

import SwiftUI

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

extension Color {
    /// 按当前外观把颜色的亮度推进可读区间。
    ///
    /// 深色外观下把亮度抬到不低于 0.62，浅色外观下压到不高于 0.45。
    /// 已经落在区间内的颜色原样返回。
    public func ehContrastAdjusted() -> Color {
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            let base = UIColor(self)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            guard base.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return base }
            let adjusted = Self.adjustBrightness(b, isDark: traits.userInterfaceStyle == .dark)
            return UIColor(hue: h, saturation: s, brightness: adjusted, alpha: a)
        })
        #else
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            guard let base = NSColor(self).usingColorSpace(.deviceRGB) else { return NSColor(self) }
            let adjusted = Self.adjustBrightness(base.brightnessComponent, isDark: isDark)
            return NSColor(
                hue: base.hueComponent,
                saturation: base.saturationComponent,
                brightness: adjusted,
                alpha: base.alphaComponent
            )
        })
        #endif
    }

    private static func adjustBrightness(_ b: CGFloat, isDark: Bool) -> CGFloat {
        isDark ? max(b, 0.62) : min(b, 0.45)
    }

    /// 0xRRGGBB 字面量构造
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}
