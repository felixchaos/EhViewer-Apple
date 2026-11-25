import Foundation
import ImageIO
import SQLite3
import Testing
import EhSpider
@testable import EhDatabase
@testable import EhDownload

@Suite struct OfflineGalleryFolderImportTests {
    @Test func importRetainsPageBytesNaturalOrderAndSurvivesReopen() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = fixture.source.appendingPathComponent("page 2.png")
        let last = fixture.source.appendingPathComponent("page 10.png")
        try image(width: 2, to: first)
        try image(width: 10, to: last)
        try Data("ignore".utf8).write(to: fixture.source.appendingPathComponent("instructions.txt"))
        try Data("ignore".utf8).write(to: fixture.source.appendingPathComponent(".hidden.png"))
        let database = try EhDatabase(storageURL: fixture.database)
        let importer = DownloadManager(database: database, directory: fixture.library)
        let gallery = try await importer.importImageFolder(fixture.source)
        #expect(OfflineGallery.isImported(gid: gallery.gid, token: gallery.token))
        #expect(gallery.pages == 2)
        let reopened = DownloadManager(database: try EhDatabase(storageURL: fixture.database),
                                       directory: fixture.library)
        let task = try #require(await reopened.getAllTasks().first)
        #expect(task.state == DownloadManager.stateFinish)
        #expect(task.downloadedPages == 2)
        #expect(task.gallery.gid == gallery.gid)
        let directory = try #require(await reopened.localGalleryDirectory(gid: gallery.gid))
        let page0 = try #require(SpiderInfoFile.getLocalImageURL(in: directory, pageIndex: 0))
        let page1 = try #require(SpiderInfoFile.getLocalImageURL(in: directory, pageIndex: 1))
        #expect(try Data(contentsOf: first) == Data(contentsOf: page0))
        #expect(try Data(contentsOf: last) == Data(contentsOf: page1))
        let header = try #require(SpiderInfoFile.readHeader(from: directory))
        #expect(OfflineGallery.canRestore(header, from: directory))
        await reopened.pauseDownload(gid: gallery.gid)
        await reopened.resumeDownload(gid: gallery.gid)
        #expect(await reopened.getTaskState(gid: gallery.gid) == DownloadManager.stateFinish)
        #expect(try database.getDownload(gid: gallery.gid)?.state == DownloadManager.stateFinish)

        // Explicit reimport is separate; it cannot overwrite installed data or source files.
        let duplicate = try await reopened.importImageFolder(fixture.source)
        #expect(duplicate.gid != gallery.gid)
        #expect(await reopened.getAllTasks().count == 2)
        #expect(try Data(contentsOf: first) == Data(contentsOf: page0))

        await reopened.deleteDownload(gid: gallery.gid)
        #expect(try database.getDownload(gid: gallery.gid) == nil)
        #expect(try await reopened.restoreOfflineGallery(header, from: directory))
        #expect(await reopened.getAllTasks().count == 2)
        #expect(try Data(contentsOf: first) == Data(contentsOf: page0))
        #expect(try await !reopened.restoreOfflineGallery(header, from: directory))
    }

    @Test func damagedImageRollsBackPreviouslyStagedPage() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try image(width: 2, to: fixture.source.appendingPathComponent("page 1.png"))
        let invalid = fixture.source.appendingPathComponent("page 2.png")
        let invalidData = Data("not an image".utf8)
        try invalidData.write(to: invalid)
        let database = try EhDatabase(storageURL: fixture.database)
        let importer = DownloadManager(database: database, directory: fixture.library)
        await #expect(throws: OfflineGalleryImportError.invalidImage) {
            _ = try await importer.importImageFolder(fixture.source)
        }
        #expect(try database.getAllDownloads().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.library.path).isEmpty)
        #expect(try Data(contentsOf: invalid) == invalidData)
    }

    @Test func imageNamedSymlinkIsRejectedAndExternalBytesUntouched() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let external = fixture.root.appendingPathComponent("outside.png")
        try image(width: 3, to: external)
        let original = try Data(contentsOf: external)
        try FileManager.default.createSymbolicLink(at: fixture.source.appendingPathComponent("page.png"),
                                                   withDestinationURL: external)
        let database = try EhDatabase(storageURL: fixture.database)
        let importer = DownloadManager(database: database, directory: fixture.library)
        await #expect(throws: OfflineGalleryImportError.unsafeFile) {
            _ = try await importer.importImageFolder(fixture.source)
        }
        #expect(try database.getAllDownloads().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.library.path).isEmpty)
        #expect(try Data(contentsOf: external) == original)
    }

    @Test func rejectsLargeFilesBeforeCopyingAndDoesNotAlterSource() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let large = fixture.source.appendingPathComponent("oversized.png")
        try Data().write(to: large)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: 64_000_001)
        try handle.close()
        let database = try EhDatabase(storageURL: fixture.database)
        let importer = DownloadManager(database: database, directory: fixture.library)
        await #expect(throws: OfflineGalleryImportError.tooLarge) {
            _ = try await importer.importImageFolder(fixture.source)
        }
        #expect(try database.getAllDownloads().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.library.path).isEmpty)
        #expect(try large.resourceValues(forKeys: [.fileSizeKey]).fileSize == 64_000_001)
    }

    @Test func databaseFailureRollsBackPublishedFolder() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try image(width: 2, to: fixture.source.appendingPathComponent("page.png"))
        let database = try EhDatabase(storageURL: fixture.database)
        var connection: OpaquePointer?
        try #require(sqlite3_open(fixture.database.path, &connection) == SQLITE_OK)
        defer { sqlite3_close(connection) }
        try #require(sqlite3_exec(connection, """
            CREATE TRIGGER refuse_offline_import BEFORE INSERT ON download
            WHEN NEW.gid < 0 BEGIN SELECT RAISE(ABORT, 'Synthetic disk registration failure'); END;
            """, nil, nil, nil) == SQLITE_OK)
        let importer = DownloadManager(database: database, directory: fixture.library)
        do {
            _ = try await importer.importImageFolder(fixture.source)
            Issue.record("The database trigger should refuse registration.")
        } catch {
            #expect(String(describing: error).contains("Synthetic disk registration failure"))
        }
        #expect(try database.getAllDownloads().isEmpty)
        #expect(await importer.getAllTasks().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.library.path).isEmpty)
    }

    @Test func cancellationAndDegradedLibraryDoNotPublish() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try image(width: 2, to: fixture.source.appendingPathComponent("page.png"))
        let database = try EhDatabase(storageURL: fixture.database)
        let importer = DownloadManager(database: database, directory: fixture.library)
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await importer.importImageFolder(fixture.source)
        }
        await #expect(throws: CancellationError.self) { _ = try await operation.value }
        #expect(try database.getAllDownloads().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.library.path).isEmpty)

        let degraded = try EhDatabase(inMemory: true)
        let unavailable = DownloadManager(database: degraded, directory: fixture.library)
        await #expect(throws: OfflineGalleryImportError.unavailable) {
            _ = try await unavailable.importImageFolder(fixture.source)
        }
        #expect(try degraded.getAllDownloads().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.library.path).isEmpty)
    }

    private func makeFixture() throws -> (root: URL, source: URL, library: URL, database: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("Neutral pages", isDirectory: true)
        let library = root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        return (root, source, library, root.appendingPathComponent("test.sqlite"))
    }

    private func image(width: Int, to output: URL) throws {
        let context = try #require(CGContext(data: nil, width: width, height: 1, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: 1))
        let image = try #require(context.makeImage())
        let encoder = try #require(CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(encoder, image, nil)
        try #require(CGImageDestinationFinalize(encoder))
    }
}
