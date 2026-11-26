//
//  GalleryArchiveExporter.swift
//  ehviewer apple
//
//  把已下载的画廊打包成 zip 分享 (issue #2)
//
//  用 NSFileCoordinator 的 `.forUploading` 选项：系统会为目录生成一份 zip 副本，
//  不需要引入第三方压缩库，也不需要自己实现 zip 格式。
//

import Darwin
import Foundation
import EhModels
import EhDownload
import EhSpider

nonisolated enum GalleryArchiveExporter {

    enum ExportError: LocalizedError {
        case notDownloaded
        case empty
        case zipFailed(String)

        var errorDescription: String? {
            switch self {
            case .notDownloaded: return "画廊未下载"
            case .empty:         return "下载目录无图片"
            case .zipFailed(let m): return "打包失败：\(m)"
            }
        }
    }

    /// Retain independent snapshots even when their suggested filenames match.
    static func exportZip(for gallery: GalleryInfo) async throws -> URL {
        guard let dir = await DownloadManager.shared.localGalleryDirectory(gid: gallery.gid) else {
            throw ExportError.notDownloaded
        }
        return try await exportZip(from: dir, pageCount: gallery.pages, title: gallery.bestTitle)
    }

    static func exportZip(
        from dir: URL, pageCount: Int, title: String,
        stagingRoot: URL = FileManager.default.temporaryDirectory.appendingPathComponent("EhViewerArchiveShare", isDirectory: true)
    ) async throws -> URL {
        guard pageCount > 0 else { throw ExportError.empty }
        try Task.checkCancellation()

        let folder = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = DownloadManager.sanitizeFilename(title)
        let destination = folder.appendingPathComponent("\(name).zip", isDirectory: false)
        var keepSnapshot = false
        defer {
            if !keepSnapshot { try? FileManager.default.removeItem(at: folder) }
        }

        // NSFileCoordinator 的打包是同步阻塞的，挪到后台线程
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try createArchive(from: dir, pageCount: pageCount, in: folder, destination: destination)
                })
            }
        }
        try Task.checkCancellation()
        keepSnapshot = true
        return destination
    }

    private static func createArchive(from dir: URL, pageCount: Int, in folder: URL, destination: URL) throws {
        // Stage only numbered reader pages, never the download directory or sidecars.
        let pages = folder.appendingPathComponent("Pages", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: pages, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: pages) }

        var hasPages = false
        for index in 0..<pageCount {
            guard let source = SpiderDen.findImageFile(in: dir, index: index),
                  try source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false
            else { continue }
            try copyPageBytes(from: source, to: pages.appendingPathComponent(source.lastPathComponent))
            hasPages = true
        }
        guard hasPages else { throw ExportError.empty }

        var coordinatorError: NSError?
        var thrown: Error?
        NSFileCoordinator().coordinate(
            readingItemAt: pages, options: [.forUploading], error: &coordinatorError
        ) { archive in
            // The system removes its temporary ZIP when the coordinator callback finishes.
            do { try fm.copyItem(at: archive, to: destination) }
            catch { thrown = error }
        }
        if let coordinatorError { throw ExportError.zipFailed(coordinatorError.localizedDescription) }
        if let thrown { throw ExportError.zipFailed(thrown.localizedDescription) }
    }

    /// Preserve the original encoded image, but not filesystem metadata or resource forks.
    private static func copyPageBytes(from source: URL, to destination: URL) throws {
        try source.withUnsafeFileSystemRepresentation { sourcePath in
            try destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { throw ExportError.zipFailed("文件路径无效") }
                guard copyfile(sourcePath, destinationPath, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_EXCL | COPYFILE_NOFOLLOW_SRC)) == 0
                else { throw ExportError.zipFailed(String(cString: strerror(errno))) }
            }
        }
    }
}

/// sheet(item:) 的包装
struct ExportedArchive: Identifiable {
    let url: URL
    var id: String { url.path }
}
