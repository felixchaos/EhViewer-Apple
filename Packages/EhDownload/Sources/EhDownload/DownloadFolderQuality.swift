import Foundation
import EhSettings
import EhSpider

/// Records the download policy, not a claim about the dimensions of each image.
enum DownloadFolderQuality {
    private static let name = ".ehviewer-download-quality-v1"
    private static let extensions = Set(SpiderDen.supportedExtensions.map { String($0.dropFirst()) })

    private static func marker(_ directory: URL) -> URL {
        directory.appendingPathComponent(name)
    }

    static func recorded(in directory: URL) -> DownloadQuality? {
        let url = marker(directory)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, (1...32).contains(size),
              let value = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return DownloadQuality(rawValue: value)
    }

    static func containsMarker(in directory: URL) -> Bool {
        let url = marker(directory)
        return FileManager.default.fileExists(atPath: url.path)
            || (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    /// Inspect names rather than gallery.pages, which can be zero/stale in some lists.
    static func canUse(_ directory: URL, quality: DownloadQuality) throws -> Bool {
        if recorded(in: directory) == quality { return true }
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return true
        }
        return !files.contains { file in
            let index = file.deletingPathExtension().lastPathComponent.utf8
            return extensions.contains(file.pathExtension.lowercased())
                && index.count >= 8 && index.allSatisfy { (48...57).contains($0) }
        }
    }

    /// Must run before the transfer can read or write any numbered pages.
    static func prepare(_ directory: URL, quality: DownloadQuality?) throws -> Bool {
        if let quality {
            if recorded(in: directory) == quality { return true }
            guard try canUse(directory, quality: quality) else { return false }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try quality.rawValue.write(to: marker(directory), atomically: true, encoding: .utf8)
        } else if containsMarker(in: directory) {
            // Legacy/reader-sync tasks can use mixed sources. Never leave
            // stale policy metadata behind when such a task writes here.
            try FileManager.default.removeItem(at: marker(directory))
        }
        return true
    }
}
