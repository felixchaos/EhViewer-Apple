import Foundation
import EhModels
import EhDatabase
import EhSpider
#if canImport(UIKit)
import UIKit
#endif

// MARK: - DownloadManager (对应 Android DownloadManager.java)
// 下载队列管理 Actor

public actor DownloadManager {
    public static let shared = DownloadManager()

    // MARK: - 状态常量

    public static let stateInvalid = -1
    public static let stateNone    = 0
    public static let stateWait    = 1
    public static let stateDownload = 2
    public static let stateFinish  = 3
    public static let stateFailed  = 4

    // MARK: - 属性

    private var downloadQueue: [DownloadTask] = []
    private var activeTask: DownloadTask?
    private let maxConcurrent = 1  // 同一时间只下载一个画廊
    private var isRunning = false

    /// 下载监听器（用于通知集成）
    public weak var listener: DownloadListener?

    /// 下载目录
    public nonisolated var downloadDirectory: URL {
        // macOS: 支持用户自定义路径
        #if os(macOS)
        if let customPath = UserDefaults.standard.string(forKey: "downloadPath"),
           !customPath.isEmpty {
            return URL(fileURLWithPath: customPath)
        }
        #endif
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("download")
    }

    private init() {
        // 确保下载目录存在
        var dir = downloadDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // iOS/iPadOS: 排除 iCloud 备份
        #if os(iOS)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? dir.setResourceValues(resourceValues)
        #endif

        // 从数据库加载下载任务
        Task { await loadFromDatabase() }
    }

    /// 从数据库加载已有下载任务
    private func loadFromDatabase() {
        do {
            let records = try EhDatabase.shared.getAllDownloads()
            downloadQueue = records.map { record in
                let gallery = GalleryInfo(
                    gid: record.gid, token: record.token,
                    title: record.title, titleJpn: record.titleJpn,
                    thumb: record.thumb,
                    category: EhCategory(rawValue: record.category),
                    posted: record.posted, uploader: record.uploader,
                    rating: record.rating, pages: record.pages
                )
                return DownloadTask(gallery: gallery, label: record.label, state: record.state)
            }
            // 扫描磁盘已下载的图片文件，恢复中断下载的进度
            for i in downloadQueue.indices {
                let task = downloadQueue[i]
                if task.state == Self.stateFinish {
                    // 已完成的任务直接设置为总页数
                    downloadQueue[i].downloadedPages = task.gallery.pages
                } else if task.gallery.pages > 0 {
                    // 扫描目录中已有的图片文件数
                    let dir = galleryDirectory(gid: task.gallery.gid, title: task.gallery.bestTitle)
                    let existingPages = SpiderInfoFile.getDownloadedPages(in: dir, totalPages: task.gallery.pages)
                    downloadQueue[i].downloadedPages = existingPages.count
                }
            }
        } catch {
            print("Failed to load downloads from database: \(error)")
        }
    }

    // MARK: - 公共接口

    /// 添加下载任务 (Fix A-1: 已有 failed/none 状态时自动恢复而非静默忽略)
    public func startDownload(gallery: GalleryInfo, label: String? = nil) async {
        // 检查是否已在队列中
        if let existingIndex = downloadQueue.firstIndex(where: { $0.gallery.gid == gallery.gid }) {
            let existingState = downloadQueue[existingIndex].state
            if existingState == Self.stateNone || existingState == Self.stateFailed {
                // 已暂停或已失败 → 重置为等待并恢复
                downloadQueue[existingIndex].state = Self.stateWait
                try? EhDatabase.shared.updateDownloadState(gid: gallery.gid, state: Self.stateWait)
                if !isRunning { processQueue() }
            }
            // stateWait / stateDownload / stateFinish → 不重复操作
            return
        }

        let task = DownloadTask(gallery: gallery, label: label)
        downloadQueue.append(task)

        // 持久化到数据库
        let record = DownloadRecord(
            gid: gallery.gid, token: gallery.token,
            title: gallery.bestTitle, titleJpn: gallery.titleJpn,
            thumb: gallery.thumb, category: gallery.category.rawValue,
            posted: gallery.posted, uploader: gallery.uploader,
            rating: gallery.rating, simpleLanguage: gallery.simpleLanguage,
            pages: gallery.pages, state: Self.stateWait, date: Date()
        )
        try? EhDatabase.shared.insertDownload(record)

        // 启动队列处理
        if !isRunning {
            processQueue()
        }
    }

    /// 暂停下载
    public func pauseDownload(gid: Int64) {
        if activeTask?.gallery.gid == gid {
            if let spider = activeTask?.spider {
                Task { await spider.cancelAll() }
            }
            activeTask?.state = Self.stateNone
            activeTask = nil
            processQueue()
        }
        if let index = downloadQueue.firstIndex(where: { $0.gallery.gid == gid }) {
            downloadQueue[index].state = Self.stateNone
            try? EhDatabase.shared.updateDownloadState(gid: gid, state: Self.stateNone)
        }
    }

    /// 暂停所有下载（磁盘满时紧急调用）
    public func pauseAllDownloads() {
        // 取消当前活跃任务
        if let spider = activeTask?.spider {
            Task { await spider.cancelAll() }
        }
        activeTask = nil

        // 暂停队列中所有等待/下载中的任务
        for i in downloadQueue.indices {
            if downloadQueue[i].state == Self.stateWait || downloadQueue[i].state == Self.stateDownload {
                downloadQueue[i].state = Self.stateNone
                try? EhDatabase.shared.updateDownloadState(gid: downloadQueue[i].gallery.gid, state: Self.stateNone)
            }
        }
        print("[DownloadManager] ⚠️ 所有下载已暂停（磁盘空间不足）")
    }

    /// 恢复下载
    public func resumeDownload(gid: Int64) {
        if let index = downloadQueue.firstIndex(where: { $0.gallery.gid == gid }) {
            downloadQueue[index].state = Self.stateWait
            try? EhDatabase.shared.updateDownloadState(gid: gid, state: Self.stateWait)
            // 用 activeTask == nil 判断，避免 isRunning 残留 true 时队列卡死
            if activeTask == nil {
                isRunning = false
                processQueue()
            }
        }
    }

    /// 强制尝试处理队列 (外部调用，修复 isRunning 残留问题)
    public func kickQueue() {
        if activeTask == nil {
            isRunning = false
            processQueue()
        }
    }

    /// 删除下载 (可选删除文件)
    public func deleteDownload(gid: Int64, deleteFiles: Bool = false) {
        // 先获取 gallery 信息 (必须在 removeAll 之前)
        let task = downloadQueue.first(where: { $0.gallery.gid == gid })
        let title = task?.gallery.bestTitle
        let pages = task?.gallery.pages ?? 0

        if activeTask?.gallery.gid == gid {
            if let spider = activeTask?.spider {
                Task { await spider.cancelAll() }
            }
            activeTask = nil
        }

        downloadQueue.removeAll { $0.gallery.gid == gid }
        try? EhDatabase.shared.deleteDownload(gid: gid)

        if deleteFiles {
            // 清除 SpiderDen 阅读缓存
            if pages > 0 {
                SpiderDen.clearCache(forGid: gid, pages: pages)
            }

            if let title = title, !title.isEmpty {
                // 精确匹配: 使用实际标题
                let dir = galleryDirectory(gid: gid, title: title)
                try? FileManager.default.removeItem(at: dir)
            } else {
                // 回退: 枚举下载目录中匹配 "gid-*" 前缀的目录
                let prefix = "\(gid)-"
                if let contents = try? FileManager.default.contentsOfDirectory(
                    at: downloadDirectory, includingPropertiesForKeys: nil) {
                    for item in contents where item.lastPathComponent.hasPrefix(prefix) {
                        try? FileManager.default.removeItem(at: item)
                    }
                }
            }
        }

        processQueue()
    }

    /// 获取所有下载任务
    public func getAllTasks() -> [DownloadTask] {
        downloadQueue
    }

    /// 获取任务状态
    public func getTaskState(gid: Int64) -> Int {
        if activeTask?.gallery.gid == gid {
            return activeTask?.state ?? Self.stateNone
        }
        return downloadQueue.first(where: { $0.gallery.gid == gid })?.state ?? Self.stateInvalid
    }

    /// 更改下载标签 (对齐 Android DownloadManager.changeLabel)
    public func changeLabel(gids: [Int64], label: String?) {
        for gid in gids {
            if let index = downloadQueue.firstIndex(where: { $0.gallery.gid == gid }) {
                downloadQueue[index].label = label
                // 同步到数据库
                if var record = try? EhDatabase.shared.getDownload(gid: gid) {
                    record.label = label
                    try? EhDatabase.shared.updateDownload(record)
                }
            }
        }
    }

    /// 更新下载进度 (由 SpiderInfoUpdater 调用，同步到队列以便 UI 读取)
    public func updateDownloadedPages(gid: Int64, count: Int) {
        if let index = downloadQueue.firstIndex(where: { $0.gallery.gid == gid }) {
            downloadQueue[index].downloadedPages = count
        }
    }

    /// 更新下载速度 (由 SpiderInfoUpdater 调用，同步到队列以便 UI 读取)
    public func updateDownloadSpeed(gid: Int64, speed: Int64) {
        if let index = downloadQueue.firstIndex(where: { $0.gallery.gid == gid }) {
            downloadQueue[index].speed = speed
        }
    }

    /// 设置下载监听器
    public func setListener(_ listener: DownloadListener?) {
        self.listener = listener
    }

    // MARK: - 后台任务支持

    /// 暂停当前活跃下载 (用于后台任务过期时, 保留 stateWait 以便恢复)
    public func pauseActiveIfNeeded() {
        guard let task = activeTask else { return }
        if let spider = task.spider {
            Task { await spider.cancelAll() }
        }
        if let index = downloadQueue.firstIndex(where: { $0.gallery.gid == task.gallery.gid }) {
            downloadQueue[index].state = Self.stateWait
            try? EhDatabase.shared.updateDownloadState(gid: task.gallery.gid, state: Self.stateWait)
        }
        activeTask = nil
        isRunning = false
    }

    /// 恢复队列处理 (用于 BGProcessingTask 唤醒时)
    public func resumeAllWaiting() {
        guard !isRunning else { return }
        if downloadQueue.contains(where: { $0.state == Self.stateWait }) {
            processQueue()
        }
    }

    // MARK: - 队列处理

    private func processQueue() {
        guard activeTask == nil else { return }

        // 找到下一个等待中的任务
        guard let nextIndex = downloadQueue.firstIndex(where: { $0.state == Self.stateWait }) else {
            isRunning = false
            return
        }

        isRunning = true
        downloadQueue[nextIndex].state = Self.stateDownload
        activeTask = downloadQueue[nextIndex]

        Task {
            await executeDownload(index: nextIndex)
        }
    }

    private func executeDownload(index: Int) async {
        guard index < downloadQueue.count else { return }

        // iOS: 申请后台执行时间, 防止进入后台后 ~30 秒被系统杀死
        #if canImport(UIKit)
        let bgTaskId = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: "EhGalleryDownload") {
                Task { await DownloadManager.shared.pauseActiveIfNeeded() }
            }
        }
        #endif

        let gallery = downloadQueue[index].gallery
        let dir = galleryDirectory(gid: gallery.gid, title: gallery.bestTitle)

        // 通知监听器下载开始
        await listener?.onDownloadStart(gid: gallery.gid, title: gallery.bestTitle)

        // 尝试从 .ehviewer 文件读取已有的 SpiderInfo
        var spiderInfo: SpiderInfo
        if let existing = SpiderInfoFile.read(from: dir) {
            spiderInfo = existing
        } else {
            spiderInfo = SpiderInfo(
                startPage: 0,
                gid: gallery.gid,
                token: gallery.token,
                pages: gallery.pages
            )
            // 保存初始 .ehviewer 文件
            try? SpiderInfoFile.write(spiderInfo, to: dir)
        }

        // 创建 SpiderQueen
        let spider = SpiderQueen(galleryInfo: gallery, spiderInfo: spiderInfo, mode: .download)
        downloadQueue[index].spider = spider

        // 设置代理以便更新 .ehviewer 文件和进度通知
        // 统计已有的下载页数作为初始值
        let initialDownloaded = SpiderInfoFile.getDownloadedPages(in: dir, totalPages: gallery.pages).count
        downloadQueue[index].downloadedPages = initialDownloaded

        let updater = SpiderInfoUpdater(
            directory: dir,
            gid: gallery.gid,
            title: gallery.bestTitle,
            total: gallery.pages,
            listener: listener,
            initialDownloaded: initialDownloaded
        )
        await spider.setDelegate(updater)

        // 开始下载所有页面 (现在 startDownload() 是真正的 async，会等待全部页面完成)
        await spider.startDownload()

        // 下载完成后更新 .ehviewer 文件
        let finalInfo = await spider.getSpiderInfo()
        try? SpiderInfoFile.write(finalInfo, to: dir)

        // 统计下载结果 (对齐 Android DownloadManager.onFinished)
        var finishedCount = 0
        var failedCount = 0
        for i in 0..<gallery.pages {
            let state = await spider.getPageState(i)
            if state == SpiderQueen.stateFinish {
                finishedCount += 1
            } else if state == SpiderQueen.stateFailed {
                failedCount += 1
            }
        }

        // 下载完成
        let success = finishedCount == gallery.pages
        downloadQueue[index].state = success ? Self.stateFinish : Self.stateFailed
        downloadQueue[index].downloadedPages = finishedCount
        try? EhDatabase.shared.updateDownloadState(gid: gallery.gid, state: downloadQueue[index].state)

        // 通知监听器下载完成
        await listener?.onDownloadFinish(gid: gallery.gid, title: gallery.bestTitle, success: success)

        // iOS: 释放后台执行时间
        #if canImport(UIKit)
        await MainActor.run {
            UIApplication.shared.endBackgroundTask(bgTaskId)
        }
        #endif

        activeTask = nil
        processQueue()
    }

    // MARK: - 文件管理

    // MARK: - 路径统一 (Fix D-1, A-3: 全局唯一的目录命名算法)

    /// 文件名清理 (移除非法字符) — 公开静态方法，保证所有组件使用同一逻辑
    public nonisolated static func sanitizeFilename(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let sanitized = name.components(separatedBy: illegal).joined(separator: "_")
        let trimmed = sanitized.prefix(128)
        return String(trimmed).trimmingCharacters(in: .whitespaces)
    }

    /// 画廊目录名 — 唯一真相源 (所有路径引用必须通过此方法)
    /// 格式: `{gid}-{sanitizeFilename(title).prefix(128)}`
    public nonisolated static func galleryDirectoryName(gid: Int64, title: String) -> String {
        let sanitized = sanitizeFilename(title)
        return "\(gid)-\(sanitized)"
    }

    /// 画廊下载目录 (对应 Android: gid-sanitized_title)
    public nonisolated func galleryDirectory(gid: Int64, title: String) -> URL {
        let dirName = Self.galleryDirectoryName(gid: gid, title: title)
        return downloadDirectory.appendingPathComponent(dirName)
    }

    /// 图片文件名 (对应 Android: String.format("%08d%s", index+1, ext))
    public nonisolated func imageFilename(index: Int, ext: String = ".jpg") -> String {
        String(format: "%08d%@", index + 1, ext)
    }

    // MARK: - 下载状态真实检查 (Fix D-2, B-1)

    /// 检查画廊是否已完整下载 — 同时验证数据库状态 AND 磁盘文件存在
    public func isGalleryFullyDownloaded(gid: Int64) -> Bool {
        guard let task = downloadQueue.first(where: { $0.gallery.gid == gid }),
              task.state == Self.stateFinish else { return false }
        let dir = galleryDirectory(gid: gid, title: task.gallery.bestTitle)
        return FileManager.default.fileExists(atPath: dir.path)
    }

    /// 获取已下载画廊的目录路径 (由 ReaderViewModel 调用，替代硬编码路径)
    public func getDownloadedGalleryDirectory(gid: Int64) -> URL? {
        guard let task = downloadQueue.first(where: { $0.gallery.gid == gid }) else { return nil }
        return galleryDirectory(gid: gid, title: task.gallery.bestTitle)
    }
}

// MARK: - DownloadTask

public struct DownloadTask: Sendable {
    public let gallery: GalleryInfo
    public var label: String?
    public var state: Int
    public var downloadedPages: Int
    /// 下载速度 (字节/秒)
    public var speed: Int64
    public var spider: SpiderQueen?

    public init(gallery: GalleryInfo, label: String? = nil, state: Int = DownloadManager.stateWait) {
        self.gallery = gallery
        self.label = label
        self.state = state
        self.downloadedPages = 0
        self.speed = 0
    }
}

// MARK: - SpiderInfo 扩展 (简化构造)

extension SpiderInfo {
    init(startPage: Int, gid: Int64, token: String, pages: Int) {
        self.init()
        self.startPage = startPage
        self.gid = gid
        self.token = token
        self.pages = pages
    }
}

// MARK: - SpiderInfoUpdater (用于下载时更新 .ehviewer 文件)

actor SpiderInfoUpdater: SpiderDelegate {
    private let directory: URL
    private let gid: Int64
    private let title: String
    private let totalPages: Int
    private weak var listener: DownloadListener?

    private var downloadedCount: Int
    private var totalBytesDownloaded: Int64 = 0
    private var startTime: Date = Date()
    private var lastNotifyTime: Date = .distantPast
    private let notifyInterval: TimeInterval = 1.0 // 每秒最多通知一次

    init(directory: URL, gid: Int64, title: String, total: Int, listener: DownloadListener?, initialDownloaded: Int = 0) {
        self.directory = directory
        self.gid = gid
        self.title = title
        self.totalPages = total
        self.listener = listener
        self.downloadedCount = initialDownloaded
        self.startTime = Date()
    }

    /// 获取指定页面的实际文件大小
    private func getPageFileSize(index: Int) -> Int64 {
        let prefix = String(format: "%08d", index + 1)
        for ext in [".jpg", ".png", ".gif", ".webp"] {
            let fileURL = directory.appendingPathComponent("\(prefix)\(ext)")
            if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let size = attrs[.size] as? UInt64 {
                return Int64(size)
            }
        }
        return 0
    }

    func onPageLoaded(index: Int, imageUrl: String) async {
        downloadedCount += 1

        // 累计实际下载字节数
        let pageSize = getPageFileSize(index: index)
        totalBytesDownloaded += pageSize

        // 同步更新 DownloadManager 队列中的进度 (便于 UI 读取)
        await DownloadManager.shared.updateDownloadedPages(gid: gid, count: downloadedCount)

        // 计算真实下载速度 (字节/秒)
        let elapsed = Date().timeIntervalSince(startTime)
        let speed = elapsed > 0 ? Int64(Double(totalBytesDownloaded) / elapsed) : 0

        // 同步速度到 DownloadManager 队列 (便于 UI 读取)
        await DownloadManager.shared.updateDownloadSpeed(gid: gid, speed: speed)

        // 节流通知
        let now = Date()
        if now.timeIntervalSince(lastNotifyTime) >= notifyInterval {
            lastNotifyTime = now
            await listener?.onDownloadProgress(
                gid: gid,
                title: title,
                downloaded: downloadedCount,
                total: totalPages,
                speed: speed
            )
        }
    }

    func onPageFailed(index: Int, error: Error) async {
        print("[SpiderInfoUpdater] Page \(index) failed: \(error)")
    }

    func onImageLimitReached() async {
        print("[SpiderInfoUpdater] Image limit (509) reached")
        await listener?.on509Error()
    }

    func onDiskFull() async {
        print("[SpiderInfoUpdater] ⚠️ 磁盘空间不足，暂停所有下载")
        await DownloadManager.shared.pauseAllDownloads()
        await listener?.onDiskFull()
    }

    func onDownloadProgress(downloaded: Int, total: Int) async {
        downloadedCount = downloaded
    }
}

// MARK: - DownloadListener (下载事件监听器)

public protocol DownloadListener: AnyObject, Sendable {
    /// 下载开始
    func onDownloadStart(gid: Int64, title: String) async

    /// 下载进度更新
    func onDownloadProgress(gid: Int64, title: String, downloaded: Int, total: Int, speed: Int64) async

    /// 下载完成
    func onDownloadFinish(gid: Int64, title: String, success: Bool) async

    /// 509错误
    func on509Error() async

    /// 磁盘空间不足
    func onDiskFull() async
}
