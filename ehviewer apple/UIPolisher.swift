//
//  UIPolisher.swift
//  ehviewer apple
//
//  Visual & Haptic polish utilities — Store-grade UX
//  包含: 触感反馈引擎、语义化颜色、调试日志守卫
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Haptic Feedback Engine

/// 统一触感反馈入口 — 对齐 Apple HIG "触觉反馈应与视觉反馈同步"
/// 使用预热的 Generator 避免首次延迟
enum Haptics {
    #if os(iOS)
    // 预热实例 (第一次调用 .prepare() 后系统分配硬件资源)
    private static let light    = UIImpactFeedbackGenerator(style: .light)
    private static let medium   = UIImpactFeedbackGenerator(style: .medium)
    private static let heavy    = UIImpactFeedbackGenerator(style: .heavy)
    private static let soft     = UIImpactFeedbackGenerator(style: .soft)
    private static let rigid    = UIImpactFeedbackGenerator(style: .rigid)
    private static let selection = UISelectionFeedbackGenerator()
    private static let notification = UINotificationFeedbackGenerator()
    #endif

    /// 轻触反馈 — 页面切换、选项选中
    static func tap() {
        #if os(iOS)
        light.prepare()
        light.impactOccurred()
        #endif
    }

    /// 中等反馈 — 收藏、下载等操作确认
    static func impact() {
        #if os(iOS)
        medium.prepare()
        medium.impactOccurred()
        #endif
    }

    /// 重击反馈 — 删除、长按等破坏性操作
    static func heavyImpact() {
        #if os(iOS)
        heavy.prepare()
        heavy.impactOccurred()
        #endif
    }

    /// 选择反馈 — Picker 切换、Slider 步进
    static func select() {
        #if os(iOS)
        selection.prepare()
        selection.selectionChanged()
        #endif
    }

    /// 成功通知 — 操作完成
    static func success() {
        #if os(iOS)
        notification.prepare()
        notification.notificationOccurred(.success)
        #endif
    }

    /// 错误通知 — 操作失败、网络错误
    static func error() {
        #if os(iOS)
        notification.prepare()
        notification.notificationOccurred(.error)
        #endif
    }

    /// 警告通知 — 确认弹窗前
    static func warning() {
        #if os(iOS)
        notification.prepare()
        notification.notificationOccurred(.warning)
        #endif
    }
}

// MARK: - Semantic Color Helpers

/// 分类标签文字色 — 始终白色 (因为背景是彩色 category.color)
/// 这不是深色模式问题: 分类标签背景始终是纯色 (红/蓝/绿等)，文字必须保持白色
/// 保留 .foregroundStyle(.white) 是正确的

// MARK: - Debug Log Guard

/// Release 构建下静默的日志宏 — 替代裸 print()
/// DEBUG 构建保持输出; Release 构建编译器会完全消除调用 (空函数 + @inlinable)
@inlinable
func debugLog(_ message: @autoclosure () -> String, file: String = #file, line: Int = #line) {
    #if DEBUG
    let filename = (file as NSString).lastPathComponent
    print("[\(filename):\(line)] \(message())")
    #endif
}
