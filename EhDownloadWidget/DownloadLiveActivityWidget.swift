//
//  DownloadLiveActivityWidget.swift
//  EhDownloadWidget
//
//  灵动岛 / 锁屏实时动态 UI — 显示下载进度
//  此文件在 Widget Extension 中渲染，与主 App 共享 DownloadActivityAttributes 类型定义
//

import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - Activity Attributes (与主 App 保持同步)

/// 下载实时动态的属性定义
/// ⚠️ 此结构体必须与主 App 中的 DownloadActivityAttributes 完全一致
struct DownloadActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var progress: Double
        var downloadedPages: Int
        var totalPages: Int
        var speed: Int64
        var statusText: String
    }

    var gid: Int64
    var title: String
}

// MARK: - Live Activity Widget

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
