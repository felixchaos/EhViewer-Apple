import Foundation
import Testing
@testable import ehviewer_apple

@MainActor
struct GalleryArchiveExporterTests {
    @Test func sameTitleExportsRemainIndependentAndPreservePriorBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let left = root.appendingPathComponent("123-first", isDirectory: true)
        let right = root.appendingPathComponent("124-second", isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        for (dir, value) in [(left, UInt8(7)), (right, UInt8(53))] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: value, count: 32).write(to: dir.appendingPathComponent("00000001.png"))
        }

        for name in [".ehviewer", "extra.txt", "cover.png", "00000003.png"] {
            try Data("synthetic non-page bytes".utf8).write(to: left.appendingPathComponent(name))
        }

        try Data(repeating: 17, count: 32).write(to: left.appendingPathComponent("00000002.jpg"))

        let first = try await GalleryArchiveExporter.exportZip(from: left, pageCount: 2, title: "Same title", stagingRoot: staging)
        let before = try Data(contentsOf: first)
        let second = try await GalleryArchiveExporter.exportZip(from: right, pageCount: 1, title: "Same title", stagingRoot: staging)
        let after = try Data(contentsOf: first)
        let other = try Data(contentsOf: second)
        #expect(first.lastPathComponent == second.lastPathComponent)
        #expect(first != second)
        #expect(before.starts(with: [0x50, 0x4b]))
        #expect(before.range(of: Data("00000001.png".utf8)) != nil)
        #expect(before.range(of: Data("00000002.jpg".utf8)) != nil)
        for name in [".ehviewer", "extra.txt", "cover.png", "00000003.png", "__MACOSX"] {
            #expect(before.range(of: Data(name.utf8)) == nil)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: first.deletingLastPathComponent().path) == [first.lastPathComponent])
        #expect(before == after)
        #expect(before != other)
    }
}
