import EhModels
import Testing
@testable import EhDownload

struct DownloadStorageSnapshotTests {
    @Test func lateOldScanCannotRestoreObsoleteSortOrTotal() {
        var storage = DownloadStorageSnapshot()
        let older = storage.begin()
        let newer = storage.begin()

        storage.finish(newer, sizes: [1: 20, 2: 30], total: 55)
        storage.finish(older, sizes: [1: 20, 2: 10], total: 35)

        var order = DownloadListOrder()
        order.key = .fileSize
        order.ascending = false
        let tasks = [1, 2].map { DownloadTask(gallery: GalleryInfo(gid: Int64($0), token: "fixture")) }
        #expect(order.apply(to: tasks, measuredSizes: storage.sizes).map(\.gallery.gid) == [2, 1])
        #expect(storage.total == 55)
        #expect(!storage.isScanning)
    }

    @Test func oldCancellationDoesNotEndNewScanAndRemovedRecordDoesNotReduceDiskUsage() {
        var storage = DownloadStorageSnapshot()
        let old = storage.begin()
        let current = storage.begin()
        storage.cancel(old)
        #expect(storage.isScanning)
        storage.finish(current, sizes: [1: 20, 2: 30], total: 55)
        let scanDuringDelete = storage.begin()
        storage.remove(gid: 2, withFiles: false)
        storage.finish(scanDuringDelete, sizes: [1: 20, 2: 30], total: 55)
        #expect(storage.sizes == [1: 20])
        #expect(storage.total == 55)
        #expect(!storage.isScanning)
    }
}
