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

        let first = try await GalleryArchiveExporter.exportZip(from: left, title: "Same title", stagingRoot: staging)
        let before = try Data(contentsOf: first)
        let second = try await GalleryArchiveExporter.exportZip(from: right, title: "Same title", stagingRoot: staging)
        let after = try Data(contentsOf: first)
        let other = try Data(contentsOf: second)
        #expect(first.lastPathComponent == second.lastPathComponent)
        #expect(first != second)
        #expect(before.starts(with: [0x50, 0x4b]))
        #expect(before == after)
        #expect(before != other)
    }
}
