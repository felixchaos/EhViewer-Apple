//
//  AppErrorHandling.swift
//  ehviewer apple
//
//  全局错误边界 — ViewModifier 方式包裹根视图
//  确保未捕获的异步错误弹出友好弹窗，而非 App 消失
//

import SwiftUI

// MARK: - 应用级错误类型

/// App 级别的可展示错误
struct AppError: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let underlyingError: Error?

    init(_ title: String, message: String, error: Error? = nil) {
        self.title = title
        self.message = message
        self.underlyingError = error
    }

    /// 从任意 Error 构造用户友好的 AppError
    static func from(_ error: Error) -> AppError {
        // 网络错误
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                return AppError("网络不可用", message: "请检查网络连接后重试。")
            case .timedOut:
                return AppError("请求超时", message: "服务器响应过慢，请稍后重试。")
            case .cancelled:
                return AppError("请求已取消", message: "操作已被取消。")
            default:
                return AppError("网络错误", message: urlError.localizedDescription, error: error)
            }
        }

        // 解码错误
        if error is DecodingError {
            return AppError("数据解析失败", message: "服务器返回了意外的数据格式。", error: error)
        }

        // 通用错误
        return AppError("发生错误", message: error.localizedDescription, error: error)
    }
}

// MARK: - 全局错误环境

/// 全局错误处理 Observable 对象
/// 审计修复 C-4: 使用 @MainActor 替代 DispatchQueue.main.async，统一并发范式
@MainActor
@Observable
final class ErrorHandler {
    static let shared = ErrorHandler()

    /// 当前待展示的错误 (触发 alert)
    var currentError: AppError?

    /// 处理错误: 记录日志 + 通知展示
    func handle(_ error: Error, context: String = "Unknown") {
        let appError = AppError.from(error)

        // 写入日志
        LogManager.shared.error(
            "\(context): \(error.localizedDescription)",
            category: "ErrorHandler"
        )

        currentError = appError
        // 通过 Notification 通知 GlobalErrorBoundary 展示错误
        // 避免 @Observable 观察链导致渲染循环
        NotificationCenter.default.post(name: .ehGlobalError, object: appError)
    }

    /// 静默处理 (仅记日志, 不弹窗)
    func handleSilently(_ error: Error, context: String = "Unknown") {
        LogManager.shared.warning(
            "\(context): \(error.localizedDescription)",
            category: "ErrorHandler"
        )
    }
}

// MARK: - ViewModifier

/// 全局错误边界修饰符
/// 用法: `.modifier(GlobalErrorBoundary())`
struct GlobalErrorBoundary: ViewModifier {
    // ⚠️ 不用 @State 包裹 @Observable 单例 — 会导致幽灵重渲染循环
    // 直接在 body 内引用 ErrorHandler.shared
    @State private var showError = false
    @State private var capturedError: AppError?

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .ehGlobalError)) { notification in
                if let error = notification.object as? AppError {
                    capturedError = error
                    showError = true
                }
            }
            .alert(
                capturedError?.title ?? "错误",
                isPresented: $showError
            ) {
                Button("确定", role: .cancel) {
                    capturedError = nil
                }
                // 提供"复制详情"按钮, 方便用户反馈
                if let detail = capturedError?.underlyingError {
                    Button("复制错误详情") {
                        let text = String(describing: detail)
                        #if os(iOS)
                        UIPasteboard.general.string = text
                        #elseif os(macOS)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        #endif
                        capturedError = nil
                    }
                }
            } message: {
                if let msg = capturedError?.message {
                    Text(msg)
                }
            }
    }
}

// MARK: - View Extension

extension View {
    /// 添加全局错误边界
    func withGlobalErrorBoundary() -> some View {
        self.modifier(GlobalErrorBoundary())
    }
}
