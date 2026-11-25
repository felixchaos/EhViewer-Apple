import Foundation
import ImageIO
import Testing
import zlib
import EhSpider
@testable import EhDatabase
@testable import EhDownload

@Suite struct OfflineGalleryArchiveImportTests {
    @Test func importsZIPAndCBZStoredAndDeflatedWithNaturalOrderAndByteEquality() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try png(width: 2, in: fixture.root)
        let second = try png(width: 10, in: fixture.root)
        let visible = [
            Item("book/10.png", second, method: 8, descriptor: true),
            Item("book/2.png", first),
        ]
        // Multibuffer deflate verification includes non-page entries.
        let metadata = Item("notes.txt", Data(repeating: 0x35, count: 180_000), method: 8)
        let payload = zip([Item("book/", Data(), attributes: 0x41ed0010)] + visible + [metadata])
        for ext in ["zip", "cbz"] {
            let source = fixture.root.appendingPathComponent("Neutral archive.\(ext)")
            try payload.write(to: source)
            let gallery = try await fixture.manager.importImageArchive(source)
            #expect(gallery.pages == 2)
            #expect(gallery.title == "Neutral archive")
            let directory = try #require(await fixture.manager.localGalleryDirectory(gid: gallery.gid))
            let p0 = try #require(SpiderInfoFile.getLocalImageURL(in: directory, pageIndex: 0))
            let p1 = try #require(SpiderInfoFile.getLocalImageURL(in: directory, pageIndex: 1))
            #expect(try Data(contentsOf: p0) == first)
            #expect(try Data(contentsOf: p1) == second)
            #expect(try Data(contentsOf: source) == payload)
        }
        #expect(await fixture.manager.getAllTasks().count == 2)
    }

    @Test func rejectsInconsistentEntryMetadataAndNeverPublishesPartialArchive() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pixels = try png(width: 3, in: fixture.root)
        let valid = Item("1.png", pixels)
        var wrongCRC = Item("2.png", pixels, method: 8, descriptor: true)
        wrongCRC.claimedCRC = 0
        var wrongSize = Item("2.png", pixels, method: 8)
        wrongSize.claimedExpanded = UInt32(pixels.count - 1)
        var invalidHeader = Item("2.png", pixels)
        invalidHeader.localName = "3.png"
        var trailingStream = Item("2.png", pixels, method: 8)
        trailingStream.afterDeflateBytes = Data([0])
        let cases = [
            zip([valid, wrongCRC]),
            zip([valid, wrongSize]),
            zip([valid, invalidHeader]),
            zip([valid, trailingStream]),
            zip([valid], declaredCount: 2),
            Data(zip([valid]).dropLast()),
        ]
        for payload in cases {
            try await validateRefusal(payload, .invalidArchive, fixture)
        }
    }

    @Test func archivePolicyRejectsUnsupportedEntryTypesAndContainers() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pixels = try png(width: 3, in: fixture.root)
        let valid = Item("1.png", pixels)
        let cases: [(Data, OfflineGalleryImportError)] = [
            (zip([Item("1.png", pixels, attributes: 0xa1ff0000)]), .unsafeFile),
            (zip([valid, Item("1.PNG", pixels)]), .unsafeFile),
            (zip([Item("1.png", pixels, flags: 1)]), .unsupportedArchive),
            (zip([Item("1.png", pixels, needed: 45)]), .unsupportedArchive),
            (zip([valid], disk: 1), .unsupportedArchive),
            (zip([Item("1.png", pixels, claimedExpanded: 64_000_001)]), .tooLarge),
            (zip([Item("notes.txt", Data("notes".utf8))]), .noImages),
            (Data("this is not an archive".utf8), .invalidArchive),
        ]
        for (payload, error) in cases {
            try await validateRefusal(payload, error, fixture)
        }
    }

    @Test func refusesUnsupportedExtensionAndCancellation() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let unsupported = fixture.root.appendingPathComponent("sample.rar")
        let pixels = try png(width: 3, in: fixture.root)
        let payload = zip([Item("1.png", pixels)])
        try payload.write(to: unsupported)
        await #expect(throws: OfflineGalleryImportError.unsupportedArchive) {
            _ = try await fixture.manager.importImageArchive(unsupported)
        }
        let supported = fixture.root.appendingPathComponent("cancel.zip")
        try payload.write(to: supported)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.manager.importImageArchive(supported)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await fixture.manager.getAllTasks().isEmpty)
    }

    private struct Fixture {
        let root: URL
        let library: URL
        let manager: DownloadManager
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = try EhDatabase(storageURL: root.appendingPathComponent("neutral.sqlite"))
        return Fixture(root: root, library: library, manager: DownloadManager(database: db, directory: library))
    }

    private func validateRefusal(_ payload: Data, _ expected: OfflineGalleryImportError,
                                 _ fixture: Fixture) async throws {
        let source = fixture.root.appendingPathComponent(UUID().uuidString + ".cbz")
        try payload.write(to: source)
        await #expect(throws: expected) { _ = try await fixture.manager.importImageArchive(source) }
        #expect(await fixture.manager.getAllTasks().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.library.path).isEmpty)
        #expect(try Data(contentsOf: source) == payload)
    }

    private func png(width: Int, in root: URL) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: 1, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.3, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: 1))
        let image = try #require(context.makeImage())
        let file = root.appendingPathComponent(UUID().uuidString + ".png")
        let encoder = try #require(CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(encoder, image, nil)
        try #require(CGImageDestinationFinalize(encoder))
        return try Data(contentsOf: file)
    }

    private struct Item {
        let name: String
        let data: Data
        var method: UInt16
        var descriptor: Bool
        var attributes: UInt32
        var flags: UInt16
        var needed: UInt16
        var claimedExpanded: UInt32?
        var claimedCRC: UInt32?
        var localName: String?
        var afterDeflateBytes = Data()

        init(_ name: String, _ data: Data, method: UInt16 = 0, descriptor: Bool = false,
             attributes: UInt32 = 0, flags: UInt16 = 0, needed: UInt16 = 20,
             claimedExpanded: UInt32? = nil) {
            self.name = name
            self.data = data
            self.method = method
            self.descriptor = descriptor
            self.attributes = attributes
            self.flags = flags
            self.needed = needed
            self.claimedExpanded = claimedExpanded
        }
    }

    private func zip(_ entries: [Item], declaredCount: UInt16? = nil, disk: UInt16 = 0) -> Data {
        var bodies = Data()
        var catalog = Data()
        for entry in entries {
            let centralName = Data(entry.name.utf8)
            let filename = Data((entry.localName ?? entry.name).utf8)
            let bytes = (entry.method == 8 ? deflateBlocks(entry.data) : entry.data) + entry.afterDeflateBytes
            let flags = entry.flags | (entry.descriptor ? 8 : 0)
            let crc = entry.claimedCRC ?? entry.data.withUnsafeBytes { raw in
                UInt32(crc32(0, raw.bindMemory(to: UInt8.self).baseAddress, UInt32(raw.count)))
            }
            let expand = entry.claimedExpanded ?? UInt32(entry.data.count)
            let offset = UInt32(bodies.count)
            bodies.le32(0x04034b50)
            for x in [entry.needed, flags, entry.method, 0, 0] { bodies.le16(x) }
            for x in [crc, UInt32(bytes.count), expand] { bodies.le32(entry.descriptor ? 0 : x) }
            bodies.le16(UInt16(filename.count))
            bodies.le16(0)
            bodies += filename + bytes
            if entry.descriptor {
                for x: UInt32 in [0x08074b50, crc, UInt32(bytes.count), expand] { bodies.le32(x) }
            }

            catalog.le32(0x02014b50)
            for x: UInt16 in [0x0314, entry.needed, flags, entry.method, 0, 0] { catalog.le16(x) }
            for x in [crc, UInt32(bytes.count), expand] { catalog.le32(x) }
            for x: UInt16 in [UInt16(centralName.count), 0, 0, 0, 0] { catalog.le16(x) }
            catalog.le32(entry.attributes)
            catalog.le32(offset)
            catalog += centralName
        }
        let start = UInt32(bodies.count)
        bodies += catalog
        bodies.le32(0x06054b50)
        for x in [disk, disk, declaredCount ?? UInt16(entries.count), declaredCount ?? UInt16(entries.count)] {
            bodies.le16(x)
        }
        bodies.le32(UInt32(catalog.count))
        bodies.le32(start)
        bodies.le16(0)
        return bodies
    }

    private func deflateBlocks(_ data: Data) -> Data {
        var output = Data()
        var offset = 0
        repeat {
            let count = min(31_000, data.count - offset)
            output.append(offset + count == data.count ? 1 : 0)
            output.le16(UInt16(count))
            output.le16(~UInt16(count))
            output += data[offset..<(offset + count)]
            offset += count
        } while offset < data.count
        return output
    }
}

private extension Data {
    mutating func le16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }
    mutating func le32(_ value: UInt32) {
        le16(UInt16(truncatingIfNeeded: value))
        le16(UInt16(truncatingIfNeeded: value >> 16))
    }
}
