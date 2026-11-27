//
//  CachedAsyncImage.swift
//  ehviewer apple
//
//  带磁盘缓存的异步图片视图 — AsyncImage 不总是正确使用 URLCache
//  对标 Android Conaco 图片加载库的内存+磁盘双缓存
//

import SwiftUI
import ImageIO
import EhAPI
import EhModels
import EhSettings
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 内存图片缓存 — 避免重复解码已下载的图片
private final class ThumbnailMemoryCache: @unchecked Sendable {
    static let shared = ThumbnailMemoryCache()
    private let cache = NSCache<NSURL, PlatformImage>()
    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 50 * 1024 * 1024  // 50MB
    }
    func get(_ url: URL) -> PlatformImage? { cache.object(forKey: url as NSURL) }
    func set(_ image: PlatformImage, for url: URL) {
        let cost = image.size.width * image.size.height * 4
        cache.setObject(image, forKey: url as NSURL, cost: Int(cost))
    }
}

/// 离主线程的降采样解码
///
/// `CachedAsyncImage` 是 View，`load()` 自然跑在 MainActor 上，
/// 原先三处 `PlatformImage(data:)` 都在主线程做全尺寸解码 ——
/// 网格里几十张图一起滚动时必然掉帧。
/// 这里改为在 detached 任务里用 ImageIO 直接解出目标尺寸的缩略图：
/// 既不占主线程，也不会把整张原图的位图留在内存里。
enum ThumbnailDecoder {
    /// 缩略图长边上限。列表缩略图、预览格子、封面都远小于此，
    /// 取一个宽松值保证清晰度，同时避免把 4000px 原图整张解进内存。
    static let defaultMaxPixel: CGFloat = 1200

    static func decode(_ data: Data, maxPixel: CGFloat = defaultMaxPixel) async -> PlatformImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                return nil
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source, 0, options as CFDictionary
            ) else {
                // GIF 等 ImageIO 缩略图失败的格式回退到整图解码
                return PlatformImage(data: data)
            }
            #if os(macOS)
            return NSImage(cgImage: cgImage,
                           size: NSSize(width: cgImage.width, height: cgImage.height))
            #else
            return UIImage(cgImage: cgImage)
            #endif
        }.value
    }
}

/// 缓存友好的异步图片加载器
/// AsyncImage 内部使用的 URLSession 可能不尊重 URLCache，
/// 本组件使用共享的 URLSession 确保缓存命中
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    let showProgress: Bool
    let fixCoverLink: Bool
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    init(
        url: URL?,
        showProgress: Bool = true,
        fixCoverLink: Bool = false,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.showProgress = showProgress
        self.fixCoverLink = fixCoverLink
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        let site = AppSettings.shared.gallerySite
        imageContent(site: site)
            .id(ImageRequestIdentity(url: url, site: site, fixCoverLink: fixCoverLink))
    }

    private struct ImageRequestIdentity: Hashable {
        let url: URL?
        let site: EhSite
        let fixCoverLink: Bool
    }

    // Reset the image/retry state itself when the request changes, not just the placeholder task.
    private func imageContent(site: EhSite) -> some View {
        ThumbnailImageContent(
            url: url, site: site, fixCoverLink: fixCoverLink, showProgress: showProgress,
            content: content, placeholder: placeholder
        )
    }
}

private struct ThumbnailImageContent<Content: View, Placeholder: View>: View {
    let url: URL?
    let site: EhSite
    let fixCoverLink: Bool
    let showProgress: Bool
    let content: (Image) -> Content
    let placeholder: () -> Placeholder
    @State private var image: PlatformImage?
    @State private var isLoading = false
    @State private var hasFailed = false
    @State private var retry = 0

    var body: some View {
        Group {
            if let image {
                if image.isAnimated {
                    // GIF 动画: 使用原生 ImageView 播放，SwiftUI Image 不支持动画
                    #if os(macOS)
                    AnimatedImageView(image: image, contentMode: .scaleProportionallyUpOrDown)
                    #else
                    AnimatedImageView(image: image, contentMode: .scaleAspectFill)
                    #endif
                } else {
                    #if os(macOS)
                    content(Image(nsImage: image))
                    #else
                    content(Image(uiImage: image))
                    #endif
                }
            } else if hasFailed {
                // 加载失败: 点击重试
                placeholder()
                    .overlay {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                    }
                    .onTapGesture {
                        hasFailed = false
                        retry += 1
                    }
            } else {
                ZStack {
                    placeholder()
                    if isLoading && showProgress {
                        ProgressView()
                            .frame(width: 24, height: 24)
                    }
                }
            }
        }
        .task(id: retry) { await load() }
    }

    private func load() async {
        guard let url else { return }
        // 如果已经有图片或正在加载，跳过
        guard image == nil, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        #if EH_OFFLINE_UI_FIXTURE && targetEnvironment(simulator)
        if EhOfflineUIFixture.interceptPreview(url) {
            try? await Task.sleep(for: .seconds(20))
            return
        }
        #endif

        let loaded = await ThumbnailImageLoader.load(url: url, site: site, fixCoverLink: fixCoverLink)
        guard !Task.isCancelled else { return }
        image = loaded
        hasFailed = loaded == nil
    }
}

@MainActor
enum ThumbnailImageLoader {
    typealias Fetch = (URLRequest) async throws -> (Data, URLResponse)

    static func load(
        url: URL,
        site: EhSite,
        fixCoverLink: Bool,
        fetch: Fetch = { try await EhAPI.shared.thumbnailData(for: $0) }
    ) async -> PlatformImage? {
        let candidates = ThumbnailRequestPolicy.candidates(for: url, site: site, fixLink: fixCoverLink)
        let referer = EhURL.host(for: site)
        let requests = candidates.map { target in
            var request = URLRequest(url: target, cachePolicy: .useProtocolCachePolicy)
            request.setValue(referer, forHTTPHeaderField: "Referer")
            return (target, request)
        }

        for (target, request) in requests {
            guard !Task.isCancelled else { return nil }
            if let cached = ThumbnailMemoryCache.shared.get(target) { return cached }
            if let cached = URLCache.shared.cachedResponse(for: request),
               let decoded = await ThumbnailDecoder.decode(cached.data) {
                guard !Task.isCancelled else { return nil }
                ThumbnailMemoryCache.shared.set(decoded, for: target)
                return decoded
            }
        }

        for (target, request) in requests {
            guard !Task.isCancelled else { return nil }
            if let decoded = await downloadImage(request: request, fetch: fetch) {
                guard !Task.isCancelled else { return nil }
                ThumbnailMemoryCache.shared.set(decoded, for: target)
                return decoded
            }
        }
        return nil
    }

    /// 网络下载单个 URL — 带重试
    private static func downloadImage(request: URLRequest, fetch: Fetch) async -> PlatformImage? {
        let maxRetries = 3
        for attempt in 0..<maxRetries {
            guard !Task.isCancelled else { return nil }
            do {
                let (data, response) = try await fetch(request)

                // 验证 HTTP 状态码
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    // 非 2xx 响应 — 不重试此 URL，由调用方尝试备选
                    return nil
                }

                guard let img = await ThumbnailDecoder.decode(data), !Task.isCancelled else { return nil }
                URLCache.shared.storeCachedResponse(CachedURLResponse(response: response, data: data), for: request)
                return img
            } catch is CancellationError {
                return nil
            } catch let urlError as URLError where urlError.code == .cancelled {
                return nil
            } catch {
                // 真实网络错误 — 延迟后重试
                if attempt < maxRetries - 1 {
                    try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 500_000_000)
                }
            }
        }
        return nil
    }
}

#if os(macOS)
typealias PlatformImage = NSImage
#else
typealias PlatformImage = UIImage
#endif
