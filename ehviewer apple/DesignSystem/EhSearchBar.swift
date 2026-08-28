//
//  EhSearchBar.swift
//  ehviewer apple
//
//  统一的搜索框
//
//  此前各页各写各的：首页是自绘胶囊，收藏/下载/历史用 `.searchable`。
//  这带来两个问题：
//
//    1. 样式不统一 —— 同一个 App 里有两种搜索框
//    2. iOS 26 的 `.searchable` 把搜索栏放在**屏幕底部**，于是它和浮起导航条
//       重叠，键盘弹出后也没有收起的落点
//
//  标签 token 用 UIKit 的 `UISearchTextField` 而不是自己拼「chip 行 + 输入框」：
//  它原生支持 token 与文本混排，且退格键的语义已经是对的 ——
//  光标在文本里时删字符，文本删空后再退格才删掉前一个 token。
//  自己实现这套光标语义很容易在中文输入法的 marked text 上出错。
//

import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

// MARK: - 搜索框

struct EhSearchBar: View {
    @Binding var text: String
    /// 已确定的标签，显示为可整体删除的 token
    @Binding var tokens: [String]

    var placeholder: String = "搜索标签或标题"
    var showsCancelButton: Bool = true

    @FocusState.Binding var isFocused: Bool

    /// 右侧附加按钮（标签选择器、高级搜索等）。聚焦时让位给「取消」。
    var trailingButtons: [(symbol: String, action: () -> Void)] = []
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                    .foregroundStyle(EhColor.tertiaryLabel)

                #if os(iOS)
                EhTokenSearchField(
                    text: $text,
                    tokens: $tokens,
                    placeholder: placeholder,
                    isFocused: $isFocused,
                    onSubmit: onSubmit
                )
                .frame(height: 24)
                #else
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onSubmit(onSubmit)
                #endif

                if !text.isEmpty || !tokens.isEmpty {
                    Button {
                        text = ""
                        tokens = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(EhColor.tertiaryLabel)
                    }
                    .buttonStyle(.plain)
                }

                if !isFocused {
                    ForEach(Array(trailingButtons.enumerated()), id: \.offset) { _, item in
                        Button(action: item.action) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 15))
                                .foregroundStyle(EhColor.secondaryLabel)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background {
                Capsule().fill(EhColor.fill)
            }
            .overlay {
                // 聚焦时描一圈琥珀，明确「正在输入」——
                // 深色底上仅靠光标闪烁不够显眼
                if isFocused {
                    Capsule().strokeBorder(EhColor.accentFill.opacity(0.5), lineWidth: 1)
                }
            }

            if showsCancelButton && isFocused {
                Button("取消") {
                    isFocused = false
                    text = ""
                }
                .font(EhFont.body)
                .foregroundStyle(EhColor.accent)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal, EhSpacing.page)
        .padding(.vertical, 8)
        .animation(.easeInOut(duration: 0.2), value: isFocused)
    }
}

// MARK: - 带 token 的输入框 (iOS)

#if os(iOS)

/// 包一层 `UISearchTextField`，把它的 token 能力接进 SwiftUI。
///
/// SwiftUI 的 TextField 没有 token 概念，自绘「chip 行 + 输入框」则要自己实现
/// 光标语义（文本删空后退格删 token）和中文输入法的 marked text 处理，
/// 而这些 UISearchTextField 早就做对了。
struct EhTokenSearchField: UIViewRepresentable {
    @Binding var text: String
    @Binding var tokens: [String]
    let placeholder: String
    @FocusState.Binding var isFocused: Bool
    var onSubmit: () -> Void

    func makeUIView(context: Context) -> UISearchTextField {
        let field = UISearchTextField()
        field.placeholder = placeholder
        field.borderStyle = .none
        field.backgroundColor = .clear
        field.font = .systemFont(ofSize: 15)
        field.returnKeyType = .search
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.clearButtonMode = .never          // 清除按钮由 SwiftUI 侧统一绘制
        // UISearchTextField 自带一枚放大镜。这里的图标由 SwiftUI 侧统一绘制
        // （macOS 分支没有 UISearchTextField，两端要长得一样），把内置的关掉，
        // 否则会并排出现两个放大镜。
        field.leftView = nil
        field.leftViewMode = .never
        field.delegate = context.coordinator
        field.addTarget(
            context.coordinator,
            action: #selector(Coordinator.textChanged(_:)),
            for: .editingChanged
        )
        // token 被整体删除时也要同步回 SwiftUI
        field.addTarget(
            context.coordinator,
            action: #selector(Coordinator.tokensChanged(_:)),
            for: .allEditingEvents
        )
        return field
    }

    func updateUIView(_ field: UISearchTextField, context: Context) {
        context.coordinator.parent = self

        if field.text != text {
            field.text = text
        }

        // 只在内容真的不同时重建 token，否则每次 body 求值都会打断输入
        let current = field.tokens.compactMap { $0.representedObject as? String }
        if current != tokens {
            field.tokens = tokens.map { tag in
                let token = UISearchToken(icon: nil, text: Self.displayName(for: tag))
                token.representedObject = tag
                return token
            }
        }

        if isFocused && !field.isFirstResponder {
            field.becomeFirstResponder()
        } else if !isFocused && field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    /// token 上显示去掉命名空间与结尾锚点的短名，完整值仍留在 representedObject 里。
    /// `female:"glasses$"` 在一枚 token 上显示不完，而用户认的是 "glasses"。
    private static func displayName(for tag: String) -> String {
        var t = tag
        if let colon = t.firstIndex(of: ":") { t = String(t[t.index(after: colon)...]) }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"$"))
        return t
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: EhTokenSearchField

        init(parent: EhTokenSearchField) { self.parent = parent }

        @objc func textChanged(_ field: UISearchTextField) {
            parent.text = field.text ?? ""
        }

        @objc func tokensChanged(_ field: UISearchTextField) {
            let values = field.tokens.compactMap { $0.representedObject as? String }
            if values != parent.tokens {
                parent.tokens = values
            }
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            parent.isFocused = true
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            parent.isFocused = false
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            return true
        }
    }
}

#endif
