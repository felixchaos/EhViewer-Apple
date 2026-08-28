//
//  EhToast.swift
//  ehviewer apple
//
//  轻提示 — 对齐 Android BaseScene.showTip
//
//  收藏、下载这类动作在 Android 上都会弹一条 Toast（「已添加至收藏」
//  「已添加至下载列表」）。iOS 端此前只有一次触感反馈：动作其实执行了，
//  但屏幕上什么都不变，用起来就是「点了没反应」。
//
//  这里补一条浮在底部导航条上方的胶囊提示，2 秒后自动消失。
//

import SwiftUI

@Observable
@MainActor
final class EhToastCenter {
    static let shared = EhToastCenter()

    struct Toast: Equatable {
        enum Kind { case success, failure, info }
        let text: String
        let kind: Kind
        /// 同样的文字连续弹两次也要能重新计时，用序号区分
        let seq: Int
    }

    private(set) var current: Toast?
    private var seq = 0
    private var dismissTask: Task<Void, Never>?

    private init() {}

    func show(_ text: String, kind: Toast.Kind = .info) {
        seq += 1
        current = Toast(text: text, kind: kind, seq: seq)
        dismissTask?.cancel()
        let mySeq = seq
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.current?.seq == mySeq else { return }
            self.current = nil
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }
}

/// 便捷入口：`EhToast.success("已添加至收藏")`
enum EhToast {
    @MainActor static func success(_ text: String) {
        Haptics.success()
        EhToastCenter.shared.show(text, kind: .success)
    }

    @MainActor static func failure(_ text: String) {
        Haptics.error()
        EhToastCenter.shared.show(text, kind: .failure)
    }

    @MainActor static func info(_ text: String) {
        EhToastCenter.shared.show(text, kind: .info)
    }
}

private struct EhToastHost: ViewModifier {
    @State private var center = EhToastCenter.shared

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let toast = center.current {
                HStack(spacing: 8) {
                    if let symbol = symbol(for: toast.kind) {
                        Image(systemName: symbol)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(tint(for: toast.kind))
                    }
                    Text(toast.text)
                        .font(EhFont.caption)
                        .foregroundStyle(EhColor.label)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .ehGlass(cornerRadius: 22)
                .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
                // 让开浮起导航条，否则提示正好压在「下载」「收藏」两个图标上
                .padding(.bottom, EhSize.tabBarHeight + EhSize.tabBarBottomInset + 14)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onTapGesture { center.dismiss() }
                .allowsHitTesting(true)
            }
        }
        // 提示是纯反馈，不该拦住下面的列表
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: center.current)
    }

    private func symbol(for kind: EhToastCenter.Toast.Kind) -> String? {
        switch kind {
        case .success: "checkmark.circle.fill"
        case .failure: "exclamationmark.triangle.fill"
        case .info: nil
        }
    }

    private func tint(for kind: EhToastCenter.Toast.Kind) -> Color {
        switch kind {
        case .success: EhColor.success
        case .failure: EhColor.danger
        case .info: EhColor.secondaryLabel
        }
    }
}

extension View {
    /// 挂在根视图上，全 App 共用一个提示层
    func ehToastHost() -> some View {
        modifier(EhToastHost())
    }
}
