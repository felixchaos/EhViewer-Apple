//
//  KeyCommandCatcher.swift
//  ehviewer apple
//
//  iOS 硬件按键捕获 — 供阅读器接收外置蓝牙翻页器 / 实体键盘的按键
//
//  为什么不用 SwiftUI 的 `.focusable()` + `@FocusState`:
//  在 iOS 上把一个普通视图设成 focusable 再程序化聚焦，系统会把它当成文本输入目标，
//  于是弹出软键盘（在阅读器里切换阅读方向时就会看到），而且 SwiftUI 的焦点手势
//  会和阅读器内部的点击/缩放手势抢事件，导致点击翻页失灵。
//
//  正确做法是走 UIKit 的 responder chain: 一个不实现 UIKeyInput 的普通 UIView
//  成为 first responder 时**不会**唤起键盘，但照样能通过 `keyCommands` 收到按键。
//

#if os(iOS)

import SwiftUI
import UIKit

/// 阅读器要处理的按键动作
enum ReaderKeyAction {
    case previousPage
    case nextPage
    case firstPage
    case lastPage
    case dismiss
    /// 方向键 —— 由调用方按当前阅读方向决定翻哪边
    case arrowLeft
    case arrowRight
    case arrowUp
    case arrowDown
}

struct KeyCommandCatcher: UIViewRepresentable {
    let onKey: (ReaderKeyAction) -> Void

    func makeUIView(context: Context) -> KeyCommandView {
        let view = KeyCommandView()
        view.onKey = onKey
        return view
    }

    func updateUIView(_ view: KeyCommandView, context: Context) {
        view.onKey = onKey
    }
}

final class KeyCommandView: UIView {
    var onKey: ((ReaderKeyAction) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // 零尺寸 + 不接收触摸: 只借 responder chain 收按键，绝不参与点击命中测试
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // ⚠️ 关键: 只 becomeFirstResponder，不实现 UIKeyInput —— 因此不会弹出软键盘
    override var canBecomeFirstResponder: Bool { true }

    /// 菜单 (Picker / Menu) 打开时 UIKit 会为"输入首字母跳选"开一个文本输入会话；
    /// 如果当前 first responder 是我们这个非文本视图，系统就会兜底弹出软键盘 ——
    /// 这正是"切换阅读方向时冒出键盘"的原因。给它一个零高度的 inputView，
    /// 会话照常开，但没有可见键盘。
    private let emptyInputView = UIView(frame: .zero)
    override var inputView: UIView? { emptyInputView }
    override var inputAccessoryView: UIView? { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            // 等本轮布局结束再抢焦点，否则可能被随后的视图安装抢走
            DispatchQueue.main.async { [weak self] in
                _ = self?.becomeFirstResponder()
            }
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        // 覆盖翻页器常见的三类按键: 方向键、翻页键、空格/回车
        let commands: [(String, ReaderKeyAction)] = [
            (UIKeyCommand.inputLeftArrow,  .arrowLeft),
            (UIKeyCommand.inputRightArrow, .arrowRight),
            (UIKeyCommand.inputUpArrow,    .arrowUp),
            (UIKeyCommand.inputDownArrow,  .arrowDown),
            (UIKeyCommand.inputPageUp,     .previousPage),
            (UIKeyCommand.inputPageDown,   .nextPage),
            (UIKeyCommand.inputHome,       .firstPage),
            (UIKeyCommand.inputEnd,        .lastPage),
            (UIKeyCommand.inputEscape,     .dismiss),
            (" ",                          .nextPage),
            ("\r",                         .nextPage),
        ]

        return commands.map { input, action in
            // propertyList 是只读的，只能经 init 传入
            let command = UIKeyCommand(
                action: #selector(handleKey(_:)),
                input: input,
                modifierFlags: [],
                propertyList: Self.key(for: action)
            )
            // 空格/方向键默认会被系统滚动行为吃掉，这里要优先级
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc private func handleKey(_ sender: UIKeyCommand) {
        guard let raw = sender.propertyList as? String,
              let action = Self.actionFromKey(raw) else { return }
        onKey?(action)
    }

    // UIKeyCommand.propertyList 只能放 plist 类型，用字符串编码枚举
    private static func key(for action: ReaderKeyAction) -> String {
        switch action {
        case .previousPage: return "prev"
        case .nextPage:     return "next"
        case .firstPage:    return "first"
        case .lastPage:     return "last"
        case .dismiss:      return "dismiss"
        case .arrowLeft:    return "left"
        case .arrowRight:   return "right"
        case .arrowUp:      return "up"
        case .arrowDown:    return "down"
        }
    }

    private static func actionFromKey(_ raw: String) -> ReaderKeyAction? {
        switch raw {
        case "prev":    return .previousPage
        case "next":    return .nextPage
        case "first":   return .firstPage
        case "last":    return .lastPage
        case "dismiss": return .dismiss
        case "left":    return .arrowLeft
        case "right":   return .arrowRight
        case "up":      return .arrowUp
        case "down":    return .arrowDown
        default:        return nil
        }
    }
}

#endif
