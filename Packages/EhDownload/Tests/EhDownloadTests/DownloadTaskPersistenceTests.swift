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
                for: DownloadTask(gallery: queued, label: "Study", state: DownloadManager.stateWait),
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
