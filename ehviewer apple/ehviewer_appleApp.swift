//
//  ehviewer_appleApp.swift
//  ehviewer apple
//
//  EhViewer for Apple platforms — E-Hentai/ExHentai gallery browser
//

import SwiftUI
import UserNotifications
import EhDownload
import EhSpider
import EhSettings
import EhDatabase
#if os(iOS)
import UIKit
#endif

@main
struct EhViewerApp: App {
    // ⚠️ 不在 App 层创建 AppState — 由 RootView 独占管理
    // 避免多个 @Observable 实例触发 App 重渲染

    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    init() {
        // 配置全局 URLCache (对标 Android Conaco 320MB 磁盘缓存)
        // AsyncImage 和所有使用 URLSession.shared 的代码都会受益
        URLCache.shared = URLCache(
            memoryCapacity: 20 * 1024 * 1024,     // 20MB 内存
            diskCapacity: 320 * 1024 * 1024,       // 320MB 磁盘
            directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("url_cache")
        )

        // 初始化 SpiderDen 图片缓存
        SpiderDen.initialize()

        // 数据库维护: 每 7 天自动 VACUUM + WAL checkpoint (V-05 修复)
        // ⚠️ 关键修复: 延迟 10 秒再执行维护，避免 VACUUM 持有 DatabaseQueue 串行锁
        // 阻塞主线程的数据库读取 (ContinueReadingCard 等)，导致白屏 + 闪退
        Task.detached(priority: .background) {
            try? await Task.sleep(for: .seconds(10))
            EhDatabase.shared.performMaintenanceIfNeeded()
        }

        // 注意: 后台任务注册由 AppDelegate.didFinishLaunchingWithOptions 负责
        // 不要在此处重复调用, BGTaskScheduler 对同一 identifier 注册两次会崩溃

        // 设置通知代理
        UNUserNotificationCenter.current().delegate = DownloadNotificationService.shared

        // 请求通知权限并设置下载监听器
        Task { @MainActor in
            _ = await DownloadNotificationService.shared.requestAuthorization()

            // 注册下载通知桥接器
            await DownloadManager.shared.setListener(DownloadNotificationBridge.shared)
        }
        
        // 标签数据库自动更新 (对齐 Android MainActivity.onCreate -> EhTagDatabase.update(this))
        Task.detached(priority: .background) {
            do {
                try await EhTagDatabase.shared.updateDatabase(forceUpdate: false)
                await MainActor.run { debugLog("[EhTagDatabase] Auto-update check completed") }
            } catch {
                await MainActor.run { debugLog("[EhTagDatabase] Auto-update failed: \(error)") }
            }
        }
    }

    var body: some Scene {
        let _ = NSLog("[RENDER] EhViewerApp body — 如果此行反复出现，说明 App 级重渲染")
        WindowGroup {
            RootView()
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 750)
        .commands {
            SidebarCommands()

            // 自定义菜单
            CommandGroup(replacing: .newItem) {
                Button("新建窗口") {
                    if let url = URL(string: "ehviewer://new-window") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            CommandMenu("浏览") {
                Button("首页") {
                    NotificationCenter.default.post(name: .navigateToHome, object: nil)
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("热门") {
                    NotificationCenter.default.post(name: .navigateToPopular, object: nil)
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("排行榜") {
                    NotificationCenter.default.post(name: .navigateToTopList, object: nil)
                }
                .keyboardShortcut("3", modifiers: .command)

                Button("收藏") {
                    NotificationCenter.default.post(name: .navigateToFavorites, object: nil)
                }
                .keyboardShortcut("4", modifiers: .command)

                Divider()

                Button("刷新") {
                    NotificationCenter.default.post(name: .refresh, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)

                Divider()

                Button("搜索") {
                    NotificationCenter.default.post(name: .focusSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }

            CommandMenu("画廊") {
                Button("下载") {
                    NotificationCenter.default.post(name: .downloadGallery, object: nil)
                }
                .keyboardShortcut("s", modifiers: .command)

                Button("收藏") {
                    NotificationCenter.default.post(name: .favoriteGallery, object: nil)
                }
                .keyboardShortcut("d", modifiers: .command)
            }

            CommandMenu("阅读") {
                Button("上一页") {
                    NotificationCenter.default.post(name: .previousPage, object: nil)
                }
                .keyboardShortcut(.leftArrow, modifiers: [])

                Button("下一页") {
                    NotificationCenter.default.post(name: .nextPage, object: nil)
                }
                .keyboardShortcut(.rightArrow, modifiers: [])

                Button("下一页 (空格)") {
                    NotificationCenter.default.post(name: .nextPage, object: nil)
                }
                .keyboardShortcut(.space, modifiers: [])

                Divider()

                Button("退出阅读") {
                    NotificationCenter.default.post(name: .exitReader, object: nil)
                }
                .keyboardShortcut(.escape, modifiers: [])

                Divider()

                Button("全屏") {
                    NotificationCenter.default.post(name: .toggleFullscreen, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .control])
            }
        }
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .frame(minWidth: 400, minHeight: 300)
        }
        #endif
    }
}

// MARK: - Navigation Notifications

extension Notification.Name {
    static let navigateToHome = Notification.Name("navigateToHome")
    static let navigateToPopular = Notification.Name("navigateToPopular")
    static let navigateToTopList = Notification.Name("navigateToTopList")
    static let navigateToFavorites = Notification.Name("navigateToFavorites")
    static let refresh = Notification.Name("refresh")
    static let focusSearch = Notification.Name("focusSearch")
    static let downloadGallery = Notification.Name("downloadGallery")
    static let favoriteGallery = Notification.Name("favoriteGallery")
    static let previousPage = Notification.Name("previousPage")
    static let nextPage = Notification.Name("nextPage")
    static let exitReader = Notification.Name("exitReader")
    static let toggleFullscreen = Notification.Name("toggleFullscreen")
    static let openGalleryFromClipboard = Notification.Name("openGalleryFromClipboard")
    /// 标签搜索 (对齐 Android: onTagClick → mUrlBuilder.set(tag) → mHelper.refresh())
    static let tagSearchRequested = Notification.Name("tagSearchRequested")
    /// 磁盘空间不足，所有下载已暂停
    static let ehDiskFull = Notification.Name("ehDiskFull")
    /// 全局错误展示 (GlobalErrorBoundary 监听)
    static let ehGlobalError = Notification.Name("ehGlobalError")
}
