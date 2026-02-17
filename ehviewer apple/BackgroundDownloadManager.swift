//
//  BackgroundDownloadManager.swift
//  ehviewer apple
//
//  后台下载管理器 — 使用 URLSession background configuration
//

import Foundation
import BackgroundTasks
import EhDownload

/// 后台下载管理器
/// 负责在 App 进入后台或被挂起时继续下载
final class BackgroundDownloadManager: NSObject, @unchecked Sendable {
    static let shared = BackgroundDownloadManager()

    private let downloadTaskIdentifier = "Stellatrix.ehviewer-apple.download"
    private let refreshTaskIdentifier = "Stellatrix.ehviewer-apple.refresh"

    private lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.stellatrix.ehviewer.background")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// 存储下载完成回调
    var backgroundCompletionHandler: (() -> Void)?

    /// 存储当前下载任务
    private var activeTasks: [Int: DownloadTaskInfo] = [:]
    private let tasksLock = NSLock()

    /// 防止重复注册后台任务
    private var isRegistered = false

    private override init() {
        super.init()
    }

    // MARK: - Background Task Registration

    /// 注册后台任务 (在 App 启动时调用, 仅注册一次)
    func registerBackgroundTasks() {
        guard !isRegistered else { return }
        isRegistered = true
        #if os(iOS) && !targetEnvironment(simulator)
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: downloadTaskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let processingTask = task as? BGProcessingTask else { return }
            self?.handleBackgroundDownload(task: processingTask)
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: refreshTaskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let refreshTask = task as? BGAppRefreshTask else { return }
            self?.handleBackgroundRefresh(task: refreshTask)
        }
        #endif
    }

    /// 调度后台下载任务
    func scheduleBackgroundDownload() {
        #if os(iOS) && !targetEnvironment(simulator)
        let request = BGProcessingTaskRequest(identifier: downloadTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false

        do {
            try BGTaskScheduler.shared.submit(request)
            debugLog("Background download task scheduled")
        } catch {
            debugLog("Failed to schedule background download: \(error)")
        }
        #endif
    }

    /// 调度后台刷新任务
    func scheduleBackgroundRefresh() {
        #if os(iOS) && !targetEnvironment(simulator)
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15分钟后

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            debugLog("Failed to schedule background refresh: \(error)")
        }
        #endif
    }

    // MARK: - Task Handlers

    #if os(iOS) && !targetEnvironment(simulator)
    private func handleBackgroundDownload(task: BGProcessingTask) {
        scheduleBackgroundDownload() // 重新调度下次

        task.expirationHandler = {
            // BGProcessingTask 过期时, 暂停活跃下载 (保留 stateWait 以便恢复)
            Task {
                await DownloadManager.shared.pauseActiveIfNeeded()
            }
            task.setTaskCompleted(success: false)
        }

        // 恢复下载队列中等待的任务
        Task {
            await DownloadManager.shared.resumeAllWaiting()
            // 等待当前任务完成或被系统打断
            // BGProcessingTask 最多有几分钟的执行时间
            try? await Task.sleep(for: .seconds(2))
            task.setTaskCompleted(success: true)
        }
    }

    private func handleBackgroundRefresh(task: BGAppRefreshTask) {
        scheduleBackgroundRefresh() // 重新调度

        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }

        // 检查下载状态
        Task {
            task.setTaskCompleted(success: true)
        }
    }
    #endif

    private func pauseAllDownloads() {
        backgroundSession.getAllTasks { tasks in
            tasks.forEach { $0.suspend() }
        }
    }

    // MARK: - Download Methods

    /// 开始下载图片 (后台兼容)
    func downloadImage(url: URL, to destination: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        let task = backgroundSession.downloadTask(with: url)
        let taskInfo = DownloadTaskInfo(destinationURL: destination, completion: completion)
        tasksLock.lock()
        activeTasks[task.taskIdentifier] = taskInfo
        tasksLock.unlock()
        task.resume()
    }
}

// MARK: - URLSessionDownloadDelegate

extension BackgroundDownloadManager: URLSessionDownloadDelegate {

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        tasksLock.lock()
        let taskInfo = activeTasks[downloadTask.taskIdentifier]
        tasksLock.unlock()
        guard let taskInfo else { return }

        do {
            // 如果目标文件已存在，先删除
            if FileManager.default.fileExists(atPath: taskInfo.destinationURL.path) {
                try FileManager.default.removeItem(at: taskInfo.destinationURL)
            }

            // 确保目录存在
            let dir = taskInfo.destinationURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            // 移动文件
            try FileManager.default.moveItem(at: location, to: taskInfo.destinationURL)
            taskInfo.completion(.success(taskInfo.destinationURL))
        } catch {
            taskInfo.completion(.failure(error))
        }

        tasksLock.lock()
        activeTasks.removeValue(forKey: downloadTask.taskIdentifier)
        tasksLock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        tasksLock.lock()
        let taskInfo = activeTasks[task.taskIdentifier]
        tasksLock.unlock()
        guard let error = error,
              let taskInfo else { return }

        // 保存 resume data 以支持断点续传
        if let nsError = error as NSError?,
           let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            // 存储 resume data，下次可以恢复下载
            let key = "resumeData_\(task.taskIdentifier)"
            UserDefaults.standard.set(resumeData, forKey: key)
            debugLog("[BackgroundDownload] 已保存 resume data (\(resumeData.count) bytes)，可断点续传")
        }

        taskInfo.completion(.failure(error))
        tasksLock.lock()
        activeTasks.removeValue(forKey: task.taskIdentifier)
        tasksLock.unlock()
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // 后台下载完成，通知系统
        DispatchQueue.main.async { [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
        }
    }
}

// MARK: - Download Task Info

private struct DownloadTaskInfo {
    let destinationURL: URL
    let completion: (Result<URL, Error>) -> Void
}
