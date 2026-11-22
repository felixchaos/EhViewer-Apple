//
//  AppDelegate.swift
//  ehviewer apple
//
//  iOS App Delegate — 处理后台下载回调
//

#if os(iOS)
import UIKit
import EhSettings

class AppDelegate: NSObject, UIApplicationDelegate {

    /// 后台下载完成回调
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // 存储完成回调，在 URLSession delegate 中调用
        BackgroundDownloadManager.shared.backgroundCompletionHandler = completionHandler
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        #if EH_OFFLINE_UI_FIXTURE && targetEnvironment(simulator)
        if EhOfflineUIFixture.enabled { return true }
        #endif
        guard !EhUnitTestHost.isOffline else { return true }
        // 注册后台任务
        BackgroundDownloadManager.shared.registerBackgroundTasks()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        #if EH_OFFLINE_UI_FIXTURE && targetEnvironment(simulator)
        if EhOfflineUIFixture.enabled { return }
        #endif
        guard !EhUnitTestHost.isOffline else { return }
        // 调度后台下载任务
        BackgroundDownloadManager.shared.scheduleBackgroundDownload()
    }

    /// 屏幕旋转控制 (对齐 Android Settings.KEY_SCREEN_ROTATION)
    /// 0=跟随系统, 1=竖屏锁定, 2=横屏锁定
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        switch AppSettings.shared.screenRotation {
        case 1:
            return .portrait
        case 2:
            return .landscape
        default:
            // 跟随系统: 允许全部方向 (iPhone 不含倒置竖屏)
            return .allButUpsideDown
        }
    }
}
#endif
