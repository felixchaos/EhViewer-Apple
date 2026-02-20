//
//  DownloadNotificationBridge.swift
//  ehviewer apple
//
//  桥接 DownloadManager 和 Live Activity / 通知服务
//  下载中使用灵动岛 Live Activity，完成后使用传统通知
//

import Foundation
import EhDownload
import EhSettings

/// 桥接 DownloadManager 的监听器到 Live Activity + 通知
final class DownloadNotificationBridge: DownloadListener, @unchecked Sendable {
    static let shared = DownloadNotificationBridge()

    private init() {}

    // MARK: - DownloadListener

    func onDownloadStart(gid: Int64, title: String) async {
        await MainActor.run {
            #if os(iOS)
            // 启动灵动岛 Live Activity (替代传统通知)
            if AppSettings.shared.showLiveActivity {
                DownloadLiveActivityManager.shared.startActivity(gid: gid, title: title)
            }
            #else
            DownloadNotificationService.shared.onDownloadStart(gid: gid, title: title)
            #endif
        }
    }

    func onDownloadProgress(gid: Int64, title: String, downloaded: Int, total: Int, speed: Int64) async {
        await MainActor.run {
            #if os(iOS)
            // 更新灵动岛进度 (替代传统通知轮询)
            if AppSettings.shared.showLiveActivity {
                DownloadLiveActivityManager.shared.updateProgress(
                    gid: gid,
                    downloaded: downloaded,
                    total: total,
                    speed: speed
                )
            }
            #else
            DownloadNotificationService.shared.onDownloadProgress(
                gid: gid,
                title: title,
                downloaded: downloaded,
                total: total,
                speed: speed
            )
            #endif
        }
    }

    func onDownloadFinish(gid: Int64, title: String, success: Bool) async {
        await MainActor.run {
            #if os(iOS)
            // 结束灵动岛 Live Activity
            if AppSettings.shared.showLiveActivity {
                DownloadLiveActivityManager.shared.finishActivity(success: success, title: title)
            }
            #endif
            // 完成通知仍使用传统通知 (在通知中心保留记录)
            DownloadNotificationService.shared.onDownloadFinish(gid: gid, title: title, success: success)
        }
    }

    func on509Error() async {
        await MainActor.run {
            #if os(iOS)
            DownloadLiveActivityManager.shared.endActivity()
            #endif
            DownloadNotificationService.shared.on509Error()
        }
    }

    func onDiskFull() async {
        await MainActor.run {
            #if os(iOS)
            DownloadLiveActivityManager.shared.endActivity()
            #endif
            // 发送磁盘满通知，让 UI 层弹窗提示用户
            NotificationCenter.default.post(name: .ehDiskFull, object: nil)
            DownloadNotificationService.shared.sendLocalNotification(
                title: "下载已暂停",
                body: "磁盘空间不足，所有下载已自动暂停。请释放存储空间后手动恢复下载。"
            )
        }
    }
}
