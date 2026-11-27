import EhModels
import Foundation
import Testing
@testable import EhDatabase
@testable import EhDownload

@Suite struct DownloadTaskPersistenceTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func storedDownloadAndReadingTaskKeepMetadataOnColdReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("test.sqlite")
        let queued = GalleryInfo(gid: 10, token: "neutral", title: "Original", titleJpn: "原題",
                                 thumb: "neutral.png", category: .misc, posted: "2024-01-01",
                                 uploader: "fixture", rating: 4.25, pages: 8,
                                 simpleTags: ["language:japanese", "artist:fixture"], simpleLanguage: "JA")
        let reading = GalleryInfo(gid: 20, token: "reading", title: "Reader entry", pages: 6,
                                   simpleTags: ["language:english"], simpleLanguage: "EN")
        do {
            let store = try EhDatabase(storageURL: databaseURL)
            try store.insertDownload(DownloadTaskPersistence.record(
                for: DownloadTask(gallery: queued, label: "Study", state: DownloadManager.stateWait, quality: .x1600),
                date: now
            ))
            try store.insertDownload(DownloadTaskPersistence.record(
                for: DownloadTask(gallery: reading, state: DownloadManager.stateNone), date: now
            ))
        }
        let reopened = try EhDatabase(storageURL: databaseURL)
        let persisted = try #require(try reopened.getDownload(gid: queued.gid))
        let persistedReading = try #require(try reopened.getDownload(gid: reading.gid))
        var scanned: [Int64] = []
        let restored = DownloadTaskPersistence.restore(persisted) { gallery in
            scanned.append(gallery.gid)
            return 3
        }
        let restoredReading = DownloadTaskPersistence.restore(persistedReading) { gallery in
            scanned.append(gallery.gid)
            return 1
        }
        #expect(persisted.date == now)
        #expect(restored.gallery.gid == queued.gid)
        #expect(restored.gallery.token == queued.token)
        #expect(restored.gallery.bestTitle == queued.bestTitle)
        #expect(restored.gallery.titleJpn == queued.titleJpn)
        #expect(restored.gallery.thumb == queued.thumb)
        #expect(restored.gallery.category == queued.category)
        #expect(restored.gallery.posted == queued.posted)
        #expect(restored.gallery.uploader == queued.uploader)
        #expect(restored.gallery.rating == queued.rating)
        #expect(restored.gallery.simpleTags == queued.simpleTags)
        #expect(restored.gallery.simpleLanguage == queued.simpleLanguage)
        #expect(restored.gallery.pages == queued.pages)
        #expect(restored.label == "Study")
        #expect(restored.quality == .x1600)
        #expect(restoredReading.quality == nil)
        #expect(restored.state == DownloadManager.stateWait)
        #expect(restored.downloadedPages == 3)
        #expect(restored.speed == 0)
        #expect(restored.spider == nil)
        #expect(restoredReading.gallery.simpleTags == reading.simpleTags)
        #expect(restoredReading.gallery.simpleLanguage == reading.simpleLanguage)
        #expect(restoredReading.label == nil)
        #expect(restoredReading.state == DownloadManager.stateNone)
        #expect(restoredReading.downloadedPages == 1)
        #expect(scanned == [queued.gid, reading.gid])
        #expect(DownloadManager.galleryDirectoryName(gid: restored.gallery.gid, title: restored.gallery.bestTitle)
                == DownloadManager.galleryDirectoryName(gid: queued.gid, title: queued.bestTitle))
    }

    @Test func readingSyncKeepsRegisteredFolderWhenTitleIsEnriched() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EhDatabase(inMemory: true)
        let manager = DownloadManager(database: store, directory: root)
        let initial = GalleryInfo(gid: 9, token: "fixture", title: "List title", pages: 2)
        var enriched = initial
        enriched.titleJpn = "Detail title"
        var wrongToken = enriched
        wrongToken.token = "other"
        let originalFolder = manager.galleryDirectory(gid: initial.gid, title: initial.bestTitle)
        let alternateFolder = manager.galleryDirectory(gid: initial.gid, title: enriched.bestTitle)
        #expect(await manager.saveWhileReading(gallery: initial, pageIndex: 0, data: Data([1]), extension: ".png"))
        #expect(!(await manager.saveWhileReading(gallery: wrongToken, pageIndex: 1, data: Data([3]), extension: ".png")))
        #expect(await manager.saveWhileReading(gallery: enriched, pageIndex: 1, data: Data([2]), extension: ".png"))
        #expect(try Data(contentsOf: originalFolder.appendingPathComponent("00000002.png")) == Data([2]))
        #expect(!FileManager.default.fileExists(atPath: alternateFolder.path))
        #expect(await manager.getDownloadedPageCount(gid: initial.gid) == 2)
        #expect(try store.getDownload(gid: initial.gid)?.state == DownloadManager.stateFinish)
    }

    @Test func clearFinishedDeletesOnlyMatchingCompletedRecordsAndFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EhDatabase(inMemory: true)
        let target = GalleryInfo(gid: 1, token: "neutral", title: "Target", pages: 1)
        let later = GalleryInfo(gid: 2, token: "neutral", title: "Later", pages: 2)
        let replacement = GalleryInfo(gid: 3, token: "neutral", title: "Replacement", pages: 1)
        let removed = GalleryInfo(gid: 4, token: "neutral", title: "Removed", pages: 1)
        let paused = GalleryInfo(gid: 5, token: "neutral", title: "Paused", pages: 2)
        let galleries = [target, later, replacement, removed, paused]
        let manager = DownloadManager(database: store, directory: root, makeTransfer: { _, _, _ in
            preconditionFailure("The local-data test must never start a transfer")
        })

        for gallery in galleries {
            let saved = await manager.saveWhileReading(gallery: gallery, pageIndex: 0, data: Data([0x01]), extension: ".png")
            try #require(saved)
        }
        let tasks = await manager.getAllTasks()
        let snapshot = Dictionary(uniqueKeysWithValues: tasks
            .filter { $0.state == DownloadManager.stateFinish }
            .map { ($0.gallery.gid, $0.recordIdentity) })
        #expect(Set(snapshot.keys) == [target.gid, replacement.gid, removed.gid])

        // Presenting and cancelling confirmation performs no manager operation.
        for gallery in galleries {
            #expect(try store.getDownload(gid: gallery.gid) != nil)
        }
        // Another task finishes while the dialog is open. One target is
        // removed with files retained; another is replaced under the same GID.
        let lateSave = await manager.saveWhileReading(gallery: later, pageIndex: 1, data: Data([0x02]), extension: ".png")
        try #require(lateSave)
        await manager.deleteDownload(gid: removed.gid, deleteFiles: false)
        await manager.deleteDownload(gid: replacement.gid, deleteFiles: true)
        let replacementSave = await manager.saveWhileReading(gallery: replacement, pageIndex: 0,
                                                              data: Data([0x03]), extension: ".png")
        try #require(replacementSave)

        // A duplicated confirmation delivery is harmless, as are non-finished
        // entries even if their true record identity is supplied.
        let pausedTask = try #require(tasks.first { $0.gallery.gid == paused.gid })
        var requested = snapshot
        requested[paused.gid] = pausedTask.recordIdentity
        await manager.deleteFinishedDownloads(matching: requested, in: manager.finishedDeletionRoot)
        await manager.deleteFinishedDownloads(matching: requested, in: manager.finishedDeletionRoot)

        for gallery in galleries {
            let directory = root.appendingPathComponent(DownloadManager.galleryDirectoryName(
                gid: gallery.gid, title: gallery.bestTitle
            ))
            #expect(FileManager.default.fileExists(atPath: directory.path) == (gallery.gid != target.gid))
            #expect((try store.getDownload(gid: gallery.gid) != nil)
                    == (gallery.gid != target.gid && gallery.gid != removed.gid))
        }
        #expect(await manager.getTaskState(gid: later.gid) == DownloadManager.stateFinish)
        #expect(await manager.getTaskState(gid: replacement.gid) == DownloadManager.stateFinish)
        #expect(await manager.getTaskState(gid: paused.gid) == DownloadManager.stateNone)
    }

    @Test func clearFinishedRejectsChangedRootAndDeletesOnlyExactEmptyTitleDirectory() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let original = parent.appendingPathComponent("original", isDirectory: true)
        let replacement = parent.appendingPathComponent("replacement", isDirectory: true)
        let selected = parent.appendingPathComponent("selected", isDirectory: true)
        let files = FileManager.default
        try files.createDirectory(at: original, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: parent) }
        try files.createDirectory(at: replacement, withIntermediateDirectories: false)
        try files.createSymbolicLink(at: selected, withDestinationURL: original)

        let store = try EhDatabase(inMemory: true)
        let gallery = GalleryInfo(gid: 6, token: "neutral", title: "", pages: 1)
        let manager = DownloadManager(database: store, directory: selected, makeTransfer: { _, _, _ in
            preconditionFailure("The local-data test must never start a transfer")
        })
        let saved = await manager.saveWhileReading(gallery: gallery, pageIndex: 0, data: Data([0x01]), extension: ".png")
        try #require(saved)
        let tasks = await manager.getAllTasks()
        let task = try #require(tasks.first)
        #expect(task.state == DownloadManager.stateFinish)
        let targets = [gallery.gid: task.recordIdentity]
        let confirmedRoot = manager.finishedDeletionRoot
        let originalGalleryDir = original.appendingPathComponent("6-")
        let unrelatedSibling = original.appendingPathComponent("6-Preserve this")
        let replacementGalleryDir = replacement.appendingPathComponent("6-")
        try files.createDirectory(at: unrelatedSibling, withIntermediateDirectories: false)
        try files.createDirectory(at: replacementGalleryDir, withIntermediateDirectories: false)

        try files.removeItem(at: selected)
        try files.createSymbolicLink(at: selected, withDestinationURL: replacement)
        await manager.deleteFinishedDownloads(matching: targets, in: confirmedRoot)
        #expect(try store.getDownload(gid: gallery.gid) != nil)
        #expect(files.fileExists(atPath: originalGalleryDir.path))
        #expect(files.fileExists(atPath: replacementGalleryDir.path))

        // A fresh confirmation after selecting the original root may delete
        // the old task, but never similarly prefixed siblings or the other root.
        try files.removeItem(at: selected)
        try files.createSymbolicLink(at: selected, withDestinationURL: original)
        await manager.deleteFinishedDownloads(matching: targets, in: manager.finishedDeletionRoot)
        #expect(try store.getDownload(gid: gallery.gid) == nil)
        #expect(!files.fileExists(atPath: originalGalleryDir.path))
        #expect(files.fileExists(atPath: unrelatedSibling.path))
        #expect(files.fileExists(atPath: replacementGalleryDir.path))
    }

    @Test func historicalCompletionAndUnknownPageCountDoNotProbeFiles() {
        let complete = DownloadRecord(gid: 1, token: "neutral", title: "Finished",
                                      pages: 7, state: DownloadManager.stateFinish)
        let unknown = DownloadRecord(gid: 2, token: "neutral2", title: "Paused",
                                     state: DownloadManager.stateNone)
        var diskScans = 0
        let scan: (GalleryInfo) -> Int = { _ in diskScans += 1; return 0 }
        let restoredComplete = DownloadTaskPersistence.restore(complete, storedPageCount: scan)
        let restoredUnknown = DownloadTaskPersistence.restore(unknown, storedPageCount: scan)
        #expect(diskScans == 0)
        #expect(restoredComplete.downloadedPages == 7)
        #expect(restoredComplete.state == DownloadManager.stateFinish)
        #expect(restoredUnknown.downloadedPages == 0)
        #expect(restoredUnknown.state == DownloadManager.stateNone)
    }
}
