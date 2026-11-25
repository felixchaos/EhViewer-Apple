// Keep the actual page file separate from the downsampled reader bitmap.

import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
import Photos
import UIKit
#endif

nonisolated struct ReaderPageExport: Sendable, Identifiable {
    let id = UUID()
    let bytes: Data
    let type: UTType
    let basename: String
    let filename: String

    init?(bytes: Data, gid: Int64, page: Int) {
        guard page >= 0, page < Int.max,
              let source = CGImageSourceCreateWithData(bytes as CFData, [
                kCGImageSourceShouldCache: false
              ] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, width > 0,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, height > 0,
              let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier),
              let suffix = type.preferredFilenameExtension
        else { return nil }
        self.bytes = bytes
        self.type = type
        // The cached extension is not trusted (e.g. CDN or default .jpg).
        let stem = "\(gid)-\(page + 1)"
        basename = stem
        filename = "\(stem).\(suffix)"
    }

    nonisolated static func readLocalPage(
        in directory: URL, locate: @escaping @Sendable (URL) -> URL?
    ) async -> Data? {
        guard directory.isFileURL else { return nil }
        let read = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled,
                  let stored = locate(directory), stored.isFileURL
            else { return nil as Data? }
            let root = directory.resolvingSymlinksInPath().standardizedFileURL.path
            let file = stored.resolvingSymlinksInPath().standardizedFileURL
            // A page symlink must not expose another file outside this download.
            guard file.deletingLastPathComponent().path == root else { return nil }
            return try? Data(contentsOf: file)
        }
        return await withTaskCancellationHandler {
            await read.value
        } onCancel: {
            read.cancel()
        }
    }
}

nonisolated struct ReaderPageExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = {
        let identifiers = CGImageSourceCopyTypeIdentifiers() as? [String] ?? []
        return [.image] + identifiers.compactMap(UTType.init)
    }()
    let bytes: Data

    init(_ export: ReaderPageExport) {
        bytes = export.bytes
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        bytes = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: bytes)
    }
}

#if os(iOS)
/// Each provider owns a byte snapshot. Nothing is unlinked on dismissal or
/// aliased to another export while a share extension is still reading it.
struct ReaderPageShareSheet: UIViewControllerRepresentable {
    let export: ReaderPageExport

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let provider = NSItemProvider()
        provider.suggestedName = export.basename
        let bytes = export.bytes
        provider.registerDataRepresentation(forTypeIdentifier: export.type.identifier,
                                            visibility: .all) { receive in
            receive(bytes, nil)
            return nil
        }
        return UIActivityViewController(
            activityItemsConfiguration: UIActivityItemsConfiguration(itemProviders: [provider])
        )
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

@MainActor enum ReaderPagePhotos {
    static func save(_ export: ReaderPageExport) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            EhToast.failure("没有相册权限")
            return
        }
        guard !Task.isCancelled else { return }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = export.filename
                options.uniformTypeIdentifier = export.type.identifier
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: export.bytes, options: options)
            }
            EhToast.success("已保存到相册")
        } catch {
            EhToast.failure("相册无法保存此图片格式，请尝试存储到文件")
        }
    }
}
#endif
