//
//  DownloadLiveActivity.swift
//  ehviewer apple
//
//  下载 Live Activity — 使用灵动岛 / 锁屏实时动态显示下载进度
//  替代传统通知方式，提供更好的用户体验
//

#if os(iOS)
import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - Activity Attributes

/// 下载实时动态的属性定义
struct DownloadActivityAttributes: ActivityAttributes {
    /// 静态数据: 画廊信息 (创建时确定，不会变化)
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

// MARK: - Live Activity Widget

/// 灵动岛 / 锁屏实时动态 UI
struct DownloadLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            // 锁屏 / StandBy 展示
            lockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                // 展开状态 — 长按灵动岛展开
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.blue)
                        .font(.title2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(Int(context.state.progress * 100))%")
                        .font(.title2.bold())
                        .foregroundStyle(.blue)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.title)
                        .font(.caption)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        ProgressView(value: context.state.progress)
                            .tint(.blue)
                        HStack {
                            Text("\(context.state.downloadedPages)/\(context.state.totalPages)")
                                .font(.caption2)
                            Spacer()
                            Text(formatSpeed(context.state.speed))
                                .font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                // 紧凑模式左侧
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
            } compactTrailing: {
                // 紧凑模式右侧
                Text("\(Int(context.state.progress * 100))%")
                    .font(.caption.bold())
                    .foregroundStyle(.blue)
            } minimal: {
                // 最小模式 (与其他 Live Activity 共存时)
                Image(systemName: "arrow.down")
                    .foregroundStyle(.blue)
            }
        }
    }

    // MARK: - 锁屏视图

    private func lockScreenView(context: ActivityViewContext<DownloadActivityAttributes>) -> some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
                Text(context.state.statusText)
                    .font(.subheadline.bold())
                Spacer()
                Text("\(Int(context.state.progress * 100))%")
                    .font(.subheadline.bold())
                    .foregroundStyle(.blue)
            }

            Text(context.attributes.title)
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            ProgressView(value: context.state.progress)
                .tint(.blue)

            HStack {
                Text("\(context.state.downloadedPages)/\(context.state.totalPages) 页")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatSpeed(context.state.speed))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    // MARK: - 格式化

    private func formatSpeed(_ bytesPerSecond: Int64) -> String {
        let kb = Double(bytesPerSecond) / 1024.0
        if kb < 1024 {
            return String(format: "%.1f KB/s", kb)
        }
        let mb = kb / 1024.0
        return String(format: "%.2f MB/s", mb)
    }
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
