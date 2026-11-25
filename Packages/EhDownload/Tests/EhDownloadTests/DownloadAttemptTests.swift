import Foundation
import Testing
import EhModels
import EhSpider
@testable import EhDatabase
@testable import EhDownload

@Suite(.timeLimit(.minutes(1))) struct DownloadAttemptTests {
    @Test func batchCommandsPreserveIneligibleStatesAndCompletedFiles() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("downloads.sqlite")
        let store = try EhDatabase(storageURL: databaseURL)
        let complete = fixture(41)
        let active = fixture(42)
        let waiting = fixture(43)
        let failed = fixture(44)
        let completeDirectory = root.appendingPathComponent(DownloadManager.galleryDirectoryName(
            gid: complete.gid, title: complete.bestTitle
        ))
        try FileManager.default.createDirectory(at: completeDirectory, withIntermediateDirectories: true)
        let imageURL = completeDirectory.appendingPathComponent("00000001.jpg")
        let original = Data([0xFF, 0xD8, 0xFF, 0xD9])
        try original.write(to: imageURL)
        for (gallery, state) in [(complete, DownloadManager.stateFinish), (failed, DownloadManager.stateFailed)] {
            let task = DownloadTask(gallery: gallery, label: "Test group", state: state)
            try store.insertDownload(DownloadTaskPersistence.record(for: task))
        }
        let transfer = HeldTransfer(gid: active.gid)
        let listener = RecordingListener()
        let manager = DownloadManager(database: store, directory: root, makeTransfer: { _, _ in transfer })
        await manager.setListener(listener)
        await manager.startDownload(gallery: active, label: "Active group")
        await transfer.waitUntilStarted()
        await manager.startDownload(gallery: waiting, label: "Waiting group")

        await manager.pauseDownload(gid: complete.gid)
        #expect(await manager.getTaskState(gid: complete.gid) == DownloadManager.stateFinish)
        await manager.resumeDownload(gid: complete.gid)
        await manager.pauseDownload(gid: failed.gid)
        await manager.resumeDownload(gid: active.gid)
        await manager.resumeDownload(gid: waiting.gid)

        let byID = await Dictionary(uniqueKeysWithValues: manager.getAllTasks().map { ($0.gallery.gid, $0) })
        #expect(byID[complete.gid]?.state == DownloadManager.stateFinish)
        #expect(byID[complete.gid]?.label == "Test group")
        #expect(byID[complete.gid]?.downloadedPages == 1)
        #expect(byID[failed.gid]?.state == DownloadManager.stateFailed)
        #expect(byID[waiting.gid]?.state == DownloadManager.stateWait)
        #expect(byID[active.gid]?.state == DownloadManager.stateDownload)
        #expect(await manager.getTaskState(gid: active.gid) == DownloadManager.stateDownload)
        #expect(try Data(contentsOf: imageURL) == original)
        #expect(try store.getDownload(gid: complete.gid)?.state == DownloadManager.stateFinish)
        #expect(try store.getDownload(gid: failed.gid)?.state == DownloadManager.stateFailed)

        await manager.pauseDownload(gid: waiting.gid)
        #expect(await manager.getTaskState(gid: waiting.gid) == DownloadManager.stateNone)
        #expect(try store.getDownload(gid: waiting.gid)?.label == "Waiting group")
        let restored = DownloadManager(database: try EhDatabase(storageURL: databaseURL), directory: root)
        #expect(await restored.getTaskState(gid: complete.gid) == DownloadManager.stateFinish)
        #expect(await restored.localGalleryDirectory(gid: complete.gid) != nil)
        #expect(await restored.getTaskState(gid: waiting.gid) == DownloadManager.stateNone)
        #expect(await restored.getTaskState(gid: failed.gid) == DownloadManager.stateFailed)

        // Keep even a broken candidate from starting a second transfer.
        await manager.pauseAllDownloads()
        await transfer.allowReturn()
    }

    @Test func resumingFailedTaskKeepsItsGroupAndUsesTheQueue() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EhDatabase(inMemory: true)
        let gallery = fixture(47)
        let task = DownloadTask(gallery: gallery, label: "Original group", state: DownloadManager.stateFailed)
        try store.insertDownload(DownloadTaskPersistence.record(for: task))
        let transfer = HeldTransfer(gid: gallery.gid)
        let manager = DownloadManager(database: store, directory: root, makeTransfer: { _, _ in transfer })
        let listener = RecordingListener()
        await manager.setListener(listener)
        await manager.resumeDownload(gid: gallery.gid)
        await transfer.waitUntilStarted()
        #expect(await manager.getTaskState(gid: gallery.gid) == DownloadManager.stateDownload)
        #expect(try store.getDownload(gid: gallery.gid)?.label == "Original group")
        await transfer.allowReturn()
        await listener.waitUntilFinished()
        #expect(try store.getDownload(gid: gallery.gid)?.state == DownloadManager.stateFinish)
    }

    @Test func pausedAttemptCannotCompleteResumedSameGallery() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EhDatabase(inMemory: true)
        let gallery = fixture(42)
        let old = HeldTransfer(gid: gallery.gid)
        let resumed = HeldTransfer(gid: gallery.gid)
        let factory = TransferSequence([old, resumed])
        let listener = RecordingListener()
        let manager = DownloadManager(database: store, directory: root, makeTransfer: { _, _ in factory.take() })
        await manager.setListener(listener)

        await manager.startDownload(gallery: gallery)
        await old.waitUntilStarted()
        await manager.pauseDownload(gid: gallery.gid)
        await manager.resumeDownload(gid: gallery.gid)

        #expect(await manager.getTaskState(gid: gallery.gid) == DownloadManager.stateWait)
        #expect(await !resumed.hasStarted)
        await old.emitLateEvents()
        #expect(await manager.getTaskState(gid: gallery.gid) == DownloadManager.stateWait)
        #expect(await listener.progress == [])
        #expect(await listener.diskFullCount == 0)
        #expect(await listener.limitCount == 0)

        await old.allowReturn()
        await resumed.waitUntilStarted()
        #expect(await old.observedCancellation)
        #expect(try store.getDownload(gid: gallery.gid)?.state == DownloadManager.stateWait)
        #expect(await manager.getTaskState(gid: gallery.gid) == DownloadManager.stateDownload)
        #expect(await listener.finished == [])

        await resumed.allowReturn()
        await listener.waitUntilFinished()
        #expect(await !resumed.observedCancellation)
        #expect(await listener.finished == [gallery.gid])
        #expect(try store.getDownload(gid: gallery.gid)?.state == DownloadManager.stateFinish)
    }

    @Test func deletionRemovesLateFilesBeforeStartingQueuedSibling() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EhDatabase(inMemory: true)
        let gallery = fixture(42)
        let sibling = fixture(43)
        let oldDirectory = root.appendingPathComponent(DownloadManager.galleryDirectoryName(
            gid: gallery.gid, title: gallery.bestTitle
        ))
        let old = HeldTransfer(gid: gallery.gid, lateWriteDirectory: oldDirectory)
        let next = HeldTransfer(gid: sibling.gid)
        let factory = TransferSequence([old, next])
        let listener = RecordingListener()
        let manager = DownloadManager(database: store, directory: root, makeTransfer: { _, _ in factory.take() })
        await manager.setListener(listener)

        await manager.startDownload(gallery: gallery)
        await old.waitUntilStarted()
        await manager.deleteDownload(gid: gallery.gid, deleteFiles: true)
        await manager.startDownload(gallery: sibling)
        #expect(try store.getDownload(gid: gallery.gid) == nil)
        #expect(await !next.hasStarted)

        // The fake deliberately ignores cancellation once, as though an
        // already-issued write finished before the actor could retire it.
        await old.allowReturn()
        await next.waitUntilStarted()
        #expect(await old.observedCancellation)
        #expect(await old.didWriteLateFile)
        #expect(!FileManager.default.fileExists(atPath: oldDirectory.path))
        #expect(await listener.finished == [])
        #expect(await listener.progress == [])
        #expect(await manager.getTaskState(gid: sibling.gid) == DownloadManager.stateDownload)

        await next.allowReturn()
        await listener.waitUntilFinished()
        #expect(await listener.finished == [sibling.gid])
        #expect(try store.getDownload(gid: sibling.gid)?.state == DownloadManager.stateFinish)
    }

    @Test func resumingNeverCountsTheSamePageTwice() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EhDatabase(inMemory: true)
        let gallery = GalleryInfo(gid: 45, token: "neutral", title: "Partial fixture", pages: 2)
        let dir = root.appendingPathComponent(DownloadManager.galleryDirectoryName(
            gid: gallery.gid, title: gallery.bestTitle
        ))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([1]).write(to: dir.appendingPathComponent("00000001.jpg"))
        let transfer = HeldTransfer(gid: gallery.gid)
        let manager = DownloadManager(database: store, directory: root, makeTransfer: { _, _ in transfer })
        let listener = RecordingListener()
        await manager.setListener(listener)
        await manager.startDownload(gallery: gallery)
        await transfer.waitUntilStarted()
        #expect(await manager.getAllTasks().first?.downloadedPages == 1)
        await transfer.emitPageLoaded(0)
        #expect(await manager.getAllTasks().first?.downloadedPages == 1)
        await transfer.emitPageLoaded(1)
        await transfer.emitPageLoaded(1)
        #expect(await manager.getAllTasks().first?.downloadedPages == 2)
        await transfer.allowReturn()
        await listener.waitUntilFinished()
    }

    @Test func cancelledReadingSyncDoesNotCreateAFileOrDownloadRecord() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EhDatabase(inMemory: true)
        let gallery = fixture(44)
        let manager = DownloadManager(database: store, directory: root, makeTransfer: { _, _ in
            fatalError("Reading sync must not start a transfer")
        })

        let cancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await manager.saveWhileReading(
                gallery: gallery, pageIndex: 0, data: Data([1]), extension: ".jpg"
            )
        }.value
        #expect(!cancelled)
        #expect(try store.getDownload(gid: gallery.gid) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        #expect(await manager.saveWhileReading(
            gallery: gallery, pageIndex: 0, data: Data([1]), extension: ".jpg"
        ))
        #expect(try store.getDownload(gid: gallery.gid) != nil)
    }

    private func fixture(_ gid: Int64) -> GalleryInfo {
        GalleryInfo(gid: gid, token: "neutral", title: "Download fixture \(gid)", pages: 1)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}

private final class TransferSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var transfers: [HeldTransfer]
    init(_ transfers: [HeldTransfer]) { self.transfers = transfers }
    func take() -> HeldTransfer {
        lock.withLock { transfers.removeFirst() }
    }
}

private actor HeldTransfer: DownloadTransfer {
    private let gid: Int64
    private let lateWriteDirectory: URL?
    private weak var delegate: SpiderDelegate?
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var returnWaiter: CheckedContinuation<Void, Never>?
    private var mayReturn = false
    private(set) var hasStarted = false
    private(set) var observedCancellation = false
    private(set) var didWriteLateFile = false

    init(gid: Int64, lateWriteDirectory: URL? = nil) {
        self.gid = gid
        self.lateWriteDirectory = lateWriteDirectory
    }

    func setDelegate(_ delegate: SpiderDelegate?) { self.delegate = delegate }

    func startDownload() async {
        hasStarted = true
        startedWaiter?.resume()
        startedWaiter = nil
        if !mayReturn { await withCheckedContinuation { returnWaiter = $0 } }
        observedCancellation = Task.isCancelled
        if let lateWriteDirectory {
            do {
                try FileManager.default.createDirectory(at: lateWriteDirectory, withIntermediateDirectories: true)
                try Data([1, 2, 3]).write(to: lateWriteDirectory.appendingPathComponent("00000001.jpg"))
                didWriteLateFile = true
            } catch {
                Issue.record("Failed to stage the deliberate late file")
            }
            await delegate?.onPageLoaded(index: 0, imageUrl: "fixture")
        }
    }

    func waitUntilStarted() async {
        if !hasStarted { await withCheckedContinuation { startedWaiter = $0 } }
    }

    func allowReturn() {
        mayReturn = true
        returnWaiter?.resume()
        returnWaiter = nil
    }

    func emitPageLoaded(_ index: Int) async {
        await delegate?.onPageLoaded(index: index, imageUrl: "fixture")
    }

    func emitLateEvents() async {
        await delegate?.onPageLoaded(index: 0, imageUrl: "fixture")
        await delegate?.onImageLimitReached()
        await delegate?.onDiskFull()
    }

    func getSpiderInfo() -> SpiderInfo {
        var info = SpiderInfo()
        info.gid = gid
        info.pages = 1
        return info
    }

    func getPageState(_ index: Int) -> Int { SpiderQueen.stateFinish }
}

private actor RecordingListener: DownloadListener {
    private(set) var progress: [Int64] = []
    private(set) var finished: [Int64] = []
    private(set) var diskFullCount = 0
    private(set) var limitCount = 0
    private var finishWaiter: CheckedContinuation<Void, Never>?

    func onDownloadStart(gid: Int64, title: String) {}
    func onDownloadProgress(gid: Int64, title: String, downloaded: Int, total: Int, speed: Int64) {
        progress.append(gid)
    }
    func onDownloadFinish(gid: Int64, title: String, success: Bool, isBatchFinished: Bool) {
        finished.append(gid)
        finishWaiter?.resume()
        finishWaiter = nil
    }
    func on509Error() { limitCount += 1 }
    func onDiskFull() { diskFullCount += 1 }

    func waitUntilFinished() async {
        if finished.isEmpty { await withCheckedContinuation { finishWaiter = $0 } }
    }
}
