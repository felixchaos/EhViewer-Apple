//
//  CachedAsyncImage.swift
//  ehviewer apple
//
//  带磁盘缓存的异步图片视图 — AsyncImage 不总是正确使用 URLCache
//  对标 Android Conaco 图片加载库的内存+磁盘双缓存
//

import SwiftUI
import EhAPI
import EhSettings
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 共享 URLSession — 避免每次 load() 创建新 session (连接池/DNS 复用显著提速)
private enum ImageSessionProvider {
    static let shared: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = .shared
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.httpMaximumConnectionsPerHost = 6
        // 使用全局 URLCache (与 App init 中配置的 320MB 磁盘缓存一致)
        config.urlCache = URLCache.shared
        config.requestCachePolicy = .useProtocolCachePolicy
        // 设置 User-Agent (对齐 Android: 所有请求携带浏览器 UA，避免 CDN 拒绝)
        config.httpAdditionalHeaders = [
            "User-Agent": EhRequestBuilder.userAgent
        ]
        return URLSession(configuration: config)
    }()
}

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

/// 缓存友好的异步图片加载器
/// AsyncImage 内部使用的 URLSession 可能不尊重 URLCache，
/// 本组件使用共享的 URLSession 确保缓存命中
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    let showProgress: Bool
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var image: PlatformImage?
    @State private var isLoading = false
    @State private var hasFailed = false
    @State private var retryCount = 0
    private let maxRetries = 3

    init(
        url: URL?,
        showProgress: Bool = true,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.showProgress = showProgress
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let image {
                #if os(macOS)
                content(Image(nsImage: image))
                #else
                content(Image(uiImage: image))
                #endif
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
                        retryCount = 0
                        Task { await load() }
                    }
            } else {
                ZStack {
                    placeholder()
                    if isLoading && showProgress {
                        ProgressView()
                            .frame(width: 24, height: 24)
                    }
                }
                .task(id: url) {
                    await load()
                }
            }
        }
    }

    private func load() async {
        guard let url else { return }
        // 如果已经有图片或正在加载，跳过
        guard image == nil, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        // 1. 内存图片缓存 (最快, 避免重复解码)
        if let memCached = ThumbnailMemoryCache.shared.get(url) {
            self.image = memCached
            return
        }

        // 2. URLCache 磁盘缓存 (直接检查, 避免网络请求)
        let cacheRequest = URLRequest(url: url)
        if let cached = URLCache.shared.cachedResponse(for: cacheRequest),
           let img = PlatformImage(data: cached.data) {
            ThumbnailMemoryCache.shared.set(img, for: url)
            self.image = img
            return
        }

        // 3. 构建要尝试的 URL 列表: 原始 URL + 自动修复的备选 URL
        var urlsToTry = [url]
        if let fallback = Self.fallbackThumbURL(for: url), fallback != url {
            // 检查备选 URL 的内存/磁盘缓存
            if let memCached = ThumbnailMemoryCache.shared.get(fallback) {
                self.image = memCached
                return
            }
            let fbRequest = URLRequest(url: fallback)
            if let cached = URLCache.shared.cachedResponse(for: fbRequest),
               let img = PlatformImage(data: cached.data) {
                ThumbnailMemoryCache.shared.set(img, for: fallback)
                self.image = img
                return
            }
            urlsToTry.append(fallback)
        }

        // 4. 网络下载 — 依次尝试每个 URL (原始 → 备选)
        let siteHost = AppSettings.shared.gallerySite == .exHentai
            ? "https://exhentai.org/" : "https://e-hentai.org/"

        for targetURL in urlsToTry {
            guard !Task.isCancelled else { return }

            if let img = await downloadImage(url: targetURL, referer: siteHost) {
                // 同时缓存原始 URL 的结果，这样下次直接命中
                ThumbnailMemoryCache.shared.set(img, for: url)
                ThumbnailMemoryCache.shared.set(img, for: targetURL)
                self.image = img
                return
            }
        }

        // 所有 URL 和重试用完 — 标记失败
        if !Task.isCancelled {
            self.hasFailed = true
        }
    }

    /// 网络下载单个 URL — 带重试
    private func downloadImage(url: URL, referer: String) async -> PlatformImage? {
        for attempt in 0..<maxRetries {
            guard !Task.isCancelled else { return nil }

            do {
                var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy)
                request.setValue(referer, forHTTPHeaderField: "Referer")
                let (data, response) = try await ImageSessionProvider.shared.data(for: request)

                // 验证 HTTP 状态码
                if let httpResponse = response as? HTTPURLResponse,
                   !(200...299).contains(httpResponse.statusCode) {
                    // 非 2xx 响应 — 不重试此 URL，由调用方尝试备选
                    return nil
                }

                // 缓存响应
                let cachedResponse = CachedURLResponse(response: response, data: data)
                URLCache.shared.storeCachedResponse(cachedResponse, for: request)

                if let img = PlatformImage(data: data) {
                    return img
                } else {
                    // 数据无法解码为图片 — 此 URL 无效
                    return nil
                }
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

    /// 自动生成备选缩略图 URL (对齐 Android EhUrl.getFixedThumbUrl)
    /// 当 ehgt.org CDN 不可达时 (常见于中国网络)，自动尝试 exhentai 的缩略图域名
    private static func fallbackThumbURL(for url: URL) -> URL? {
        let urlStr = url.absoluteString
        // 只对 ehgt.org 系列的缩略图做回退
        guard urlStr.contains("ehgt.org") else { return nil }

        let isExHentai = AppSettings.shared.gallerySite == .exHentai
        if isExHentai {
            // ExHentai 用户: ehgt.org → exhentai.org/t/
            if let range = urlStr.range(of: "https://(?:gt\\d\\.)?ehgt\\.org/", options: .regularExpression) {
                var fixed = urlStr
                fixed.replaceSubrange(range, with: "https://exhentai.org/t/")
                return URL(string: fixed)
            }
        }
        // E-Hentai 用户: 尝试不同的 gt 子域名作为回退
        // gt0-3.ehgt.org 可能部分可达
        if urlStr.contains("ehgt.org/") && !urlStr.contains("gt") {
            // 无子域名 → 尝试 gt1.ehgt.org
            return URL(string: urlStr.replacingOccurrences(of: "ehgt.org/", with: "gt1.ehgt.org/"))
        }
        return nil
    }
}

#if os(macOS)
typealias PlatformImage = NSImage
#else
typealias PlatformImage = UIImage
#endif
