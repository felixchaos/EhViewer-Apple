//
//  CachedAsyncImage.swift
//  ehviewer apple
//
//  带磁盘缓存的异步图片视图 — AsyncImage 不总是正确使用 URLCache
//  对标 Android Conaco 图片加载库的内存+磁盘双缓存
//

import SwiftUI
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
                    .onAppear {
                        // 视图重新出现时自动重试
                        if retryCount < maxRetries {
                            hasFailed = false
                            retryCount = 0
                            Task {
                                try? await Task.sleep(nanoseconds: 300_000_000)
                                await load()
                            }
                        }
                    }
            } else {
                ZStack {
                    placeholder()
                    if isLoading {
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
        guard let url, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        // 1. 内存图片缓存 (最快, 避免重复解码)
        if let memCached = ThumbnailMemoryCache.shared.get(url) {
            await MainActor.run { self.image = memCached }
            return
        }

        // 2. URLCache 磁盘缓存 (直接检查, 避免网络请求)
        let cacheRequest = URLRequest(url: url)
        if let cached = URLCache.shared.cachedResponse(for: cacheRequest),
           let img = PlatformImage(data: cached.data) {
            ThumbnailMemoryCache.shared.set(img, for: url)
            await MainActor.run { self.image = img }
            return
        }

        // 3. 网络下载 — 使用 data(for:) 一次性下载 (比 bytes 逐字节更快更可靠)
        do {
            let request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy)
            let (data, response) = try await ImageSessionProvider.shared.data(for: request)

            // 缓存响应
            let cachedResponse = CachedURLResponse(response: response, data: data)
            URLCache.shared.storeCachedResponse(cachedResponse, for: request)

            if let img = PlatformImage(data: data) {
                ThumbnailMemoryCache.shared.set(img, for: url)
                await MainActor.run { self.image = img }
            } else {
                await MainActor.run { self.hasFailed = true }
            }
        } catch {
            print("[CachedAsyncImage] Failed to load \(url.absoluteString): \(error)")
            await MainActor.run { self.retryCount += 1 }
            if retryCount < maxRetries {
                // 自动重试: 递增延迟
                try? await Task.sleep(nanoseconds: UInt64(retryCount) * 500_000_000)
                await load()
            } else {
                await MainActor.run { self.hasFailed = true }
            }
        }
    }
}

#if os(macOS)
typealias PlatformImage = NSImage
#else
typealias PlatformImage = UIImage
#endif
