import Foundation
import Testing
import UniformTypeIdentifiers
@testable import ehviewer_apple

@MainActor
struct ReaderPageExportTests {
    private static let gif = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")!

    @Test func exportPreservesEncodedBytesAndUsesDetectedFormat() throws {
        let source = try #require(ReaderPageExport(bytes: Self.gif, gid: 43, page: 2))
        #expect(source.filename == "43-3.gif")
        #expect(source.type == .gif)
        #expect(source.bytes == Self.gif)
        #expect(ReaderPageExportDocument(source).bytes == Self.gif)
    }

    @Test func rejectNonImageAndUseDistinctRequestIdentities() throws {
        #expect(ReaderPageExport(bytes: Data("<html>error</html>".utf8), gid: 43, page: 2) == nil)
        #expect(ReaderPageExport(bytes: Self.gif, gid: 43, page: -1) == nil)
        let first = try #require(ReaderPageExport(bytes: Self.gif, gid: 43, page: 2))
        let second = try #require(ReaderPageExport(bytes: Self.gif, gid: 43, page: 2))
        #expect(first.filename == second.filename)
        #expect(first.id != second.id)
    }

    @Test func offlineFileLookupKeepsBytesAndRejectsExternalSymlink() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("download", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = directory.appendingPathComponent("00000001.jpg")
        let second = directory.appendingPathComponent("00000002.jpg")
        let outside = root.appendingPathComponent("unrelated.gif")
        try Self.gif.write(to: first)
        try Self.gif.write(to: outside)
        try FileManager.default.createSymbolicLink(at: second, withDestinationURL: outside)

        let data = await ReaderPageExport.readLocalPage(in: directory) { _ in first }
        #expect(data == Self.gif) // .jpg suffix is intentionally misleading.
        let denied = await ReaderPageExport.readLocalPage(in: directory) { _ in second }
        #expect(denied == nil)
    }

    @Test func modelLookupsStayOnTheRequestedPageAndNeverFetchARemoteURL() async throws {
        let model = ReaderViewModel()
        model.gid = 43
        model.totalPages = 3
        // This URL is deliberately not contacted even when the encoded cache is absent.
        model.imageURLs[2] = "https://example.invalid/fixture.jpg"
        model.cachedImages[2] = PlatformImage()
        let data = Self.gif
        let result = await model.pageExport(2) { gallery, index in
            #expect(gallery == 43)
            #expect(index == 2)
            return data
        }
        #expect(result?.bytes == data)
        let unavailable = await model.pageExport(2, cacheLookup: { _, _ in nil })
        #expect(unavailable == nil)
        let outOfRange = await model.pageExport(3, cacheLookup: { _, _ in
            Issue.record("Out-of-range export attempted a cache lookup.")
            return data
        })
        #expect(outOfRange == nil)
    }

    @Test func discardsCacheReadIfReaderChangedGalleryDuringLookup() async {
        let model = ReaderViewModel()
        model.gid = 43
        model.totalPages = 3
        let data = Self.gif
        let result = await model.pageExport(2) { _, _ in
            await MainActor.run { model.gid = 44 }
            return data
        }
        #expect(result == nil)
    }
}
