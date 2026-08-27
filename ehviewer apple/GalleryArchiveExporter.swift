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
            case .notDownloaded: return "这本还没有下载到本地"
            case .empty:         return "下载目录里没有图片"
            case .zipFailed(let m): return "打包失败：\(m)"
            }
        }
    }

    /// 打包指定画廊，返回临时 zip 的位置
    ///
    /// - Note: 结果放在临时目录，分享完由系统回收；同一本重复导出会覆盖上一次的文件。
    static func exportZip(for gallery: GalleryInfo) async throws -> URL {
        guard let dir = await DownloadManager.shared.localGalleryDirectory(gid: gallery.gid) else {
            throw ExportError.notDownloaded
        }

        let images = imageCount(in: dir)
        guard images > 0 else { throw ExportError.empty }

        let name = DownloadManager.sanitizeFilename(gallery.bestTitle)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name).zip")
        try? FileManager.default.removeItem(at: destination)

        // NSFileCoordinator 的打包是同步阻塞的，挪到后台线程
        return try await withCheckedThrowingContinuation { continuation in
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
                    continuation.resume(returning: destination)
                }
            }
        }
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
