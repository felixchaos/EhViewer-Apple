import Foundation
import ImageIO
import Darwin
import EhSpider
import EhModels

/// A reading entry made from files, never an online gallery identity.
public enum OfflineGallery {
    static let token = "offline-import-v1"
    public static func isImported(gid: Int64, token: String) -> Bool {
        gid < 0 && token == Self.token
    }

    /// These user-owned copies can be re-registered after "keep files".
    public static func canRestore(_ info: SpiderInfo, from directory: URL) -> Bool {
        guard isImported(gid: info.gid, token: info.token), (1...maximumPages).contains(info.pages),
              (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
              directory.lastPathComponent.hasPrefix("\(info.gid)-")
        else { return false }
        return (0..<info.pages).allSatisfy { page in
            guard let image = SpiderInfoFile.getLocalImageURL(in: directory, pageIndex: page) else { return false }
            return (try? image.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false
        }
    }

    static let maximumPages = 2_000
}

public enum OfflineGalleryImportError: LocalizedError {
    case noImages, tooLarge, unsafeFile, invalidImage, unavailable, failed, invalidArchive, unsupportedArchive

    public var errorDescription: String? {
        switch self {
        case .noImages: "这个文件夹没有可导入的图片。请选择直接存放图片的文件夹，或包含图片的归档。"
        case .tooLarge: "超过导入限制：2,000 页、单个文件 64 MB、解压后合计 4 GB、压缩包 1 GB 或单页 4,800 万像素。"
        case .unsafeFile: "无法安全读取文件夹中的图片。请确定文件已下载到本机，并且不是符号链接。"
        case .invalidImage: "至少一张图片已损坏或格式不受支持。原文件没有改动。"
        case .unavailable: "应用的本地下载库不可用，未导入任何图片。"
        case .failed: "未能保存到下载库。请检查可用空间后再试。"
        case .invalidArchive: "压缩包损坏或内容不一致，没有导入任何图片。"
        case .unsupportedArchive: "仅支持普通 ZIP/CBZ。不支持加密、分卷或 ZIP64 压缩包。"
        }
    }
}

enum OfflineGalleryFolderImport {
    struct Stage: Sendable {
        let root: URL
        let directory: URL
        let title: String
        let pages: Int
    }

    private static let extensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp"]
    private static let types: [String: String] = [
        "public.jpeg": ".jpg", "public.png": ".png", "com.compuserve.gif": ".gif", "org.webmproject.webp": ".webp"
    ]
    private static let maximumEntries = 20_000
    private static let maximumPageBytes = 64_000_000
    private static let maximumGalleryBytes = 4_000_000_000
    private static let maximumPagePixels = 48_000_000

    /// Security scope and coordination must remain live for enumeration and all reads.
    static func stage(folder: URL, under root: URL) throws -> Stage {
        try coordinatedRead(folder) { try copyFolder($0, under: root) }
    }

    static func stage(archive: URL, under root: URL) throws -> Stage {
        try coordinatedRead(archive) { selected in
            guard ["zip", "cbz"].contains(selected.pathExtension.lowercased())
            else { throw OfflineGalleryImportError.unsupportedArchive }
            let zip = try OfflineGalleryZIP(selected)
            let entries = try zip.entries(maxEntryBytes: maximumPageBytes, maxExpandedBytes: maximumGalleryBytes)
                .sorted { naturalOrder($0.name, $1.name) }
            let isPage: (OfflineGalleryZIP.Entry) -> Bool = { entry in
                !entry.directory && !entry.name.split(separator: "/").contains {
                    $0.hasPrefix(".") || $0 == "__MACOSX"
                } && extensions.contains((entry.name as NSString).pathExtension.lowercased())
            }
            let pages = entries.filter(isPage).count
            guard pages > 0 else { throw OfflineGalleryImportError.noImages }
            guard pages <= OfflineGallery.maximumPages else { throw OfflineGalleryImportError.tooLarge }
            // Archive title is derived from its selected filename; entry names are
            // used only to classify/sort and can never name an output file.
            return try buildStage(root: root, name: selected.deletingPathExtension().lastPathComponent, pages: pages) { staging in
                var page = 0
                for entry in entries {
                    try Task.checkCancellation()
                    if !isPage(entry) {
                        try zip.stream(entry, writingTo: nil)
                        continue
                    }
                    try autoreleasepool {
                        let scratch = staging.appendingPathComponent(".page")
                        guard FileManager.default.createFile(atPath: scratch.path, contents: nil,
                                                             attributes: [.posixPermissions: 0o600])
                        else { throw OfflineGalleryImportError.failed }
                        let file = try FileHandle(forWritingTo: scratch)
                        do {
                            try zip.stream(entry, writingTo: file)
                            try file.close()
                        } catch {
                            try? file.close()
                            throw error
                        }
                        try finishPage(scratch: scratch, staging: staging, index: page)
                        page += 1
                    }
                }
            }
        }
    }

    private static func coordinatedRead(_ location: URL, action: (URL) throws -> Stage) throws -> Stage {
        try Task.checkCancellation()
        guard location.startAccessingSecurityScopedResource() else {
            return try action(location)
        }
        defer { location.stopAccessingSecurityScopedResource() }
        var failure: NSError?
        var result: Result<Stage, Error>?
        NSFileCoordinator().coordinate(readingItemAt: location, options: [], error: &failure) { coordinated in
            result = Result { try action(coordinated) }
        }
        if let result { return try result.get() }
        if let failure { throw failure }
        throw OfflineGalleryImportError.unsafeFile
    }

    private static func copyFolder(_ folder: URL, under root: URL) throws -> Stage {
        let fm = FileManager.default
        let folderPath = folder.standardizedFileURL.path
        let resolvedFolder = folder.standardizedFileURL.resolvingSymlinksInPath()
        guard folderPath != root.path, resolvedFolder.path != root.path,
              !resolvedFolder.path.hasPrefix(root.path + "/"),
              try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true
        else { throw OfflineGalleryImportError.unsafeFile }

        let directoryFD = folder.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard directoryFD >= 0 else { throw OfflineGalleryImportError.unsafeFile }
        defer { Darwin.close(directoryFD) }

        let contents = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        guard contents.count <= maximumEntries else { throw OfflineGalleryImportError.tooLarge }
        let images = contents.filter { extensions.contains($0.pathExtension.lowercased()) }.sorted {
            naturalOrder($0.lastPathComponent, $1.lastPathComponent)
        }
        guard !images.isEmpty else { throw OfflineGalleryImportError.noImages }
        guard images.count <= OfflineGallery.maximumPages else { throw OfflineGalleryImportError.tooLarge }
        return try buildStage(root: root, name: folder.lastPathComponent, pages: images.count) { staging in
            var total = 0
            for (index, image) in images.enumerated() {
                try Task.checkCancellation()
                try autoreleasepool {
                    let scratch = staging.appendingPathComponent(".page")
                    total += try copyImage(image.lastPathComponent, from: directoryFD, to: scratch,
                                           remaining: maximumGalleryBytes - total)
                    try finishPage(scratch: scratch, staging: staging, index: index)
                }
            }
        }
    }

    private static func buildStage(root: URL, name: String, pages: Int,
                                   write: (URL) throws -> Void) throws -> Stage {
        // Bound by UTF-8 bytes before incorporating the title into the on-disk directory name.
        let originalTitle = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var title = ""
        var titleBytes = 0
        for character in originalTitle {
            let bytes = String(character).utf8.count
            if titleBytes + bytes > 128 { break }
            title.append(character)
            titleBytes += bytes
        }
        if title.isEmpty { title = "本地画廊" }
        let fm = FileManager.default
        let staging = root.appendingPathComponent(".offline-stage-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        var prepared = false
        defer { if !prepared { try? fm.removeItem(at: staging) } }
        try write(staging)
        try Task.checkCancellation()
        prepared = true
        return Stage(root: root, directory: staging, title: title, pages: pages)
    }

    private static func finishPage(scratch: URL, staging: URL, index: Int) throws {
        let ext = try validatedExtension(for: scratch)
        try FileManager.default.moveItem(at: scratch, to: staging.appendingPathComponent(
            SpiderDen.generateImageFilename(index: index, extension: ext)
        ))
    }

    /// Natural numeric ordering with fixed locale and a literal tie-breaker.
    static func naturalOrder(_ lhs: String, _ rhs: String) -> Bool {
        let result = lhs.compare(rhs, options: [.numeric, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        if result != .orderedSame { return result == .orderedAscending }
        return lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    /// Names are resolved relative to the selected directory descriptor. A link, FIFO,
    /// directory, replaced path, or a file growing past the cap cannot escape the import.
    private static func copyImage(_ name: String, from parent: Int32, to destination: URL, remaining: Int) throws -> Int {
        let fd = name.withCString { Darwin.openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard fd >= 0 else { throw OfflineGalleryImportError.unsafeFile }
        let source = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? source.close() }
        var attributes = stat()
        guard fstat(fd, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG else {
            throw OfflineGalleryImportError.unsafeFile
        }
        let limit = min(maximumPageBytes, remaining)
        guard attributes.st_size > 0 else { throw OfflineGalleryImportError.invalidImage }
        guard attributes.st_size <= Int64(limit) else { throw OfflineGalleryImportError.tooLarge }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600])
        else { throw OfflineGalleryImportError.failed }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var written = 0
        while let chunk = try source.read(upToCount: 256 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            guard chunk.count <= limit - written else { throw OfflineGalleryImportError.tooLarge }
            try output.write(contentsOf: chunk)
            written += chunk.count
        }
        guard written == attributes.st_size else { throw OfflineGalleryImportError.unsafeFile }
        return written
    }

    private static func validatedExtension(for url: URL) throws -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let rawType = CGImageSourceGetType(source), let ext = types[rawType as String],
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { throw OfflineGalleryImportError.invalidImage }
        guard width <= maximumPagePixels / height else { throw OfflineGalleryImportError.tooLarge }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) != nil,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
        else { throw OfflineGalleryImportError.invalidImage }
        return ext
    }
}
