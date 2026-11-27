import Foundation
import SQLite3
import Testing
import EhModels
import EhSpider
@testable import EhDatabase
@testable import EhDownload

@Suite(.timeLimit(.minutes(1))) struct DownloadAttemptTests {
    enum BetweenTransfers: CaseIterable, Sendable {
        case pause, remove, continueBatch
    }

    @Test(arguments: BetweenTransfers.allCases)
    func notificationBatchOwnershipTracksQueueIdle(_ decision: BetweenTransfers) async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EhDatabase(inMemory: true)
        let a = fixture(71), b = fixture(72), c = fixture(73)
        let first = HeldTransfer(gid: a.gid)
        let second = HeldTransfer(gid: b.gid)
        let third = HeldTransfer(gid: c.gid)
        let factory = TransferSequence([first, second, third])
        let manager = DownloadManager(database: store, directory: root, makeTransfer: { _, _, _ in factory.take() })
        let listener = RecordingListener()
        await manager.setListener(listener)

        #expect(await manager.startDownload(gallery: a) == .enqueued)
        await first.waitUntilStarted()
        #expect(await manager.startDownload(gallery: b) == .enqueued)
        await first.allowReturn()
        await second.waitUntilStarted()
        let firstNotice = try #require(await listener.completions.first)
        #expect(firstNotice.gid == a.gid && !firstNotice.isFinal)

        switch decision {
        case .pause:
            await manager.pauseDownload(gid: b.gid)
            #expect(await manager.getTaskState(gid: b.gid) == DownloadManager.stateNone)
        case .remove:
            await manager.deleteDownload(gid: b.gid)
            #expect(try store.getDownload(gid: b.gid) == nil)
        case .continueBatch:
            break
        }
        // Queue C while the B runner is still held. A retired runner can drain
        // after C is enqueued but must not carry A into C's batch.
        #expect(await manager.startDownload(gallery: c) == .enqueued)
        await second.allowReturn()
        await third.waitUntilStarted()
        await third.allowReturn()
        let continuous = decision == .continueBatch
        await listener.waitUntilFinished(count: continuous ? 3 : 2)

        let notices = await listener.completions
        #expect(notices.map(\.gid) == (continuous ? [a.gid, b.gid, c.gid] : [a.gid, c.gid]))
        #expect(notices.last?.isFinal == true)
        #expect((notices.last?.batchID == firstNotice.batchID) == continuous)
        if continuous { #expect(notices.dropLast().allSatisfy { !$0.isFinal && $0.batchID == firstNotice.batchID }) }
    }

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
        let manager = DownloadManager(database: store, directory: root, makeTransfer: { _, _, _ in transfer })
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

    @Test func startReportsCommittedStateWithoutDuplicatingOrChangingExistingTasks() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EhDatabase(inMemory: true)
        let active = fixture(51)
        let waiting = fixture(52)
        let paused = fixture(53)
        let failed = fixture(54)
        let finished = fixture(55)
        let imported = GalleryInfo(gid: -56, token: OfflineGallery.token, title: "Offline", pages: 1)
        let folder = root.appendingPathComponent(DownloadManager.galleryDirectoryName(
            gid: finished.gid, title: finished.bestTitle
        ))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = folder.appendingPathComponent("00000001.jpg")
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xD9])
        try bytes.write(to: image)
        for (gallery, state) in [(paused, DownloadManager.stateNone), (failed, DownloadManager.stateFailed),
                                 (finished, DownloadManager.stateFinish), (imported, DownloadManager.stateFinish)] {
            try store.insertDownload(DownloadTaskPersistence.record(
                for: .init(gallery: gallery, label: "Original group", state: state)
            ))
        }
        let transfer = HeldTransfer(gid: active.gid)
        let factory = TransferSequence([transfer])
        let manager = DownloadManager(database: store, directory: root, makeTransfer: { _, _, _ in factory.take() })

        async let first = manager.startDownload(gallery: active, label: "First label")
        async let second = manager.startDownload(gallery: active, label: "First label")
        let requests = await [first, second]
        #expect(requests.filter { $0 == .enqueued }.count == 1)
        #expect(requests.filter { $0 == .alreadyDownloading }.count == 1)
        await transfer.waitUntilStarted()
        #expect(await manager.startDownload(gallery: active, label: "Ignored") == .alreadyDownloading)
        #expect(await manager.startDownload(gallery: waiting) == .enqueued)
        #expect(await manager.startDownload(gallery: waiting) == .alreadyWaiting)
        #expect(await manager.startDownload(gallery: paused, label: "Ignored") == .resumed)
        #expect(await manager.startDownload(gallery: failed, label: "Ignored") == .resumed)
        #expect(await manager.startDownload(gallery: paused) == .alreadyWaiting)
        #expect(await manager.startDownload(gallery: finished, label: "Ignored") == .alreadyFinished)
        #expect(await manager.startDownload(gallery: imported) == .offlineImport)
        let mismatched = GalleryInfo(gid: imported.gid, token: "other", title: "Other", pages: 1)
        #expect(await manager.startDownload(gallery: mismatched) == .offlineImport)
        #expect(await manager.getAllTasks().count == 6)
        #expect(try store.getDownload(gid: active.gid)?.label == "First label")
        for gallery in [paused, failed] {
            #expect(try store.getDownload(gid: gallery.gid)?.label == "Original group")
            #expect(try store.getDownload(gid: gallery.gid)?.state == DownloadManager.stateWait)
        }
        #expect(try store.getDownload(gid: finished.gid)?.state == DownloadManager.stateFinish)
        #expect(try store.getDownload(gid: imported.gid)?.state == DownloadManager.stateFinish)
        #expect(try Data(contentsOf: image) == bytes)
        await manager.pauseAllDownloads()
        await transfer.allowReturn()
    }

    @Test func rejectedDatabaseWritesDoNotReportEnqueueOrResume() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("downloads.sqlite")
        let store = try EhDatabase(storageURL: databaseURL)
        let paused = fixture(53)
        let new = fixture(54)
        try store.insertDownload(DownloadTaskPersistence.record(
            for: .init(gallery: paused, label: "Original group", state: DownloadManager.stateNone)
        ))
        var connection: OpaquePointer?
        try #require(sqlite3_open(databaseURL.path, &connection) == SQLITE_OK)
        defer { sqlite3_close(connection) }
        try #require(sqlite3_exec(connection, """
            CREATE TRIGGER refuse_new BEFORE INSERT ON download
            BEGIN SELECT RAISE(ABORT, 'Synthetic registration failure'); END;
            CREATE TRIGGER refuse_resume BEFORE UPDATE OF state ON download
            BEGIN SELECT RAISE(ABORT, 'Synthetic state write failure'); END;
            """, nil, nil, nil) == SQLITE_OK)
        let transfer = HeldTransfer(gid: new.gid)
        let manager = DownloadManager(database: store, directory: root, makeTransfer: { _, _, _ in transfer })

        #expect(await manager.startDownload(gallery: new) == .unavailable)
        #expect(await manager.startDownload(gallery: paused) == .unavailable)
        #expect(await manager.getAllTasks().map(\.gallery.gid) == [paused.gid])
        #expect(await manager.getTaskState(gid: paused.gid) == DownloadManager.stateNone)
        #expect(try store.getDownload(gid: new.gid) == nil)
        #expect(try store.getDownload(gid: paused.gid)?.state == DownloadManager.stateNone)
        #expect(await !transfer.hasStarted)
        // Drain even if a regressed candidate incorrectly starts the transfer.
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
        let manager = DownloadManager(database: store, directory: root, makeTransfer: { _, _, _ in transfer })
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

    @MainActor
    @Test(arguments: [ActivationOrder.foregroundAfterExpiration, .foregroundBeforeExpiration, .backgroundAgainBeforeDrain])
    func foregroundResumesExpiredAttemptAfterDrainButNotManualPause(order: ActivationOrder) async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EhDatabase(inMemory: true)
        let gallery = GalleryInfo(gid: 46, token: "neutral", title: "Partial fixture", pages: 2)
        let paused = fixture(47)
        let directory = root.appendingPathComponent(DownloadManager.galleryDirectoryName(
            gid: gallery.gid, title: gallery.bestTitle
        ))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let existingFile = directory.appendingPathComponent("00000001.jpg")
        let original = Data([0xFF, 0xD8, 0xFF, 0xD9])
        try original.write(to: existingFile)
        try store.insertDownload(DownloadTaskPersistence.record(
            for: .init(gallery: paused, label: "Manually paused", state: DownloadManager.stateNone)
        ))
        let old = HeldTransfer(gid: gallery.gid)
        let resumed = HeldTransfer(gid: gallery.gid)
        let factory = TransferSequence([old, resumed])
        let listener = RecordingListener()
        let activation = SimulatedActivation()
        let manager = DownloadManager(database: store, directory: root, isApplicationActive: {
            activation.isActive
        }, makeTransfer: { _, _, _ in factory.take() })
        await manager.setListener(listener)
        try store.insertDownload(DownloadTaskPersistence.record(
            for: .init(gallery: gallery, label: "Existing label", state: DownloadManager.stateNone)
        ))
        #expect(await manager.startDownload(gallery: gallery) == .resumed)
        await old.waitUntilStarted()

        if order != .foregroundAfterExpiration {
            activation.isActive = true
            await manager.recoverForegroundQueue() // No-op while the old attempt is active.
        }
        await manager.pauseActiveIfNeeded()

        #expect(await manager.getTaskState(gid: gallery.gid) == DownloadManager.stateWait)
        #expect(try store.getDownload(gid: gallery.gid)?.state == DownloadManager.stateWait)
        #expect(await !resumed.hasStarted)
        await old.emitLateEvents()
        #expect(await listener.progress == [])
        #expect(await listener.diskFullCount == 0)
        #expect(await listener.limitCount == 0)
        if order != .foregroundBeforeExpiration {
            activation.isActive = false
            await manager.recoverForegroundQueue() // Inactive must not request a restart.
            await old.allowReturn()
            try await Task.sleep(for: .milliseconds(50))
            #expect(await !resumed.hasStarted)
            activation.isActive = true
            await manager.recoverForegroundQueue()
        }
        await old.allowReturn()

        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while await !resumed.hasStarted && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await resumed.hasStarted)
        #expect(await old.observedCancellation)
        #expect(await manager.getTaskState(gid: paused.gid) == DownloadManager.stateNone)
        #expect((await manager.getAllTasks()).first { $0.gallery.gid == gallery.gid }?.downloadedPages == 1)
        #expect(try Data(contentsOf: existingFile) == original)
        #expect(try store.getDownload(gid: gallery.gid)?.label == "Existing label")

        await resumed.allowReturn()
        await listener.waitUntilFinished()
        #expect(await listener.finished == [gallery.gid])
        #expect(try store.getDownload(gid: paused.gid)?.state == DownloadManager.stateNone)
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
        let manager = DownloadManager(database: store, directory: root, makeTransfer: { _, _, _ in factory.take() })
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
        let manager = DownloadManager(database: store, directory: root, makeTransfer: { _, _, _ in factory.take() })
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
        let manager = DownloadManager(database: store, directory: root, makeTransfer: { _, _, _ in transfer })
        let listener = RecordingListener()
        await manager.setListener(listener)
        try store.insertDownload(DownloadTaskPersistence.record(
            for: .init(gallery: gallery, state: DownloadManager.stateNone)
        ))
        #expect(await manager.startDownload(gallery: gallery) == .resumed)
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

    @Test(arguments: [1, 3])
    func addingOriginalAfterRecordOnlyDeletionMustNotCountRetainedSizedImage(pageCount: Int) async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EhDatabase(storageURL: root.appendingPathComponent("queue.sqlite"))
        var gallery = GalleryInfo(gid: 104, token: "neutral", title: "Retained download fixture", pages: pageCount)
        let oldState = pageCount == 1 ? DownloadManager.stateFinish : DownloadManager.stateNone
        let old = DownloadTask(gallery: gallery, state: oldState, quality: .x780)
        try store.insertDownload(DownloadTaskPersistence.record(for: old))
        let directory = root.appendingPathComponent(DownloadManager.galleryDirectoryName(
            gid: gallery.gid, title: gallery.bestTitle
        ))
        #expect(try DownloadFolderQuality.prepare(directory, quality: .x780))
        let oldImage = directory.appendingPathComponent("00000001.jpg")
        let oldBytes = Data([0xFF, 0xD8, 0x10, 0xFF, 0xD9])
        try oldBytes.write(to: oldImage)
        let manager = DownloadManager(database: store, directory: root, makeTransfer: { _, _, _ in
            Issue.record("Conflicting retained pages must not reach the transfer.")
            return HeldTransfer(gid: 104)
        })

        await manager.deleteDownload(gid: gallery.gid, deleteFiles: false)
        #expect(await manager.startDownload(gallery: gallery, quality: .original) == .retainedFiles)
        let clean = fixture(105)
        let conflicts = await manager.retainedDownloadConflicts(galleries: [clean, gallery, gallery], quality: .original)
        #expect(conflicts.map(\.gid) == [gallery.gid])
        #expect(try store.getDownload(gid: clean.gid) == nil)
        gallery.pages = 0
        #expect(await manager.startDownload(gallery: gallery, quality: .original) == .retainedFiles)
        #expect(try Data(contentsOf: oldImage) == oldBytes)
        #expect(try store.getDownload(gid: gallery.gid) == nil)
        #expect(!(await manager.saveWhileReading(gallery: gallery, pageIndex: 1, data: oldBytes, extension: ".jpg")))

        let info = SpiderInfo(gid: gallery.gid, token: gallery.token, pages: pageCount)
        try SpiderInfoFile.write(info, to: directory)
        #expect(try await manager.restoreRetainedDownload(info, from: directory))
        #expect(await manager.getAllTasks().first?.quality == .x780)
        #expect(await manager.getAllTasks().first?.downloadedPages == 1)
        #expect(try store.getDownload(gid: gallery.gid)?.state == oldState)
    }

    @Test(arguments: [false, true])
    func newTaskReusesOnlyMatchingProvenPolicy(marked: Bool) async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EhDatabase(storageURL: root.appendingPathComponent("queue.sqlite"))
        let gallery = fixture(105)
        let dir = root.appendingPathComponent(DownloadManager.galleryDirectoryName(
            gid: gallery.gid, title: gallery.bestTitle
        ))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if marked { #expect(try DownloadFolderQuality.prepare(dir, quality: .x780)) }
        let page = dir.appendingPathComponent("00000001.jpg")
        let data = Data([0xFF, 0xD8, 0xFF, 0xD9])
        try data.write(to: page)
        let transfer = HeldTransfer(gid: gallery.gid)
        let manager = DownloadManager(database: store, directory: root, makeTransfer: { _, _, selected in
            #expect(selected == .x780)
            return transfer
        })
        if marked {
            try #require(await manager.startDownload(gallery: gallery, quality: .x780) == .enqueued)
            await transfer.waitUntilStarted()
            #expect(await manager.getAllTasks().first?.downloadedPages == 1)
            await manager.pauseDownload(gid: gallery.gid)
            await transfer.allowReturn()
        } else {
            #expect(await manager.startDownload(gallery: gallery, quality: .x780) == .retainedFiles)
            let info = SpiderInfo(gid: gallery.gid, token: gallery.token, pages: gallery.pages)
            try SpiderInfoFile.write(info, to: dir)
            #expect(try await manager.restoreRetainedDownload(info, from: dir))
            #expect(await manager.getAllTasks().first?.quality == nil)
            #expect(await manager.getAllTasks().first?.downloadedPages == 1)
        }
        #expect(try Data(contentsOf: page) == data)
    }

    @Test func replacementAfterConfirmedDiskDeletionUsesNewPolicyOnlyAfterDrain() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EhDatabase(inMemory: true)
        let gallery = fixture(106)
        let dir = root.appendingPathComponent(DownloadManager.galleryDirectoryName(
            gid: gallery.gid, title: gallery.bestTitle
        ))
        let old = HeldTransfer(gid: gallery.gid, lateWriteDirectory: dir)
        let new = HeldTransfer(gid: gallery.gid)
        let factory = TransferSequence([old, new])
        let manager = DownloadManager(database: store, directory: root, makeTransfer: { _, _, _ in factory.take() })
        try #require(await manager.startDownload(gallery: gallery, quality: .x780) == .enqueued)
        await old.waitUntilStarted()
        let page = dir.appendingPathComponent("00000001.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: page)
        await manager.deleteDownload(gid: gallery.gid, deleteFiles: true)
        try #require(await manager.startDownload(gallery: gallery, quality: .original) == .enqueued)
        #expect(await !new.hasStarted)
        #expect(FileManager.default.fileExists(atPath: page.path))
        #expect(await manager.getDownloadedPageCount(gid: gallery.gid) == 0)
        #expect(await manager.localGalleryDirectory(gid: gallery.gid) == nil)
        let reopened = DownloadManager(database: store, directory: root)
        #expect(await reopened.getAllTasks().first?.downloadedPages == 0)
        #expect(await reopened.localGalleryDirectory(gid: gallery.gid) == nil)
        await old.allowReturn()
        await new.waitUntilStarted()
        #expect(await old.didWriteLateFile)
        #expect(await manager.getAllTasks().first?.downloadedPages == 0)
        #expect(DownloadFolderQuality.recorded(in: dir) == .original)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("00000001.jpg").path))
        await manager.pauseDownload(gid: gallery.gid)
        await new.allowReturn()
    }

    @Test func qualityIsSubmittedToTransferAndRetainedForExistingTasks() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("queue.sqlite")
        let store = try EhDatabase(storageURL: databaseURL)
        let gallery = fixture(123456)
        let firstTransfer = HeldTransfer(gid: gallery.gid)
        let manager = DownloadManager(database: store, directory: root, makeTransfer: { _, _, quality in
            #expect(quality == .x1280)
            return firstTransfer
        })
        #expect(await manager.startDownload(gallery: gallery, quality: .x1280) == .enqueued)
        await firstTransfer.waitUntilStarted()
        #expect(await manager.startDownload(gallery: gallery, quality: .x780) == .alreadyDownloading)
        #expect(!(await manager.saveWhileReading(gallery: gallery, pageIndex: 0, data: Data([1]), extension: ".jpg")))
        await manager.pauseAllDownloads()
        await firstTransfer.allowReturn()

        let secondTransfer = HeldTransfer(gid: gallery.gid)
        let restored = DownloadManager(database: try EhDatabase(storageURL: databaseURL), directory: root,
                                       makeTransfer: { _, _, quality in
            #expect(quality == .x1280)
            return secondTransfer
        })
        #expect(await restored.getAllTasks().first?.quality == .x1280)
        #expect(await restored.startDownload(gallery: gallery, quality: .original) == .resumed)
        await secondTransfer.waitUntilStarted()
        #expect(try store.getDownload(gid: gallery.gid)?.quality == "1280")
        await restored.pauseAllDownloads()
        await secondTransfer.allowReturn()
    }

    @Test func readerSyncCannotFinishAQueuedActiveOrDrainingDownload() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EhDatabase(inMemory: true)
        let gallery = GalleryInfo(gid: 81, token: "neutral", title: "First fixture", pages: 2)
        let queued = GalleryInfo(gid: 82, token: "neutral", title: "Second fixture", pages: 2)
        let activeTransfer = HeldTransfer(gid: gallery.gid)
        let queuedTransfer = HeldTransfer(gid: queued.gid)
        let factory = TransferSequence([activeTransfer, queuedTransfer])
        let manager = DownloadManager(database: store, directory: root, makeTransfer: { _, _, quality in
            #expect(quality == nil, "Reader-created or older tasks have no explicit quality.")
            return factory.take()
        })
        let first = Data([0xFF, 0xD8, 1, 0xFF, 0xD9])
        let last = Data([0xFF, 0xD8, 2, 0xFF, 0xD9])
        for item in [gallery, queued] {
            #expect(await manager.saveWhileReading(gallery: item, pageIndex: 0, data: first, extension: ".jpg"))
        }
        let directory = try #require(await manager.getDownloadedGalleryDirectory(gid: gallery.gid))
        let lastURL = directory.appendingPathComponent("00000002.jpg")
        await manager.resumeDownload(gid: gallery.gid)
        await activeTransfer.waitUntilStarted()
        await manager.resumeDownload(gid: queued.gid)

        #expect(!(await manager.saveWhileReading(gallery: gallery, pageIndex: 1, data: last, extension: ".jpg")))
        #expect(!(await manager.saveWhileReading(gallery: queued, pageIndex: 1, data: last, extension: ".jpg")))
        #expect(!FileManager.default.fileExists(atPath: lastURL.path))
        #expect(await manager.getTaskState(gid: gallery.gid) == DownloadManager.stateDownload)
        #expect(await manager.getTaskState(gid: queued.gid) == DownloadManager.stateWait)
        #expect(await manager.getAllTasks().first { $0.gallery.gid == gallery.gid }?.canPause == true)

        await manager.pauseDownload(gid: gallery.gid)
        #expect(await manager.getTaskState(gid: gallery.gid) == DownloadManager.stateNone)
        #expect(!(await manager.saveWhileReading(gallery: gallery, pageIndex: 1, data: last, extension: ".jpg")))
        #expect(!FileManager.default.fileExists(atPath: lastURL.path))

        // Let the lane drain. The successor's start is a deterministic signal
        // that the paused gallery has relinquished the transfer slot.
        await activeTransfer.allowReturn()
        // Free this task if a broken baseline already marked it Finished.
        let successorState = await manager.getTaskState(gid: queued.gid)
        if successorState == DownloadManager.stateWait || successorState == DownloadManager.stateDownload {
            await queuedTransfer.waitUntilStarted()
        }
        #expect(await manager.saveWhileReading(gallery: gallery, pageIndex: 1, data: last, extension: ".jpg"))
        #expect(try Data(contentsOf: lastURL) == last)
        #expect(try store.getDownload(gid: gallery.gid)?.state == DownloadManager.stateFinish)
        await manager.pauseAllDownloads()
        await queuedTransfer.allowReturn()
    }

    @Test func cancelledReadingSyncDoesNotCreateAFileOrDownloadRecord() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EhDatabase(inMemory: true)
        let gallery = fixture(44)
        let manager = DownloadManager(database: store, directory: root, makeTransfer: { _, _, _ in
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

enum ActivationOrder: Sendable {
    case foregroundAfterExpiration, foregroundBeforeExpiration, backgroundAgainBeforeDrain
}

@MainActor
private final class SimulatedActivation {
    var isActive = false
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
    private(set) var completions: [(gid: Int64, batchID: UUID, isFinal: Bool)] = []
    private var finishWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func onDownloadStart(gid: Int64, title: String) {}
    func onDownloadProgress(gid: Int64, title: String, downloaded: Int, total: Int, speed: Int64) {
        progress.append(gid)
    }
    func onDownloadFinish(gid: Int64, title: String, success: Bool, batchID: UUID, isBatchFinished: Bool) {
        finished.append(gid)
        completions.append((gid, batchID, isBatchFinished))
        let ready = finishWaiters.filter { $0.count <= finished.count }
        finishWaiters.removeAll { $0.count <= finished.count }
        for waiter in ready { waiter.continuation.resume() }
    }
    func on509Error() { limitCount += 1 }
    func onDiskFull() { diskFullCount += 1 }

    func waitUntilFinished(count: Int = 1) async {
        if finished.count < count { await withCheckedContinuation { finishWaiters.append((count, $0)) } }
    }
}
