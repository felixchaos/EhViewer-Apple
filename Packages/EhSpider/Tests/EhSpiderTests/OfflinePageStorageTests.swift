import EhModels
import EhSpider
import Foundation
import Testing

@Suite("Offline page storage")
struct OfflinePageStorageTests {
    private func withScratchDirectory(_ body: (URL) throws -> Void) throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("EhSpiderTests-\(UUID())", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: directory) }
        try body(directory)
    }

    @Test func readerAndResumeRecognizeEverySupportedPageFilename() throws {
        try withScratchDirectory { directory in
            // Existing offline files, named independently from the writer under test.
            let files = [
                "00000001.jpeg", "00000001.webp", "00000002.jpeg",
                "00000004.png", "00000005.bin", "00000006.jpg", "00000007.gif",
            ]
            for filename in files {
                try Data([0x01]).write(to: directory.appendingPathComponent(filename))
            }
            #expect(SpiderInfoFile.getDownloadedPages(in: directory, totalPages: 3) == [0, 1])
            #expect(SpiderInfoFile.getDownloadedPages(in: directory, totalPages: 7) == [0, 1, 3, 5, 6])
            #expect(SpiderInfoFile.getLocalImageURL(in: directory, pageIndex: 0)?.lastPathComponent == "00000001.webp")
            #expect(SpiderInfoFile.getLocalImageURL(in: directory, pageIndex: 1)?.lastPathComponent == "00000002.jpeg")
            #expect(SpiderInfoFile.getLocalImageURL(in: directory, pageIndex: 2) == nil)
            #expect(SpiderInfoFile.getLocalImageURL(in: directory, pageIndex: 4) == nil)
            #expect(SpiderInfoFile.getLocalImageURL(in: directory, pageIndex: 5)?.lastPathComponent == "00000006.jpg")
            #expect(SpiderInfoFile.getLocalImageURL(in: directory, pageIndex: 6)?.lastPathComponent == "00000007.gif")
        }
    }

    @Test func emptyFilesAndDirectoriesDoNotMaskUsablePageAlternates() throws {
        try withScratchDirectory { directory in
            try Data().write(to: directory.appendingPathComponent("00000001.jpg"))
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent("00000002.jpg"), withIntermediateDirectories: false
            )
            try Data().write(to: directory.appendingPathComponent("00000003.jpg"))
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent("00000003.png"), withIntermediateDirectories: false
            )
            for filename in ["00000003.gif", "00000003.webp", "00000004.jpg", "00000004.png"] {
                try Data([1]).write(to: directory.appendingPathComponent(filename))
            }

            #expect(SpiderInfoFile.getLocalImageURL(in: directory, pageIndex: 0) == nil)
            #expect(SpiderInfoFile.getLocalImageURL(in: directory, pageIndex: 1) == nil)
            #expect(SpiderInfoFile.getLocalImageURL(in: directory, pageIndex: 2)?.lastPathComponent == "00000003.gif")
            #expect(SpiderInfoFile.getLocalImageURL(in: directory, pageIndex: 3)?.lastPathComponent == "00000004.jpg")
            #expect(SpiderInfoFile.getDownloadedPages(in: directory, totalPages: 4) == [2, 3])
        }
    }

    @Test func inventoryIsEmptyWhenMetadataHasNoUsablePageCount() throws {
        try withScratchDirectory { directory in
            try Data([0x01]).write(to: directory.appendingPathComponent("00000000.jpg"))
            #expect(SpiderInfoFile.getDownloadedPages(in: directory, totalPages: 0).isEmpty)
            #expect(SpiderInfoFile.getDownloadedPages(in: directory, totalPages: -1).isEmpty)
            #expect(SpiderInfoFile.getLocalImageURL(in: directory, pageIndex: -1) == nil)
            #expect(SpiderInfoFile.getLocalImageURL(in: directory, pageIndex: Int.max) == nil)
        }
    }

    @Test func fullMetadataReopensWhileHeaderReadLeavesPageTokensOnDisk() throws {
        try withScratchDirectory { directory in
            try SpiderInfoFile.write(
                SpiderInfo(startPage: 16, gid: 109, token: "abcd", pages: 24,
                           previewPages: 3, previewPerPage: 8, pTokenMap: [16: "p16", 17: "failed", 18: "p18"]),
                to: directory
            )
            let metadataURL = directory.appendingPathComponent(".ehviewer")
            let before = try Data(contentsOf: metadataURL)

            let header = try #require(SpiderInfoFile.readHeader(from: directory))
            #expect(header.startPage == 16)
            #expect(header.gid == 109)
            #expect(header.token == "abcd")
            #expect(header.pages == 24)
            #expect(header.previewPages == 3)
            #expect(header.previewPerPage == 8)
            #expect(header.pTokenMap.isEmpty)

            let full = try #require(SpiderInfoFile.read(from: directory))
            #expect(full.pTokenMap == [16: "p16", 18: "p18"])
            #expect(try Data(contentsOf: metadataURL) == before)
        }
    }

    @Test func missingTruncatedAndOversizedMetadataCannotLoad() throws {
        try withScratchDirectory { directory in
            let metadataURL = directory.appendingPathComponent(".ehviewer")
            #expect(SpiderInfoFile.read(from: directory) == nil)
            try Data("VERSION2\n00000001\n".utf8).write(to: metadataURL)
            #expect(SpiderInfoFile.read(from: directory) == nil)
            #expect(SpiderInfoFile.readHeader(from: directory) == nil)
            try SpiderInfoFile.write(SpiderInfo(startPage: 1, gid: 11, token: "abcd", pages: 4), to: directory)
            let file = try FileHandle(forWritingTo: metadataURL)
            defer { try? file.close() }
            try file.truncate(atOffset: UInt64(SpiderInfoFile.maxFileSize) + 1)
            #expect(SpiderInfoFile.read(from: directory) == nil)
            #expect(SpiderInfoFile.readHeader(from: directory) == nil)
        }
    }
}
