//
//  DownloadLiveActivity.swift
//  ehviewer apple
//
//  下载 Live Activity — ActivityAttributes 类型定义 + LiveActivity Manager
//  Widget UI 已移至 EhDownloadWidget 扩展目标
//

#if os(iOS)
import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - Activity Attributes

/// 下载实时动态的属性定义
/// ⚠️ 此结构体必须与 EhDownloadWidget 中的定义完全一致
struct DownloadActivityAttributes: ActivityAttributes {
    /// 动态数据: 下载状态 (实时更新)
    public struct ContentState: Codable, Hashable {
        /// 下载进度 (0.0 ~ 1.0)
        var progress: Double
        /// 已下载页数
        var downloadedPages: Int
        /// 总页数
        var totalPages: Int
        /// 下载速度 (字节/秒)
        var speed: Int64
        /// 状态文字
        var statusText: String
    }

    /// 画廊 ID
    var gid: Int64
    /// 画廊标题
    var title: String
}

// MARK: - Live Activity Manager

/// 管理下载 Live Activity 的生命周期
@MainActor
final class DownloadLiveActivityManager {
    static let shared = DownloadLiveActivityManager()

    private var currentActivity: Activity<DownloadActivityAttributes>?
    private var lastUpdateTime: Date = .distantPast
    private let updateInterval: TimeInterval = 1.0  // 每秒最多更新一次

    private init() {}

    /// 开始下载 Live Activity
    func startActivity(gid: Int64, title: String) {
        // 先结束旧的 Activity
        endActivity()

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            debugLog("[LiveActivity] Live Activities 未启用")
            return
        }

        let attributes = DownloadActivityAttributes(gid: gid, title: title)
        let initialState = DownloadActivityAttributes.ContentState(
            progress: 0,
            downloadedPages: 0,
            totalPages: 0,
            speed: 0,
            statusText: "正在下载"
        )

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: initialState, staleDate: nil),
                pushType: nil
            )
            currentActivity = activity
            debugLog("[LiveActivity] 已启动: \(activity.id)")
        } catch {
            debugLog("[LiveActivity] 启动失败: \(error)")
        }
    }

    /// 更新下载进度
    func updateProgress(gid: Int64, downloaded: Int, total: Int, speed: Int64) {
        guard let activity = currentActivity else { return }

        // 节流: 每秒最多更新一次
        let now = Date()
        guard now.timeIntervalSince(lastUpdateTime) >= updateInterval else { return }
        lastUpdateTime = now

        let progress = total > 0 ? Double(downloaded) / Double(total) : 0
        let state = DownloadActivityAttributes.ContentState(
            progress: progress,
            downloadedPages: downloaded,
            totalPages: total,
            speed: speed,
            statusText: "正在下载"
        )

        Task {
            await activity.update(.init(state: state, staleDate: nil))
        }
    }

    /// 下载完成，结束 Live Activity
    func finishActivity(success: Bool, title: String) {
        guard let activity = currentActivity else { return }

        let finalState = DownloadActivityAttributes.ContentState(
            progress: success ? 1.0 : 0,
            downloadedPages: 0,
            totalPages: 0,
            speed: 0,
            statusText: success ? "下载完成" : "下载失败"
        )

        Task {
            await activity.end(
                .init(state: finalState, staleDate: nil),
                dismissalPolicy: .after(.now + 5)  // 5 秒后自动消失
            )
            currentActivity = nil
        }
    }

    /// 强制结束 Activity
    func endActivity() {
        guard let activity = currentActivity else { return }
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
            currentActivity = nil
        }
    }
}
#endif
