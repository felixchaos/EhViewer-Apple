//
//  DownloadNotificationService.swift
//  ehviewer apple
//
//  下载通知服务 — 对应 Android DownloadService 的通知功能
//  使用 UserNotifications 框架显示下载进度、完成和错误通知
//

import Foundation
import UserNotifications
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// 下载通知服务
/// 管理下载过程中的所有通知（进度、完成、509错误等）
@MainActor
final class DownloadNotificationService: NSObject, @unchecked Sendable {
    static let shared = DownloadNotificationService()

    // MARK: - 通知标识符（对应 Android ID_DOWNLOADING 等）

    private let downloadingNotificationId = "ehviewer.downloading"
    private let downloadedNotificationId = "ehviewer.downloaded"
    private let error509NotificationId = "ehviewer.509"
    private let notificationCategoryId = "ehviewer.download"

    // MARK: - 状态追踪

    /// 已完成的下载记录（对应 Android sItemStateArray）
    private var completedItems: [(gid: Int64, title: String, success: Bool)] = []
    private var finishedCount = 0
    private var failedCount = 0

    /// 当前正在下载的任务信息
    private var currentDownloadInfo: DownloadingInfo?

    /// 通知节流（对应 Android DELAY = 1s）
    private var lastNotificationTime: Date = .distantPast
    private let notificationDelay: TimeInterval = 1.0

    // MARK: - 初始化

    private override init() {
        super.init()
        setupNotificationCategories()
    }

    // MARK: - 设置通知分类和操作

    private func setupNotificationCategories() {
        let center = UNUserNotificationCenter.current()

        // 停止所有下载的操作
        let stopAllAction = UNNotificationAction(
            identifier: "STOP_ALL",
            title: "停止全部",
            options: [.destructive]
        )

        // 清除通知的操作
        let clearAction = UNNotificationAction(
            identifier: "CLEAR",
            title: "清除",
            options: []
        )

        // 下载中分类
        let downloadingCategory = UNNotificationCategory(
            identifier: "DOWNLOADING",
            actions: [stopAllAction],
            intentIdentifiers: [],
            options: []
        )

        // 下载完成分类
        let downloadedCategory = UNNotificationCategory(
            identifier: "DOWNLOADED",
            actions: [clearAction],
            intentIdentifiers: [],
            options: []
        )

        // 509错误分类
        let error509Category = UNNotificationCategory(
            identifier: "ERROR_509",
            actions: [],
            intentIdentifiers: [],
            options: []
        )

        center.setNotificationCategories([downloadingCategory, downloadedCategory, error509Category])
    }

    // MARK: - 请求通知权限

    func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            return granted
        } catch {
            print("[DownloadNotification] Authorization error: \(error)")
            return false
        }
    }

    // MARK: - 下载开始通知（对应 Android onStart）

    func onDownloadStart(gid: Int64, title: String) {
        currentDownloadInfo = DownloadingInfo(
            gid: gid,
            title: title,
            downloaded: 0,
            total: 0,
            speed: 0
        )

        let content = UNMutableNotificationContent()
        content.title = "正在下载"
        content.body = title
        content.categoryIdentifier = "DOWNLOADING"
        content.sound = nil // 静默

        // 添加用户信息以便点击跳转
        content.userInfo = ["gid": gid]

        sendNotificationThrottled(id: downloadingNotificationId, content: content)
    }

    // MARK: - 下载进度更新（对应 Android onDownload/onGetPage）

    func onDownloadProgress(gid: Int64, title: String, downloaded: Int, total: Int, speed: Int64) {
        currentDownloadInfo = DownloadingInfo(
            gid: gid,
            title: title,
            downloaded: downloaded,
            total: total,
            speed: speed
        )

        let content = UNMutableNotificationContent()
        content.title = title
        content.categoryIdentifier = "DOWNLOADING"
        content.sound = nil

        // 格式化进度信息
        let speedText = formatSpeed(speed)
        if total > 0 {
            let progress = downloaded * 100 / total
            content.body = "\(downloaded)/\(total) (\(progress)%) - \(speedText)"
            content.subtitle = "\(progress)% 完成"
        } else {
            content.body = "\(downloaded) 页 - \(speedText)"
        }

        content.userInfo = ["gid": gid]

        sendNotificationThrottled(id: downloadingNotificationId, content: content)
    }

    // MARK: - 下载完成通知（对应 Android onFinish）

    func onDownloadFinish(gid: Int64, title: String, success: Bool) {
        // 移除下载中通知
        removeNotification(id: downloadingNotificationId)
        currentDownloadInfo = nil

        // 记录完成状态
        completedItems.append((gid: gid, title: title, success: success))
        if success {
            finishedCount += 1
        } else {
            failedCount += 1
        }

        // 构建完成通知
        let content = UNMutableNotificationContent()
        content.categoryIdentifier = "DOWNLOADED"
        content.sound = .default

        if completedItems.count == 1 {
            // 单个下载完成
            content.title = success ? "下载完成" : "下载失败"
            content.body = title
        } else {
            // 多个下载完成
            content.title = "下载完成"
            if finishedCount > 0 && failedCount > 0 {
                content.body = "\(finishedCount) 个成功，\(failedCount) 个失败"
            } else if finishedCount > 0 {
                content.body = "\(finishedCount) 个画廊下载完成"
            } else {
                content.body = "\(failedCount) 个画廊下载失败"
            }

            // 使用收件箱样式显示列表
            var summaryText = ""
            for (_, itemTitle, itemSuccess) in completedItems.suffix(5) {
                let status = itemSuccess ? "✓" : "✗"
                summaryText += "\(status) \(itemTitle)\n"
            }
            if completedItems.count > 5 {
                summaryText += "... 还有 \(completedItems.count - 5) 个"
            }
            content.subtitle = summaryText.trimmingCharacters(in: .newlines)
        }

        content.userInfo = ["action": "open_downloads"]

        sendNotificationImmediate(id: downloadedNotificationId, content: content)
    }

    // MARK: - 509错误通知（对应 Android onGet509）

    func on509Error() {
        let content = UNMutableNotificationContent()
        content.title = "下载限制"
        content.body = "已达到图片浏览限制 (509)，请稍后再试或获取更多配额"
        content.categoryIdentifier = "ERROR_509"
        content.sound = .default

        sendNotificationImmediate(id: error509NotificationId, content: content)
    }

    // MARK: - 下载取消

    func onDownloadCancel() {
        removeNotification(id: downloadingNotificationId)
        currentDownloadInfo = nil
    }

    // MARK: - 清除完成计数（对应 Android clear）

    func clearCompletedItems() {
        completedItems.removeAll()
        finishedCount = 0
        failedCount = 0
        removeNotification(id: downloadedNotificationId)
    }

    // MARK: - 内部方法

    private func sendNotificationThrottled(id: String, content: UNMutableNotificationContent) {
        let now = Date()
        guard now.timeIntervalSince(lastNotificationTime) >= notificationDelay else {
            return // 节流
        }
        lastNotificationTime = now

        sendNotificationImmediate(id: id, content: content)
    }

    private func sendNotificationImmediate(id: String, content: UNMutableNotificationContent) {
        let request = UNNotificationRequest(
            identifier: id,
            content: content,
            trigger: nil // 立即发送
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[DownloadNotification] Failed to send: \(error)")
            }
        }
    }

    /// 发送简单的本地通知（公开方法，供磁盘满等系统级告警使用）
    func sendLocalNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        sendNotificationImmediate(id: "system_alert_\(Date().timeIntervalSince1970)", content: content)
    }

    private func removeNotification(id: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
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

// MARK: - UNUserNotificationCenterDelegate

extension DownloadNotificationService: UNUserNotificationCenterDelegate {

    /// 前台显示通知
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // 在前台也显示通知横幅
        return [.banner, .list]
    }

    /// 用户点击通知
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo

        switch response.actionIdentifier {
        case "STOP_ALL":
            // 停止所有下载
            NotificationCenter.default.post(name: .stopAllDownloads, object: nil)

        case "CLEAR":
            // 清除完成记录
            clearCompletedItems()

        case UNNotificationDefaultActionIdentifier:
            // 用户点击通知本身
            if let gid = userInfo["gid"] as? Int64 {
                // 打开对应的下载详情
                NotificationCenter.default.post(
                    name: .openDownloadDetail,
                    object: nil,
                    userInfo: ["gid": gid]
                )
            } else if userInfo["action"] as? String == "open_downloads" {
                // 打开下载列表
                NotificationCenter.default.post(name: .openDownloads, object: nil)
            }

        default:
            break
        }
    }
}

// MARK: - 通知名称

extension Notification.Name {
    static let stopAllDownloads = Notification.Name("stopAllDownloads")
    static let openDownloadDetail = Notification.Name("openDownloadDetail")
    static let openDownloads = Notification.Name("openDownloads")
}

// MARK: - 下载中信息

private struct DownloadingInfo {
    let gid: Int64
    let title: String
    let downloaded: Int
    let total: Int
    let speed: Int64
}
