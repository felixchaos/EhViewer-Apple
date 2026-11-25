//
//  GalleryArchiveExporter.swift
//  ehviewer apple
//
//  把已下载的画廊打包成 zip 分享 (issue #2)
//
//  用 NSFileCoordinator 的 `.forUploading` 选项：系统会为目录生成一份 zip 副本，
//  不需要引入第三方压缩库，也不需要自己实现 zip 格式。
//

import Foundation
import EhModels
import EhDownload

enum GalleryArchiveExporter {

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
        return try await exportZip(from: dir, title: gallery.bestTitle)
    }

    static func exportZip(
        from dir: URL, title: String,
        stagingRoot: URL = FileManager.default.temporaryDirectory.appendingPathComponent("EhViewerArchiveShare", isDirectory: true)
    ) async throws -> URL {
        guard imageCount(in: dir) > 0 else { throw ExportError.empty }
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
                var coordinatorError: NSError?
                var thrown: Error?

                NSFileCoordinator().coordinate(
                    readingItemAt: dir,
                    options: [.forUploading],
                    error: &coordinatorError
                ) { zippedURL in
                    // 回调作用域结束后系统会清掉这个临时 zip，必须先拷出来
                    do {
                        try FileManager.default.copyItem(at: zippedURL, to: destination)
                    } catch {
                        thrown = error
                    }
                }

                if let coordinatorError {
                    continuation.resume(throwing: ExportError.zipFailed(coordinatorError.localizedDescription))
                } else if let thrown {
                    continuation.resume(throwing: ExportError.zipFailed(thrown.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
        try Task.checkCancellation()
        keepSnapshot = true
        return destination
    }

    /// 目录里的图片数量 (只数支持的扩展名)
    private static func imageCount(in dir: URL) -> Int {
        let supported: Set<String> = ["jpg", "jpeg", "png", "gif", "webp"]
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.filter { supported.contains(($0 as NSString).pathExtension.lowercased()) }.count
    }
}

/// sheet(item:) 的包装
struct ExportedArchive: Identifiable {
    let url: URL
    var id: String { url.path }
}
