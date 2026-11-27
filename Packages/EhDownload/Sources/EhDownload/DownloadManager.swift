import Foundation
import EhModels
import EhDatabase
import EhSpider
import EhSettings
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

    /// 下载队列
    /// ⚠️ lazy: 首次访问时同步从数据库加载。
    ///   以前是 init 里 `Task { await loadFromDatabase() }` —— Actor 不保证 Task 之间的
    ///   执行顺序，App 启动后立刻打开已下载画廊时队列可能还是空的，
    ///   于是被判定为"未下载"、整本走网络 (issue #8 问题二)
    private lazy var downloadQueue = Self.tasksFromDatabase(
        database: database, downloadDirectory: downloadDirectory
    )

    fileprivate struct Attempt: Equatable, Sendable {
        let gid: Int64
        let batchID: UUID
        private let identity: UUID

        init(gid: Int64, batchID: UUID) {
            self.gid = gid
            self.batchID = batchID
            self.identity = UUID()
        }
    }

    private struct FileDeletion {
        let gid: Int64
        let title: String?
        let pages: Int
        let confirmedDirectory: URL?
    }

    private var activeAttempt: Attempt?
    private var notificationBatchID: UUID?
    // A retired attempt no longer accepts updates, but keeps the transfer
    // slot until its structured children finish touching the download files.
    private var runner: (attempt: Attempt, task: Task<Void, Never>)?
    private var startQueueAfterDrain = false
    private var recoverForegroundAfterDrain = false
    private var pendingFileDeletion: FileDeletion?
    private let database: EhDatabase
    private nonisolated let directoryOverride: URL?
    private let isApplicationActive: @MainActor @Sendable () -> Bool
    private let makeTransfer: (@Sendable (GalleryInfo, SpiderInfo, DownloadQuality?) -> any DownloadTransfer)?

    /// 下载监听器（用于通知集成）
    public weak var listener: DownloadListener?

    /// 下载目录
    public nonisolated var downloadDirectory: URL {
        if let directoryOverride { return directoryOverride }
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

    /// Capture the physical destination when offering a completed-download deletion.
    public nonisolated var finishedDeletionRoot: URL {
        downloadDirectory.standardizedFileURL.resolvingSymlinksInPath()
    }

    init(
        database: EhDatabase = .shared,
        directory: URL? = nil,
        isApplicationActive: @escaping @MainActor @Sendable () -> Bool = {
            #if os(iOS)
            UIApplication.shared.applicationState == .active
            #else
            false
            #endif
        },
        makeTransfer: (@Sendable (GalleryInfo, SpiderInfo, DownloadQuality?) -> any DownloadTransfer)? = nil
    ) {
        self.database = database
        self.directoryOverride = directory
        self.makeTransfer = makeTransfer
        self.isApplicationActive = isApplicationActive
        // 确保下载目录存在
        var dir = downloadDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // iOS/iPadOS: 排除 iCloud 备份
        #if os(iOS)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? dir.setResourceValues(resourceValues)
        #endif
    }

    /// 从数据库加载已有下载任务 (nonisolated static: 供 lazy 属性同步初始化)
    private nonisolated static func tasksFromDatabase(database: EhDatabase, downloadDirectory: URL) -> [DownloadTask] {
        do {
            let records = try database.getAllDownloads()
            return records.map { record in
                var task = DownloadTaskPersistence.restore(record) { gallery in
                    let dir = downloadDirectory.appendingPathComponent(
                        Self.galleryDirectoryName(gid: gallery.gid, title: gallery.bestTitle)
                    )
                    if let quality = record.quality.flatMap(DownloadQuality.init(rawValue:)),
                       DownloadFolderQuality.recorded(in: dir) != quality { return 0 }
                    return SpiderInfoFile.getDownloadedPages(in: dir, totalPages: gallery.pages).count
                }
                if record.state == Self.stateFinish, let quality = task.quality {
                    let dir = downloadDirectory.appendingPathComponent(
                        Self.galleryDirectoryName(gid: task.gallery.gid, title: task.gallery.bestTitle)
                    )
                    if DownloadFolderQuality.recorded(in: dir) != quality { task.downloadedPages = 0 }
                }
                return task
            }
        } catch {
            print("Failed to load downloads from database: \(error)")
            return []
        }
    }

    // MARK: - 公共接口

    /// Imports a flat image folder as a completed, offline-only gallery.
    /// Copying occurs outside the queue actor; registration is synchronous and serialized.
    public func importImageFolder(_ folder: URL) async throws -> GalleryInfo {
        try await importOfflineGallery { try OfflineGalleryFolderImport.stage(folder: folder, under: $0) }
    }

    public func importImageArchive(_ archive: URL) async throws -> GalleryInfo {
        try await importOfflineGallery { try OfflineGalleryFolderImport.stage(archive: archive, under: $0) }
    }

    private func importOfflineGallery(
        stage: @escaping @Sendable (URL) throws -> OfflineGalleryFolderImport.Stage
    ) async throws -> GalleryInfo {
        guard !database.isDegraded else { throw OfflineGalleryImportError.unavailable }
        let root = finishedDeletionRoot
        let worker = Task.detached(priority: .userInitiated) { try stage(root) }
        let staged = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        defer { try? FileManager.default.removeItem(at: staged.directory) }
        try Task.checkCancellation()
        guard staged.root == finishedDeletionRoot else { throw OfflineGalleryImportError.unavailable }

        let fm = FileManager.default
        var galleryID: Int64?
        for _ in 0..<4 {
            let gid = Int64.random(in: (Int64.min + 1)...(-1))
            guard try database.getDownload(gid: gid) == nil,
                  !downloadQueue.contains(where: { $0.gallery.gid == gid }),
                  !fm.fileExists(atPath: staged.root.appendingPathComponent(
                    Self.galleryDirectoryName(gid: gid, title: staged.title)
                  ).path) else { continue }
            galleryID = gid
            break
        }
        guard let galleryID else { throw OfflineGalleryImportError.failed }

        let gallery = GalleryInfo(gid: galleryID, token: OfflineGallery.token,
                                  title: staged.title, pages: staged.pages)
        let target = staged.root.appendingPathComponent(
            Self.galleryDirectoryName(gid: gallery.gid, title: gallery.bestTitle), isDirectory: true
        )
        var task = DownloadTask(gallery: gallery, label: nil, state: Self.stateFinish)
        task.downloadedPages = staged.pages
        try SpiderInfoFile.write(SpiderInfo(gid: gallery.gid, token: gallery.token, pages: gallery.pages),
                                 to: staged.directory)
        // Same-volume move publishes a complete folder. It does not replace an existing destination.
        try fm.moveItem(at: staged.directory, to: target)
        do {
            try database.insertDownload(DownloadTaskPersistence.record(for: task))
        } catch {
            try? fm.removeItem(at: target)
            throw error
        }
        downloadQueue.insert(task, at: 0)
        return gallery
    }

    /// Re-registers an imported copy after the user retained its files.
    public func restoreOfflineGallery(_ info: SpiderInfo, from directory: URL) throws -> Bool {
        guard !database.isDegraded else { throw OfflineGalleryImportError.unavailable }
        let parent = directory.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        guard parent.path == finishedDeletionRoot.path, OfflineGallery.canRestore(info, from: directory),
              try database.getDownload(gid: info.gid) == nil,
              !downloadQueue.contains(where: { $0.gallery.gid == info.gid })
        else { return false }
        let title = String(directory.lastPathComponent.dropFirst("\(info.gid)-".count))
        guard !title.isEmpty, directory.lastPathComponent == Self.galleryDirectoryName(gid: info.gid, title: title)
        else { return false }
        let gallery = GalleryInfo(gid: info.gid, token: info.token, title: title, pages: info.pages)
        var task = DownloadTask(gallery: gallery, label: nil, state: Self.stateFinish)
        task.downloadedPages = info.pages
        try database.insertDownload(DownloadTaskPersistence.record(for: task))
        downloadQueue.insert(task, at: 0)
        return true
    }

    /// Re-register kept files without assigning an unverified download policy.
    public func restoreRetainedDownload(_ info: SpiderInfo, from directory: URL) throws -> Bool {
        guard !database.isDegraded else { throw OfflineGalleryImportError.unavailable }
        let parent = directory.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let prefix = "\(info.gid)-"
        guard parent.path == finishedDeletionRoot.path, info.gid > 0, !info.token.isEmpty, info.pages > 0,
              directory.lastPathComponent.hasPrefix(prefix),
              runner?.attempt.gid != info.gid,
              try database.getDownload(gid: info.gid) == nil,
              !downloadQueue.contains(where: { $0.gallery.gid == info.gid }) else { return false }
        let title = String(directory.lastPathComponent.dropFirst(prefix.count))
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              directory.lastPathComponent == Self.galleryDirectoryName(gid: info.gid, title: title) else { return false }
        let gallery = GalleryInfo(gid: info.gid, token: info.token, title: title, pages: info.pages)
        let pages = SpiderInfoFile.getDownloadedPages(in: directory, totalPages: info.pages).count
        var task = DownloadTask(gallery: gallery, state: pages == info.pages ? Self.stateFinish : Self.stateNone,
                                quality: DownloadFolderQuality.recorded(in: directory))
        task.downloadedPages = pages
        try database.insertDownload(DownloadTaskPersistence.record(for: task))
        downloadQueue.insert(task, at: 0)
        return true
    }

    public enum StartOutcome: Equatable, Sendable {
        case enqueued, resumed
        case alreadyWaiting, alreadyDownloading, alreadyFinished
        case offlineImport, retainedFiles, unavailable
    }

    /// Non-mutating preflight for the download setup page. The queue repeats
    /// the same check at submission, and the runner checks again before IO.
    public func retainedDownloadConflicts(galleries: [GalleryInfo], quality: DownloadQuality) -> [GalleryInfo] {
        let existing = Set(downloadQueue.map { $0.gallery.gid })
        var seen = Set<Int64>()
        return galleries.filter { gallery in
            guard seen.insert(gallery.gid).inserted,
                  !OfflineGallery.isImported(gid: gallery.gid, token: gallery.token),
                  !existing.contains(gallery.gid) else { return false }
            return (try? retainedDownloadConflicts(with: gallery, quality: quality)) == true
        }
    }

    private func retainedDownloadConflicts(with gallery: GalleryInfo, quality: DownloadQuality) throws -> Bool {
        if pendingFileDeletion?.gid == gallery.gid { return false }
        let directory = galleryDirectory(gid: gallery.gid, title: gallery.bestTitle)
        // A retired transfer can still finish writing. Use only the same
        // proven policy until that runner has drained.
        if runner?.attempt.gid == gallery.gid,
           DownloadFolderQuality.recorded(in: directory) != quality { return true }
        return try !DownloadFolderQuality.canUse(directory, quality: quality)
    }

    /// Classify and apply the request under one actor turn. An existing
    /// transfer retains its label, progress and files.
    @discardableResult
    public func startDownload(gallery: GalleryInfo, label: String? = nil, quality: DownloadQuality? = nil) async -> StartOutcome {
        guard !OfflineGallery.isImported(gid: gallery.gid, token: gallery.token) else {
            return .offlineImport
        }
        if let index = downloadQueue.firstIndex(where: { $0.gallery.gid == gallery.gid }) {
            let task = downloadQueue[index]
            guard !OfflineGallery.isImported(gid: task.gallery.gid, token: task.gallery.token) else {
                return .offlineImport
            }
            switch task.state {
            case Self.stateNone, Self.stateFailed: return resumeDownload(at: index) ? .resumed : .unavailable
            case Self.stateWait: return .alreadyWaiting
            case Self.stateDownload: return .alreadyDownloading
            case Self.stateFinish: return .alreadyFinished
            default: return .unavailable
            }
        }

        let selected = quality ?? AppSettings.shared.defaultDownloadQuality
        let task = DownloadTask(gallery: gallery, label: label, quality: selected)
        do {
            if try retainedDownloadConflicts(with: gallery, quality: selected) { return .retainedFiles }
            try database.insertDownload(DownloadTaskPersistence.record(for: task))
        } catch {
            return .unavailable
        }
        downloadQueue.append(task)
        processQueue()
        return .enqueued
    }

    /// 暂停下载
    public func pauseDownload(gid: Int64) {
        guard let index = downloadQueue.firstIndex(where: { $0.gallery.gid == gid }),
              downloadQueue[index].canPause else { return }
        let wasActive = activeAttempt?.gid == gid
        if wasActive { retireActiveAttempt() }
        downloadQueue[index].state = Self.stateNone
        downloadQueue[index].spider = nil
        try? database.updateDownloadState(gid: gid, state: Self.stateNone)
        _ = closeNotificationBatchIfIdle()
        if wasActive { processQueue() }
    }

    /// 暂停所有下载（磁盘满时紧急调用）
    public func pauseAllDownloads() {
        retireActiveAttempt()
        startQueueAfterDrain = false
        recoverForegroundAfterDrain = false

        // 暂停队列中所有等待/下载中的任务
        for i in downloadQueue.indices {
            if downloadQueue[i].canPause {
                downloadQueue[i].state = Self.stateNone
                downloadQueue[i].spider = nil
                try? database.updateDownloadState(gid: downloadQueue[i].gallery.gid, state: Self.stateNone)
            }
        }
        notificationBatchID = nil
        print("[DownloadManager] ⚠️ 所有下载已暂停（磁盘空间不足）")
    }

    /// 恢复下载
    public func resumeDownload(gid: Int64) {
        guard let index = downloadQueue.firstIndex(where: { $0.gallery.gid == gid }) else { return }
        resumeDownload(at: index)
    }

    @discardableResult
    private func resumeDownload(at index: Int) -> Bool {
        guard downloadQueue[index].canResume else { return false }
        let gid = downloadQueue[index].gallery.gid
        do {
            try database.updateDownloadState(gid: gid, state: Self.stateWait)
        } catch {
            return false
        }
        downloadQueue[index].state = Self.stateWait
        processQueue()
        return true
    }

    /// 强制尝试处理队列 (外部调用)
    public func kickQueue() {
        processQueue()
    }

    /// 删除下载 (可选删除文件)
    public func deleteDownload(gid: Int64, deleteFiles: Bool = false) {
        deleteDownload(gid: gid, deleteFiles: deleteFiles, confirmedDirectory: nil)
    }

    private func deleteDownload(gid: Int64, deleteFiles: Bool, confirmedDirectory: URL?) {
        let task = downloadQueue.first(where: { $0.gallery.gid == gid })
        if activeAttempt?.gid == gid { retireActiveAttempt() }
        downloadQueue.removeAll { $0.gallery.gid == gid }
        try? database.deleteDownload(gid: gid)
        // 列表行上的「已下载」标记要跟着消失
        NotificationCenter.default.post(name: Notification.Name("galleryDownloadChanged"),
                                        object: nil,
                                        userInfo: ["gid": gid, "downloading": false])

        if deleteFiles {
            let deletion = FileDeletion(
                gid: gid, title: task?.gallery.bestTitle, pages: task?.gallery.pages ?? 0,
                confirmedDirectory: confirmedDirectory
            )
            if runner?.attempt.gid == gid {
                // The old transfer may already be in a disk write. Delete
                // after it drains and before any replacement starts.
                if pendingFileDeletion == nil { pendingFileDeletion = deletion }
            } else {
                removeFiles(deletion)
            }
        }

        _ = closeNotificationBatchIfIdle()
        processQueue()
    }

    /// Delete only the same completed tasks shown for confirmation. Rechecking
    /// and deleting happen on this actor without a suspension between them.
    public func deleteFinishedDownloads(matching identities: [Int64: UUID], in confirmedRoot: URL) {
        deleteConfirmedDownloads(matching: identities, in: confirmedRoot, withFiles: true, onlyFinished: true)
    }

    /// A filter change or replacement with the same GID must not add a task
    /// to an already-confirmed deletion.
    public func deleteConfirmedDownloads(matching identities: [Int64: UUID], in confirmedRoot: URL, withFiles: Bool) {
        deleteConfirmedDownloads(matching: identities, in: confirmedRoot, withFiles: withFiles, onlyFinished: false)
    }

    private func deleteConfirmedDownloads(matching identities: [Int64: UUID], in confirmedRoot: URL, withFiles: Bool, onlyFinished: Bool) {
        let currentRoot = finishedDeletionRoot
        guard confirmedRoot.isFileURL, confirmedRoot.path == currentRoot.path else { return }
        for gid in identities.keys.sorted() {
            guard let task = downloadQueue.first(where: { $0.gallery.gid == gid }),
                  task.recordIdentity == identities[gid],
                  !onlyFinished || getTaskState(gid: gid) == Self.stateFinish else { continue }
            let name = Self.galleryDirectoryName(gid: gid, title: task.gallery.bestTitle)
            deleteDownload(gid: gid, deleteFiles: withFiles, confirmedDirectory: currentRoot.appendingPathComponent(name))
        }
    }

    private func removeFiles(_ deletion: FileDeletion) {
        if deletion.pages > 0 {
            // A caller supplying an isolated directory is not using the app's
            // shared read cache.
            if directoryOverride == nil { SpiderDen.clearCache(forGid: deletion.gid, pages: deletion.pages) }
        }
        // Deferred cleanup must not pick up a later Settings change.
        if let directory = deletion.confirmedDirectory {
            try? FileManager.default.removeItem(at: directory)
        } else if let title = deletion.title, !title.isEmpty {
            try? FileManager.default.removeItem(at: galleryDirectory(gid: deletion.gid, title: title))
        } else {
            let prefix = "\(deletion.gid)-"
            if let contents = try? FileManager.default.contentsOfDirectory(
                at: downloadDirectory, includingPropertiesForKeys: nil
            ) {
                for item in contents where item.lastPathComponent.hasPrefix(prefix) {
                    try? FileManager.default.removeItem(at: item)
                }
            }
        }
    }

    public func getAllTasks() -> [DownloadTask] {
        downloadQueue
    }

    /// 获取任务状态
    public func getTaskState(gid: Int64) -> Int {
        if activeAttempt?.gid == gid { return Self.stateDownload }
        return downloadQueue.first(where: { $0.gallery.gid == gid })?.state ?? Self.stateInvalid
    }

    /// 更改下载标签 (对齐 Android DownloadManager.changeLabel)
    public func changeLabel(gids: [Int64], label: String?) {
        for gid in gids {
            if let index = downloadQueue.firstIndex(where: { $0.gallery.gid == gid }) {
                downloadQueue[index].label = label
                // 同步到数据库
                if var record = try? database.getDownload(gid: gid) {
                    record.label = label
                    try? database.updateDownload(record)
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
    public func pauseActiveIfNeeded() async {
        guard let attempt = activeAttempt else { return }
        await pauseForExpiration(of: attempt)
    }

    private func pauseForExpiration(of attempt: Attempt) async {
        guard activeAttempt == attempt else { return }
        retireActiveAttempt()
        startQueueAfterDrain = false
        recoverForegroundAfterDrain = false
        if let index = downloadQueue.firstIndex(where: { $0.gallery.gid == attempt.gid }) {
            downloadQueue[index].state = Self.stateWait
            downloadQueue[index].spider = nil
            try? database.updateDownloadState(gid: attempt.gid, state: Self.stateWait)
        }
        // If activation raced ahead of the expiration callback, its first
        // kick saw an active attempt. Recheck after restoring the waiting state.
        await recoverForegroundQueue()
    }

    /// Start queued work only if the iOS application is still active.
    public func recoverForegroundQueue() async {
        guard await isApplicationActive() else { return }
        processQueue(foregroundOnly: true)
    }

    /// 恢复队列处理 (用于 BGProcessingTask 唤醒时)
    public func resumeAllWaiting() {
        processQueue()
    }

    // MARK: - 队列处理

    private func retireActiveAttempt() {
        activeAttempt = nil
        // This task owns SpiderQueen's batch TaskGroup. cancelAll() only
        // covers independently requested pages, not those children.
        runner?.task.cancel()
    }

    private static func isRunnable(_ task: DownloadTask) -> Bool {
        (task.state == Self.stateWait || task.state == Self.stateDownload)
            && !OfflineGallery.isImported(gid: task.gallery.gid, token: task.gallery.token)
    }

    /// An idle boundary belongs to the queue, not to a deferred notification callback.
    /// A later attempt carries a new batch ID even if the old runner is still draining.
    private func closeNotificationBatchIfIdle() -> Bool {
        guard !downloadQueue.contains(where: Self.isRunnable) else { return false }
        notificationBatchID = nil
        return true
    }

    private func processQueue(foregroundOnly: Bool = false) {
        guard activeAttempt == nil else { return }
        guard let index = downloadQueue.firstIndex(where: {
            $0.state == Self.stateWait && Self.isRunnable($0)
        }) else { return }
        guard runner == nil else {
            if foregroundOnly {
                recoverForegroundAfterDrain = true
            } else {
                startQueueAfterDrain = true
            }
            return
        }

        let batchID = notificationBatchID ?? UUID()
        notificationBatchID = batchID
        let attempt = Attempt(gid: downloadQueue[index].gallery.gid, batchID: batchID)
        downloadQueue[index].state = Self.stateDownload
        activeAttempt = attempt
        let task = Task {
            let bgToken = await beginBackgroundTask(for: attempt)
            await executeDownload(attempt)
            await endBackgroundTask(bgToken)
            await finishRunner(attempt)
        }
        runner = (attempt, task)
    }

    // MARK: - 后台任务句柄 (iOS: 申请后台执行时间; 其他平台 no-op)

    private func beginBackgroundTask(for attempt: Attempt) async -> Int {
        #if canImport(UIKit)
        guard activeAttempt == attempt, !Task.isCancelled else {
            return UIBackgroundTaskIdentifier.invalid.rawValue
        }
        let identifier: UIBackgroundTaskIdentifier = await MainActor.run {
            guard !Task.isCancelled else { return .invalid }
            return UIApplication.shared.beginBackgroundTask(withName: "EhGalleryDownload") {
                Task { await self.pauseForExpiration(of: attempt) }
            }
        }
        return identifier.rawValue
        #else
        return 0
        #endif
    }

    private func endBackgroundTask(_ token: Int) async {
        #if canImport(UIKit)
        guard token != UIBackgroundTaskIdentifier.invalid.rawValue else { return }
        await MainActor.run {
            UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: token))
        }
        #endif
    }

    private func finishRunner(_ attempt: Attempt) async {
        guard runner?.attempt == attempt else { return }
        let shouldContinue = activeAttempt == attempt || startQueueAfterDrain
        let shouldRecoverForeground = recoverForegroundAfterDrain
        if activeAttempt == attempt { activeAttempt = nil }
        runner = nil
        startQueueAfterDrain = false
        recoverForegroundAfterDrain = false
        if let deletion = pendingFileDeletion {
            pendingFileDeletion = nil
            removeFiles(deletion)
        }
        if shouldContinue { processQueue() }
        else if shouldRecoverForeground { await recoverForegroundQueue() }
    }

    private func executeDownload(_ attempt: Attempt) async {
        let gid = attempt.gid
        guard activeAttempt == attempt,
              let index = downloadQueue.firstIndex(where: { $0.gallery.gid == gid }) else { return }

        let gallery = downloadQueue[index].gallery
        let quality = downloadQueue[index].quality
        let dir = galleryDirectory(gid: gallery.gid, title: gallery.bestTitle)
        // Legacy transfers retain their historical path (notably for very
        // long titles). New quality tasks use one path for verification and IO.
        let transferDirectory = quality == nil && directoryOverride == nil
            ? SpiderDen.getGalleryDownloadDir(galleryInfo: gallery) : dir
        await listener?.onDownloadStart(gid: gallery.gid, title: gallery.bestTitle)
        guard activeAttempt == attempt else { return }

        // Recheck after any deferred deletion, and before the spider can
        // credit old files. A failed guard never touches numbered pages.
        guard (try? DownloadFolderQuality.prepare(transferDirectory, quality: quality)) == true else {
            guard let failedIndex = downloadQueue.firstIndex(where: { $0.gallery.gid == gid }) else { return }
            downloadQueue[failedIndex].state = Self.stateFailed
            downloadQueue[failedIndex].downloadedPages = 0
            try? database.updateDownloadState(gid: gid, state: Self.stateFailed)
            let batchFinished = closeNotificationBatchIfIdle()
            await listener?.onDownloadFinish(gid: gid, title: gallery.bestTitle,
                                             success: false, batchID: attempt.batchID, isBatchFinished: batchFinished)
            return
        }

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
        let transfer = makeTransfer?(gallery, spiderInfo, quality)
            ?? SpiderQueen(galleryInfo: gallery, spiderInfo: spiderInfo, mode: .download,
                           downloadQuality: quality, downloadDirectory: transferDirectory)

        // 统计已有的下载页数作为初始值
        let initialDownloaded = SpiderInfoFile.getDownloadedPages(in: dir, totalPages: gallery.pages)

        // No suspension since we revalidated ownership after the callback.
        guard let setupIndex = downloadQueue.firstIndex(where: { $0.gallery.gid == gid }) else { return }
        downloadQueue[setupIndex].spider = transfer as? SpiderQueen
        downloadQueue[setupIndex].downloadedPages = initialDownloaded.count

        let updater = SpiderInfoUpdater(
            directory: dir,
            attempt: attempt,
            title: gallery.bestTitle,
            total: gallery.pages,
            manager: self,
            initialDownloaded: initialDownloaded
        )
        await transfer.setDelegate(updater)
        guard activeAttempt == attempt else { return }

        await transfer.startDownload()
        guard activeAttempt == attempt else { return }

        let finalInfo = await transfer.getSpiderInfo()
        var finishedCount = 0
        for i in 0..<gallery.pages {
            guard activeAttempt == attempt else { return }
            if await transfer.getPageState(i) == SpiderQueen.stateFinish {
                finishedCount += 1
            }
        }

        // All terminal disk, database and state writes require ownership.
        guard activeAttempt == attempt,
              let finalIndex = downloadQueue.firstIndex(where: { $0.gallery.gid == gid }) else { return }
        try? SpiderInfoFile.write(finalInfo, to: dir)

        // 下载完成
        let success = finishedCount == gallery.pages
        downloadQueue[finalIndex].state = success ? Self.stateFinish : Self.stateFailed
        downloadQueue[finalIndex].downloadedPages = finishedCount
        downloadQueue[finalIndex].spider = nil  // 释放 spider 引用
        try? database.updateDownloadState(gid: gallery.gid, state: downloadQueue[finalIndex].state)

        let batchFinished = closeNotificationBatchIfIdle()
        await listener?.onDownloadFinish(gid: gallery.gid, title: gallery.bestTitle,
                                         success: success, batchID: attempt.batchID, isBatchFinished: batchFinished)
    }

    fileprivate func reportPageProgress(
        for attempt: Attempt, title: String, downloaded: Int, total: Int,
        speed: Int64, notify: Bool
    ) async {
        guard activeAttempt == attempt else { return }
        updateDownloadedPages(gid: attempt.gid, count: downloaded)
        updateDownloadSpeed(gid: attempt.gid, speed: speed)
        if notify {
            await listener?.onDownloadProgress(gid: attempt.gid, title: title,
                                               downloaded: downloaded, total: total, speed: speed)
        }
    }

    fileprivate func reportImageLimit(for attempt: Attempt) async {
        guard activeAttempt == attempt else { return }
        await listener?.on509Error()
    }

    fileprivate func reportDiskFull(for attempt: Attempt) async {
        guard activeAttempt == attempt else { return }
        pauseAllDownloads()
        await listener?.onDiskFull()
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

    private func readableDirectory(for task: DownloadTask) -> URL? {
        let dir = galleryDirectory(gid: task.gallery.gid, title: task.gallery.bestTitle)
        // A replacement may be queued behind deletion, while mismatched
        // files still occupy the path. Do not expose them as its download.
        if let quality = task.quality, DownloadFolderQuality.recorded(in: dir) != quality { return nil }
        return dir
    }

    /// 检查画廊是否已完整下载 — 验证数据库状态 AND 磁盘上每一页都存在
    /// (仅目录存在不足以判定完成: 下载中断后目录同样存在, 会被误判为"已下载")
    public func isGalleryFullyDownloaded(gid: Int64) -> Bool {
        guard let task = downloadQueue.first(where: { $0.gallery.gid == gid }),
              task.state == Self.stateFinish, let dir = readableDirectory(for: task),
              FileManager.default.fileExists(atPath: dir.path) else { return false }
        let pages = task.gallery.pages
        guard pages > 0 else { return false }
        return SpiderInfoFile.getDownloadedPages(in: dir, totalPages: pages).count >= pages
    }

    /// 已下载的页数 (磁盘真实文件数, 与下载状态无关)
    public func getDownloadedPageCount(gid: Int64) -> Int {
        guard let task = downloadQueue.first(where: { $0.gallery.gid == gid }),
              task.gallery.pages > 0,
              let dir = readableDirectory(for: task) else { return 0 }
        return SpiderInfoFile.getDownloadedPages(in: dir, totalPages: task.gallery.pages).count
    }

    // MARK: - 阅读时同步下载 (对齐 Android 上游 sync_download_while_reading)

    /// 阅读时把看过的图片顺手存进下载目录
    ///
    /// 对应 Android SpiderDen.shouldSyncDownloadWhileReading(): 阅读模式 + 设置开启时，
    /// 写图片的管道从"只写缓存"变成"也写下载目录"。
    /// Apple 端阅读器没走 SpiderDen（自己下图），所以由阅读器下载成功后回调到这里。
    ///
    /// - Returns: 真正写入磁盘了才返回 true (已存在同页 / 磁盘空间不足 → false)
    @discardableResult
    public func saveWhileReading(
        gallery: GalleryInfo, pageIndex: Int, data: Data, extension ext: String
    ) -> Bool {
        guard !OfflineGallery.isImported(gid: gallery.gid, token: gallery.token),
              !Task.isCancelled, pageIndex >= 0, !data.isEmpty,
              pendingFileDeletion?.gid != gallery.gid else { return false }
        let existingIndex = downloadQueue.firstIndex { $0.gallery.gid == gallery.gid }
        // Reader cache bytes have no download-quality provenance. Keep the
        // registered directory when richer detail later changes the title.
        let registered: GalleryInfo
        if let existingIndex {
            let task = downloadQueue[existingIndex]
            guard task.quality == nil, task.gallery.token == gallery.token else { return false }
            registered = task.gallery
        } else {
            registered = gallery
        }
        guard registered.pages <= 0 || pageIndex < registered.pages else { return false }
        let dir = galleryDirectory(gid: registered.gid, title: registered.bestTitle)
        // The record may have been deleted while keeping this folder.
        guard !DownloadFolderQuality.containsMarker(in: dir) else { return false }
        // 已经有这一页就不重复写 (可能是之前下载过的)
        if SpiderInfoFile.getLocalImageURL(in: dir, pageIndex: pageIndex) != nil { return false }

        // 磁盘空间兜底 —— 与正式下载同一套判断
        guard SpiderDen.hasSufficientDiskSpace(bytes: Int64(data.count) + 10 * 1024 * 1024) else {
            return false
        }

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let filename = imageFilename(index: pageIndex, ext: ext)
            try data.write(to: dir.appendingPathComponent(filename))
        } catch {
            print("[DownloadManager] 阅读时同步下载失败 p\(pageIndex): \(error)")
            return false
        }

        // 首次写入时补一份 .ehviewer + 数据库记录，
        // 这样这本画廊会出现在下载列表里，也能被"扫描下载目录恢复任务"认出来
        registerReadingSyncTaskIfNeeded(gallery: registered, directory: dir)

        // 刷新进度，让下载列表显示"已存 N 页"
        if let index = existingIndex ?? downloadQueue.firstIndex(where: { $0.gallery.gid == registered.gid }),
           registered.pages > 0 {
            let saved = SpiderInfoFile.getDownloadedPages(in: dir, totalPages: registered.pages).count
            downloadQueue[index].downloadedPages = saved

            // 整本都看完 = 整本都存下来了 → 标记为已完成
            // (否则列表会一直显示"已暂停"，但 4/4 页其实都在盘上)
            if saved >= registered.pages, downloadQueue[index].state != Self.stateFinish {
                downloadQueue[index].state = Self.stateFinish
                try? database.updateDownloadState(gid: registered.gid, state: Self.stateFinish)
            }
        }
        return true
    }

    /// 同步下载首次落盘时登记任务 (状态设为 stateNone = 已暂停，不会抢占下载队列)
    private func registerReadingSyncTaskIfNeeded(gallery: GalleryInfo, directory: URL) {
        guard !downloadQueue.contains(where: { $0.gallery.gid == gallery.gid }) else { return }

        if SpiderInfoFile.read(from: directory) == nil {
            let info = SpiderInfo(
                startPage: 0, gid: gallery.gid, token: gallery.token, pages: gallery.pages
            )
            try? SpiderInfoFile.write(info, to: directory)
        }

        // ⚠️ stateNone 而不是 stateWait: 这是"顺手存的"，不应该自己启动整本下载
        var task = DownloadTask(gallery: gallery, label: nil, state: Self.stateNone)
        task.downloadedPages = SpiderInfoFile.getDownloadedPages(
            in: directory, totalPages: max(gallery.pages, 1)
        ).count
        downloadQueue.append(task)

        try? database.insertDownload(DownloadTaskPersistence.record(for: task))
    }

    /// 获取已下载画廊的目录路径 (由 ReaderViewModel 调用，替代硬编码路径)
    public func getDownloadedGalleryDirectory(gid: Int64) -> URL? {
        guard let task = downloadQueue.first(where: { $0.gallery.gid == gid }) else { return nil }
        return readableDirectory(for: task)
    }

    /// 本地画廊目录 — 只要有下载记录且目录里至少有一张图就返回
    /// (对齐 Android SpiderDen: 逐页判断本地是否存在，而不是整本"全有或全无")
    /// 这样部分下载 / 下载中断的画廊也能优先读本地，缺失的页再回退网络
    public func localGalleryDirectory(gid: Int64) -> URL? {
        guard let task = downloadQueue.first(where: { $0.gallery.gid == gid }) else { return nil }
        guard let dir = readableDirectory(for: task),
              FileManager.default.fileExists(atPath: dir.path) else { return nil }
        let pages = task.gallery.pages
        guard pages > 0,
              !SpiderInfoFile.getDownloadedPages(in: dir, totalPages: pages).isEmpty else { return nil }
        return dir
    }
}

// MARK: - DownloadTask

public struct DownloadTask: Sendable {
    /// In-memory identity for confirmations; a replacement with the same GID
    /// must not inherit an open confirmation. No persisted schema change.
    public let recordIdentity = UUID()
    public let gallery: GalleryInfo
    public let createdAt: Date
    public let quality: DownloadQuality?
    public var label: String?
    public var state: Int
    public var downloadedPages: Int
    /// 下载速度 (字节/秒)
    public var speed: Int64
    public var spider: SpiderQueen?

    /// Whether the currently queued or active transfer accepts Pause.
    public var canPause: Bool {
        (state == DownloadManager.stateWait || state == DownloadManager.stateDownload)
            && !OfflineGallery.isImported(gid: gallery.gid, token: gallery.token)
    }

    /// Whether a paused or failed online transfer accepts Resume.
    public var canResume: Bool {
        (state == DownloadManager.stateNone || state == DownloadManager.stateFailed)
            && !OfflineGallery.isImported(gid: gallery.gid, token: gallery.token)
    }

    public init(gallery: GalleryInfo, label: String? = nil, state: Int = DownloadManager.stateWait,
                createdAt: Date = .init(), quality: DownloadQuality? = nil) {
        self.gallery = gallery
        self.createdAt = createdAt
        self.quality = quality
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

/// Download-only surface: tests can hold a transfer at a known suspension
/// point without networking, while production keeps the existing SpiderQueen.
protocol DownloadTransfer: Sendable {
    func setDelegate(_ delegate: SpiderDelegate?) async
    func startDownload() async
    func getSpiderInfo() async -> SpiderInfo
    func getPageState(_ index: Int) async -> Int
}

extension SpiderQueen: DownloadTransfer {}

// MARK: - SpiderInfoUpdater (用于下载时更新 .ehviewer 文件)

actor SpiderInfoUpdater: SpiderDelegate {
    private let directory: URL
    private let attempt: DownloadManager.Attempt
    private let title: String
    private let totalPages: Int
    private weak var manager: DownloadManager?

    private var completedPages: Set<Int>
    private var totalBytesDownloaded: Int64 = 0
    private var startTime: Date = Date()
    private var lastNotifyTime: Date = .distantPast
    private let notifyInterval: TimeInterval = 1.0 // 每秒最多通知一次

    fileprivate init(
        directory: URL, attempt: DownloadManager.Attempt, title: String,
        total: Int, manager: DownloadManager, initialDownloaded: Set<Int>
    ) {
        self.directory = directory
        self.attempt = attempt
        self.title = title
        self.totalPages = total
        self.manager = manager
        self.completedPages = initialDownloaded
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
        // Existing files are included in the initial snapshot. SpiderQueen
        // also reports cache hits as loaded, so count each page only once.
        guard (0..<totalPages).contains(index), completedPages.insert(index).inserted else { return }

        // 累计实际下载字节数
        let pageSize = getPageFileSize(index: index)
        totalBytesDownloaded += pageSize

        let now = Date()
        let elapsed = now.timeIntervalSince(startTime)
        let speed = elapsed > 0 ? Int64(Double(totalBytesDownloaded) / elapsed) : 0
        let notify = now.timeIntervalSince(lastNotifyTime) >= notifyInterval
        if notify { lastNotifyTime = now }
        await manager?.reportPageProgress(for: attempt, title: title,
                                          downloaded: completedPages.count, total: totalPages,
                                          speed: speed, notify: notify)
    }

    func onPageFailed(index: Int, error: Error) async {
        print("[SpiderInfoUpdater] Page \(index) failed: \(error)")
    }

    func onImageLimitReached() async {
        print("[SpiderInfoUpdater] Image limit (509) reached")
        await manager?.reportImageLimit(for: attempt)
    }

    func onDiskFull() async {
        print("[SpiderInfoUpdater] ⚠️ 磁盘空间不足，暂停所有下载")
        await manager?.reportDiskFull(for: attempt)
    }

    // Queue progress comes from distinct onPageLoaded indexes; an
    // aggregate callback cannot identify duplicates or already-saved pages.
    func onDownloadProgress(downloaded: Int, total: Int) async {}
}

// MARK: - DownloadListener (下载事件监听器)

public protocol DownloadListener: AnyObject, Sendable {
    /// 下载开始
    func onDownloadStart(gid: Int64, title: String) async

    /// 下载进度更新
    func onDownloadProgress(gid: Int64, title: String, downloaded: Int, total: Int, speed: Int64) async

    /// 下载完成
    func onDownloadFinish(gid: Int64, title: String, success: Bool, batchID: UUID, isBatchFinished: Bool) async

    /// 509错误
    func on509Error() async

    /// 磁盘空间不足
    func onDiskFull() async
}
