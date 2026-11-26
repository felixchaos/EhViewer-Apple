import EhModels
import Foundation
import Testing
@testable import EhDatabase
@testable import EhDownload

@Suite struct DownloadListOrderTests {
    private func task(_ gid: Int64, _ title: String, _ rating: Float, _ stamp: TimeInterval) -> DownloadTask {
        DownloadTask(gallery: GalleryInfo(gid: gid, token: "fixture", title: title, rating: rating),
                     createdAt: Date(timeIntervalSince1970: stamp))
    }

    @Test func queueOrderIsUnchangedAndSortingIsStableInBothDirections() {
        let tasks = [task(30, "Issue 11", 4, 300), task(10, "Issue 2", 4, 100), task(20, "Issue 10", 2, 100)]
        let sizes: [Int64: Int64] = [30: 200, 10: 100]
        var order = DownloadListOrder()
        func ids() -> [Int64] { order.apply(to: tasks, measuredSizes: sizes).map(\.gallery.gid) }
        #expect(ids() == [30, 10, 20])
        order.key = .galleryID
        #expect(ids() == [10, 20, 30])
        order.key = .created
        #expect(ids() == [10, 20, 30])
        order.ascending = false
        #expect(ids() == [30, 10, 20])
        order.key = .rating
        #expect(ids() == [30, 10, 20])
        order.ascending = true
        #expect(ids() == [20, 30, 10])
        order.key = .title
        #expect(ids() == [10, 20, 30])
        order.key = .fileSize
        #expect(ids() == [10, 30, 20])
        order.ascending = false
        #expect(ids() == [30, 10, 20])
        order.key = .queue
        #expect(ids() == [30, 10, 20])
    }

    @Test func unknownGalleryCategoryIsNotTheSameAsKnownMisc() {
        let unknown = EhCategory(rawValue: 0)
        let unknownFuture = EhCategory(rawValue: 0x400)
        #expect(DownloadListCategory.all.includes(unknown))
        #expect(DownloadListCategory.known(.misc).includes(.misc))
        #expect(!DownloadListCategory.known(.misc).includes(unknown))
        #expect(!DownloadListCategory.unknown.includes(.misc))
        #expect(DownloadListCategory.unknown.includes(unknown))
        #expect(DownloadListCategory.unknown.includes(unknownFuture))
    }

    @Test func creationSortKeepsOriginalDatabaseDate() throws {
        let store = try EhDatabase(inMemory: true)
        let queued = task(30, "Fixture", 4, 1_700_000_000)
        try store.insertDownload(DownloadTaskPersistence.record(for: queued))
        let record = try #require(try store.getDownload(gid: 30))
        let reopened = DownloadTaskPersistence.restore(record) { _ in 0 }
        #expect(reopened.createdAt == queued.createdAt)
    }

    @Test func confirmedVisibleDeletionKeepsFileAndRejectsReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EhDatabase(inMemory: true)
        let manager = DownloadManager(database: store, directory: root, makeTransfer: { _, _, _ in
            preconditionFailure("The local-data test must never start a transfer")
        })
        let selected = GalleryInfo(gid: 1, token: "one", title: "Visible", pages: 2)
        let hidden = GalleryInfo(gid: 2, token: "two", title: "Hidden", pages: 1)
        let replaced = GalleryInfo(gid: 3, token: "old", title: "To replace", pages: 1)
        for gallery in [selected, hidden, replaced] {
            let saved = await manager.saveWhileReading(gallery: gallery, pageIndex: 0, data: Data([1]), extension: ".png")
            try #require(saved)
        }
        let tasks = await manager.getAllTasks()
        let confirmed = Dictionary(uniqueKeysWithValues: tasks.filter { $0.gallery.gid != hidden.gid }
            .map { ($0.gallery.gid, $0.recordIdentity) })
        await manager.deleteDownload(gid: replaced.gid, deleteFiles: true)
        let saved = await manager.saveWhileReading(gallery: replaced, pageIndex: 0, data: Data([2]), extension: ".png")
        try #require(saved)
        await manager.deleteConfirmedDownloads(matching: confirmed, in: manager.finishedDeletionRoot, withFiles: false)
        #expect(try store.getDownload(gid: selected.gid) == nil)
        #expect(try store.getDownload(gid: hidden.gid) != nil)
        #expect(try store.getDownload(gid: replaced.gid) != nil)
        let selectedDirectory = root.appendingPathComponent(DownloadManager.galleryDirectoryName(gid: selected.gid, title: selected.bestTitle))
        #expect(FileManager.default.fileExists(atPath: selectedDirectory.path))
    }
}
