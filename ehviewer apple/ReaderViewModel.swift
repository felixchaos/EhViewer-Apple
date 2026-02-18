//
//  ReaderViewModel.swift
//  ehviewer apple
//
//  阅读器 ViewModel — 管理页面加载、双页逻辑、预加载策略、内存优化
//  从 ImageReaderView.swift 分离，对齐 Android GalleryActivity ViewModel
//

import SwiftUI
import EhModels
import EhSpider
import EhSettings
import EhDownload
import CoreImage

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import ImageIO

// MARK: - Reading Direction

enum ReadingDirection: Int, CaseIterable {
    case leftToRight = 0
    case rightToLeft = 1
    case topToBottom = 2

    var label: String {
        switch self {
        case .leftToRight: return "从左到右"
        case .rightToLeft: return "从右到左"
        case .topToBottom: return "从上到下"
        }
    }

    var icon: String {
        switch self {
        case .leftToRight: return "arrow.right"
        case .rightToLeft: return "arrow.left"
        case .topToBottom: return "arrow.down"
        }
    }
}

// MARK: - Scale Mode

enum ScaleMode: Int, CaseIterable {
    case origin = 0
    case fitWidth = 1
    case fitHeight = 2
    case fit = 3
    case fixed = 4

    var label: String {
        switch self {
        case .origin: return "原始大小"
        case .fitWidth: return "适应宽度"
        case .fitHeight: return "适应高度"
        case .fit: return "适应屏幕"
        case .fixed: return "固定缩放"
        }
    }
}

// MARK: - Start Position

enum StartPosition: Int, CaseIterable {
    case topLeft = 0
    case topRight = 1
    case bottomLeft = 2
    case bottomRight = 3
    case center = 4

    var label: String {
        switch self {
        case .topLeft: return "左上"
        case .topRight: return "右上"
        case .bottomLeft: return "左下"
        case .bottomRight: return "右下"
        case .center: return "居中"
        }
    }
}

// MARK: - Page Spread (双页模式数据模型)

/// 一个"展页"— 单页或双页并排
struct PageSpread: Identifiable, Equatable {
    let id: Int
    let primaryPage: Int
    let secondaryPage: Int?

    var pages: [Int] {
        if let s = secondaryPage { return [primaryPage, s] } else { return [primaryPage] }
    }

    var isSingle: Bool { secondaryPage == nil }
}

// MARK: - ReaderViewModel

@MainActor
@Observable
class ReaderViewModel {

    // MARK: - Page State

    var currentPage: Int = 0
    var totalPages: Int = 0
    var gid: Int64 = 0
    var token: String = ""
    var isDownloaded: Bool = false
    /// Perf P0-1: scrollPosition 绑定用 Optional Int (ScrollView 要求 Binding<Int?>)
    var lazyCurrentPage: Int? = 0
    /// Perf P0-2: 垂直滚动模式页码追踪 (scrollPosition 绑定)
    var verticalScrollPage: Int? = 0

    // MARK: - Double Page

    /// 是否启用双页模式 (screenWidth > 600pt)
    var isDoublePageEnabled: Bool = false
    /// 页面展页列表 (单页模式下每个 spread 只有一页)
    var spreads: [PageSpread] = []
    /// 当前展页索引 (Perf P0-1: Optional for scrollPosition binding)
    var currentSpreadIndex: Int? = 0

    // MARK: - Image Loading

    var imageURLs: [Int: String] = [:]
    /// 已解码的图片 (Observable 层，触发 SwiftUI 刷新)
    var cachedImages: [Int: PlatformImage] = [:]
    var errorPages: Set<Int> = []
    var errorMessages: [Int: String] = [:]
    var retryingPages: [Int: Int] = [:]
    var downloadProgress: [Int: Double] = [:]
    var retryGeneration: [Int: Int] = [:]

    // MARK: - Visual

    /// 每页的主色调 (用于模糊背景填充)
    var dominantColors: [Int: Color] = [:]

    // MARK: - Private

    private var pTokens: [Int: String] = [:]
    private var showKeys: [Int: String] = [:]
    private var loadingPages: Set<Int> = []
    private var downloadingImages: Set<Int> = []
    private var downloadDir: URL?

    /// NSCache composite key: "gid:pageIndex" — 防止切换画廊时命中旧画廊的图片缓存
    private func cacheKey(for page: Int) -> NSString {
        "\(gid):\(page)" as NSString
    }

    /// 最大解码像素尺寸 (屏幕长边 × 3 倍，限制超大图解码内存)
    /// 15000×20000 的长条漫会被降采样到合理尺寸，避免 OOM
    /// 使用固定保守值避免在非主线程访问 UIApplication (MainActor-isolated)
    /// CGFloat 是 Sendable 的，nonisolated let 可安全跨隔离域访问
    nonisolated private static let maxDecodePixelSize: CGFloat = {
        #if os(iOS)
        // iPhone Pro Max @3x ≈ 2868px (当前最大 iPhone 屏幕像素)
        let screenMax: CGFloat = 2868
        #else
        // Mac Retina 5K 显示器
        let screenMax: CGFloat = 5120
        #endif
        return max(screenMax * 3, 4096) // 至少 4096px，最大约 3× 屏幕
    }()

    /// NSCache 后端: 根据设备物理内存动态调整
    /// 审计修复 M-1: iPhone SE (3GB) → 80MB; iPhone 15 Pro (6GB) → 200MB; Mac → 400MB
    /// cost 使用解码后像素字节数而非压缩数据大小
    private static let imageCache: NSCache<NSString, PlatformImage> = {
        let cache = NSCache<NSString, PlatformImage>()
        let physicalMemory = ProcessInfo.processInfo.physicalMemory // bytes
        let memoryGB = Double(physicalMemory) / (1024 * 1024 * 1024)
        
        let cacheLimitMB: Int
        if memoryGB < 4 {
            cacheLimitMB = 80   // iPhone SE, 低端设备
        } else if memoryGB < 6 {
            cacheLimitMB = 150  // iPhone 15 等中端
        } else if memoryGB < 8 {
            cacheLimitMB = 250  // iPhone 15 Pro, iPad
        } else {
            cacheLimitMB = 400  // Mac, 高端 iPad
        }
        
        cache.totalCostLimit = cacheLimitMB * 1024 * 1024
        cache.countLimit = min(40, cacheLimitMB / 5) // 每张约 5MB 估算
        return cache
    }()

    /// 降采样解码: 用 ImageIO 在解码阶段限制像素尺寸，而非先全量解码再缩放
    /// 一张 15000×20000 JPEG 全量解码 = 1.2GB; 降采样到 4096px 宽 ≈ 40MB
    nonisolated private static func downsampledImage(data: Data) -> PlatformImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false  // 不缓存原始数据
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else { return nil }

        // 获取原图尺寸
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let pixelHeight = properties[kCGImagePropertyPixelHeight] as? CGFloat else {
            // 无法读取尺寸，退回普通解码但仍有 NSCache 保护
            return PlatformImage(data: data)
        }

        let maxDimension = max(pixelWidth, pixelHeight)

        // 如果图片在安全范围内，直接解码
        if maxDimension <= maxDecodePixelSize {
            let thumbOpts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary) else {
                return PlatformImage(data: data)
            }
            #if os(iOS)
            return UIImage(cgImage: cgImage)
            #else
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            #endif
        }

        // 超大图: 降采样到 maxDecodePixelSize
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDecodePixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary) else {
            return PlatformImage(data: data)
        }
        #if os(iOS)
        return UIImage(cgImage: cgImage)
        #else
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif
    }

    /// 计算解码后图片的实际像素内存占用 (bytes)
    nonisolated private static func decodedCost(of image: PlatformImage) -> Int {
        #if os(iOS)
        guard let cg = image.cgImage else { return 1024 * 1024 } // 1MB fallback
        return cg.bytesPerRow * cg.height
        #else
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return 1024 * 1024 }
        return rep.bytesPerRow * rep.pixelsHigh
        #endif
    }

    /// 共享 URLSession (保持 cookies)
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = .shared
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }()

    private static let pTokenUrlPattern = try! NSRegularExpression(
        pattern: #"/s/([0-9a-f]+)/(\d+)-(\d+)"#
    )

    private static let pagesPattern = try! NSRegularExpression(
        pattern: #"(\d+)\s*pages?"#, options: .caseInsensitive
    )
    private static let imgSrcPattern = try! NSRegularExpression(
        pattern: #"id="img"\s+src="([^"]+)""#
    )
    private static let showKeyPattern = try! NSRegularExpression(
        pattern: #"var showkey\s*=\s*"([^"]+)""#
    )

    // MARK: - Double Page Logic

    /// 根据屏幕尺寸更新双页模式 — 仅横屏 + 宽度 > 700pt 时启用
    /// 修复: iPad 竖屏不再触发双页模式
    func updateLayout(screenWidth: CGFloat, screenHeight: CGFloat) {
        let shouldDouble = screenWidth > screenHeight && screenWidth > 700
        guard shouldDouble != isDoublePageEnabled else { return }
        isDoublePageEnabled = shouldDouble
        computeSpreads()
        syncSpreadIndex()
    }

    /// 计算 spreads 数组 — 封面(page 0)单独显示，后续两两配对
    func computeSpreads() {
        guard totalPages > 0 else { spreads = []; return }

        if !isDoublePageEnabled {
            spreads = (0..<totalPages).map {
                PageSpread(id: $0, primaryPage: $0, secondaryPage: nil)
            }
            return
        }

        var result: [PageSpread] = []
        // 封面始终独占
        result.append(PageSpread(id: 0, primaryPage: 0, secondaryPage: nil))
        var i = 1
        var spreadIdx = 1
        while i < totalPages {
            if i + 1 < totalPages {
                result.append(PageSpread(id: spreadIdx, primaryPage: i, secondaryPage: i + 1))
                i += 2
            } else {
                result.append(PageSpread(id: spreadIdx, primaryPage: i, secondaryPage: nil))
                i += 1
            }
            spreadIdx += 1
        }
        spreads = result
    }

    /// 根据 currentPage 同步 currentSpreadIndex
    func syncSpreadIndex() {
        currentSpreadIndex = spreadIndex(for: currentPage)
    }

    /// 查找某页所在的 spread 索引
    func spreadIndex(for page: Int) -> Int {
        spreads.firstIndex(where: { $0.pages.contains(page) }) ?? 0
    }

    /// 获取某 spread 的主页码
    func pageForSpread(_ idx: Int) -> Int {
        guard idx >= 0 && idx < spreads.count else { return 0 }
        return spreads[idx].primaryPage
    }

    // MARK: - Composite Image (双页合成)

    /// 将一个 spread 的两页合成为一张图片
    func spreadImage(at index: Int, direction: ReadingDirection) -> PlatformImage? {
        guard index >= 0 && index < spreads.count else { return nil }
        let spread = spreads[index]

        guard let primary = cachedImages[spread.primaryPage] else { return nil }
        guard let secPage = spread.secondaryPage,
              let secondary = cachedImages[secPage] else {
            return primary
        }

        // RTL: 高页码在左 (漫画翻书序)
        let (left, right): (PlatformImage, PlatformImage)
        if direction == .rightToLeft {
            left = secondary
            right = primary
        } else {
            left = primary
            right = secondary
        }
        return compositeImages(left: left, right: right)
    }

    /// 双页合成: 将两张图片水平拼合
    /// 安全限制: 合成结果不超过 maxDecodePixelSize，防止双大图合成导致 OOM
    private func compositeImages(left: PlatformImage, right: PlatformImage) -> PlatformImage {
        var maxH = max(left.size.height, right.size.height)
        var totalW = left.size.width + right.size.width

        // 安全阀: 如果合成尺寸过大，按比例缩小
        let maxDimension = max(totalW, maxH)
        let scale: CGFloat = maxDimension > Self.maxDecodePixelSize
            ? Self.maxDecodePixelSize / maxDimension
            : 1.0

        if scale < 1.0 {
            totalW *= scale
            maxH *= scale
        }

        #if os(iOS)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: totalW, height: maxH))
        return renderer.image { _ in
            let lw = left.size.width * scale
            let lh = left.size.height * scale
            let rw = right.size.width * scale
            let rh = right.size.height * scale
            let leftY = (maxH - lh) / 2
            left.draw(in: CGRect(x: 0, y: leftY, width: lw, height: lh))
            let rightY = (maxH - rh) / 2
            right.draw(in: CGRect(x: lw, y: rightY, width: rw, height: rh))
        }
        #else
        let composited = NSImage(size: NSSize(width: totalW, height: maxH))
        composited.lockFocus()
        let lw = left.size.width * scale
        let lh = left.size.height * scale
        let rw = right.size.width * scale
        let rh = right.size.height * scale
        let leftY = (maxH - lh) / 2
        left.draw(in: NSRect(x: 0, y: leftY, width: lw, height: lh),
                  from: .zero, operation: .copy, fraction: 1.0)
        let rightY = (maxH - rh) / 2
        right.draw(in: NSRect(x: lw, y: rightY, width: rw, height: rh),
                   from: .zero, operation: .copy, fraction: 1.0)
        composited.unlockFocus()
        return composited
        #endif
    }

    // MARK: - Dominant Color (模糊背景主色调提取)

    /// 提取图片平均色用于模糊氛围背景 — CIFilter 在后台线程执行
    func extractDominantColor(for page: Int) {
        guard dominantColors[page] == nil, let image = cachedImages[page] else { return }

        Task.detached(priority: .utility) {
            let color = Self.computeDominantColor(from: image)
            if let color = color {
                await MainActor.run { [weak self] in
                    self?.dominantColors[page] = color
                }
            }
        }
    }

    /// 纯计算: CIFilter 提取平均色 (nonisolated, 可在任意线程运行)
    nonisolated private static func computeDominantColor(from image: PlatformImage) -> Color? {
        #if os(iOS)
        guard let cgImage = image.cgImage else { return nil }
        let ciImage = CIImage(cgImage: cgImage)
        #else
        guard let tiffData = image.tiffRepresentation,
              let ciImage = CIImage(data: tiffData) else { return nil }
        #endif

        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: ciImage,
            kCIInputExtentKey: CIVector(cgRect: ciImage.extent)
        ]),
        let output = filter.outputImage else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        let ctx = CIContext(options: [.workingColorSpace: NSNull()])
        ctx.render(output, toBitmap: &bitmap, rowBytes: 4,
                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBA8, colorSpace: nil)

        return Color(
            red: Double(bitmap[0]) / 255.0,
            green: Double(bitmap[1]) / 255.0,
            blue: Double(bitmap[2]) / 255.0
        ).opacity(0.5)
    }

    // MARK: - Memory Management

    /// 主动释放距当前页过远的图片，防止 OOM
    func evictDistantPages(from page: Int) {
        // 保留当前页前后各 5 页 (双页模式下约 2.5 个 spread)
        let lo = max(0, page - 5)
        let hi = min(max(0, totalPages - 1), page + 5)
        let keepRange = lo...hi

        var toEvict: [Int] = []
        for (p, _) in cachedImages where !keepRange.contains(p) {
            toEvict.append(p)
        }
        for p in toEvict {
            cachedImages.removeValue(forKey: p)
            // NSCache 保留自身引用，这里只释放 Observable 层
        }
    }

    // MARK: - Context Switch (画廊切换身份守卫)

    /// 身份核对守卫 — 检测是否需要切换画廊上下文
    /// - Hit Cache: `gid` 未变且已有数据 → 跳过重新加载
    /// - Context Switch: `gid` 变更 → 重置全部状态后加载新画廊
    /// - Returns: `true` = 需要重新加载; `false` = 命中缓存可跳过
    func prepareForGallery(targetGid: Int64, targetToken: String) -> Bool {
        if self.gid == targetGid && self.totalPages > 0 {
            // Hit Cache: 同一画廊且数据已就绪 → 不重新加载
            return false
        }

        if self.gid != targetGid {
            // Context Switch: 换书了 → 先清空旧状态
            resetState()
        }

        // 设置新身份
        self.gid = targetGid
        self.token = targetToken
        return true
    }

    /// 彻底重置所有状态 — 在加载新画廊前调用
    /// UI 会因 totalPages == 0 立即切入 Loading 状态
    private func resetState() {
        // 页面状态
        currentPage = 0
        totalPages = 0
        isDownloaded = false
        lazyCurrentPage = 0
        verticalScrollPage = 0

        // 双页模式
        spreads = []
        currentSpreadIndex = 0

        // 图片数据
        imageURLs.removeAll()
        cachedImages.removeAll()
        errorPages.removeAll()
        errorMessages.removeAll()
        retryingPages.removeAll()
        downloadProgress.removeAll()
        retryGeneration.removeAll()

        // ⚠️ 关键: 清空 NSCache 防止旧画廊图片被复用
        Self.imageCache.removeAllObjects()

        // 视觉
        dominantColors.removeAll()

        // 私有状态
        pTokens.removeAll()
        showKeys.removeAll()
        loadingPages.removeAll()
        downloadingImages.removeAll()
        downloadDir = nil
    }

    // MARK: - Setup (Fix D-1, B-1: 从 DownloadManager 查询真实下载状态，不再信任调用方传入的 Bool)

    /// 检查下载状态并设置本地目录 — 替代旧的硬编码 `isDownloaded` + `gid-token` 路径
    /// 验证: 数据库状态 == stateFinish AND 磁盘目录存在
    func setupLocalGallery() async {
        let fullyDownloaded = await DownloadManager.shared.isGalleryFullyDownloaded(gid: gid)
        if fullyDownloaded,
           let dir = await DownloadManager.shared.getDownloadedGalleryDirectory(gid: gid) {
            self.isDownloaded = true
            self.downloadDir = dir
        } else {
            self.isDownloaded = false
            self.downloadDir = nil
        }
    }

    func extractPTokens(from previewSet: PreviewSet) {
        let urls: [String]
        switch previewSet {
        case .normal(let items): urls = items.map { $0.pageUrl }
        case .large(let items): urls = items.map { $0.pageUrl }
        }

        for url in urls {
            let range = NSRange(url.startIndex..., in: url)
            if let match = Self.pTokenUrlPattern.firstMatch(in: url, range: range),
               let ptRange = Range(match.range(at: 1), in: url),
               let pnRange = Range(match.range(at: 3), in: url) {
                let pt = String(url[ptRange])
                let pn = Int(url[pnRange]) ?? 0
                pTokens[pn - 1] = pt
            }
        }
    }

    // MARK: - Network: Gallery Info

    func fetchGalleryInfo() async {
        let site = GalleryActionService.siteBaseURL
        let urlStr = "\(site)g/\(gid)/\(token)/"
        guard let url = URL(string: urlStr) else { return }

        do {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
                             forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 15

            let (data, _) = try await Self.session.data(for: request)
            let html = String(data: data, encoding: .utf8) ?? ""

            if let match = Self.pagesPattern.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                let pages = Int(html[range]) ?? 0
                await MainActor.run { self.totalPages = pages }
            }

            let range = NSRange(html.startIndex..., in: html)
            let matches = Self.pTokenUrlPattern.matches(in: html, range: range)
            for m in matches {
                guard let ptRange = Range(m.range(at: 1), in: html),
                      let pnRange = Range(m.range(at: 3), in: html) else { continue }
                let pt = String(html[ptRange])
                let pn = Int(html[pnRange]) ?? 0
                pTokens[pn - 1] = pt
            }
        } catch {}
    }

    // MARK: - Page Loading

    func loadCurrentPage() async {
        await loadPage(currentPage)
        await downloadImageData(currentPage)
        await preload(around: currentPage)
    }

    func onPageChange(_ page: Int) async {
        // 更新 spread 索引
        let spreadIdx = spreadIndex(for: page)
        if spreadIdx != currentSpreadIndex {
            await MainActor.run { self.currentSpreadIndex = spreadIdx }
        }

        await loadPage(page)
        await downloadImageData(page)

        // 双页模式下同时加载副页
        if isDoublePageEnabled, spreadIdx < spreads.count {
            let spread = spreads[spreadIdx]
            for p in spread.pages where p != page {
                await loadPage(p)
                await downloadImageData(p)
            }
        }

        await preload(around: page)

        // 提取主色调 (内部已在后台线程执行)
        extractDominantColor(for: page)

        // 释放远处页面
        evictDistantPages(from: page)
    }

    /// 下载图片数据到 NSCache，带进度追踪
    func downloadImageData(_ index: Int) async {
        // 已缓存 → 直接提升到 Observable 层 (使用 gid:page 复合 key)
        let key = cacheKey(for: index)
        if let cached = Self.imageCache.object(forKey: key) {
            await MainActor.run {
                if self.cachedImages[index] == nil {
                    self.cachedImages[index] = cached
                }
            }
            return
        }
        guard let urlString = imageURLs[index], let url = URL(string: urlString) else { return }
        guard !downloadingImages.contains(index) else { return }
        downloadingImages.insert(index)
        defer { downloadingImages.remove(index) }

        for attempt in 0..<3 {
            do {
                var request = URLRequest(url: url)
                request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
                                 forHTTPHeaderField: "User-Agent")
                request.setValue(GalleryActionService.siteBaseURL, forHTTPHeaderField: "Referer")
                request.timeoutInterval = 60

                // Perf: 使用 data(for:) 一次性下载替代 byte-by-byte 迭代
                // byte-by-byte 的 async overhead 极高，导致翻页卡顿
                let (data, _) = try await Self.session.data(for: request)

                // 图片解码移到后台线程，避免阻塞 MainActor
                let img = await Task.detached(priority: .userInitiated) {
                    Self.downsampledImage(data: data)
                }.value

                if let img = img {
                    let cost = Self.decodedCost(of: img)
                    let cacheKey = self.cacheKey(for: index)
                    Self.imageCache.setObject(img, forKey: cacheKey, cost: cost)
                    await MainActor.run {
                        self.cachedImages[index] = img
                        self.downloadProgress.removeValue(forKey: index)
                        // 审计修复 M-2: 每次新图片加入后立即淘汰远处页面
                        self.evictDistantPages(from: self.currentPage)
                    }
                    return
                } else {
                    await MainActor.run {
                        self.errorPages.insert(index)
                        self.errorMessages[index] = "图片数据无效"
                        self.downloadProgress.removeValue(forKey: index)
                    }
                    return
                }
            } catch is CancellationError {
                return
            } catch let urlError as URLError where urlError.code == .cancelled {
                return
            } catch {
                if Task.isCancelled { return }
                debugLog("[Reader] Image download error page \(index) attempt \(attempt + 1): \(error.localizedDescription)")
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt))) * 1_000_000_000)
                    if Task.isCancelled { return }
                    continue
                }
                await MainActor.run {
                    self.errorPages.insert(index)
                    self.errorMessages[index] = "下载失败: \(error.localizedDescription)"
                    self.downloadProgress.removeValue(forKey: index)
                }
            }
        }
    }

    /// 带重试的页面 URL 获取 (最多 5 次)
    func loadPageWithRetry(_ index: Int) async {
        let maxRetries = 5
        for attempt in 0..<maxRetries {
            guard !Task.isCancelled else { return }
            await MainActor.run { self.retryingPages[index] = attempt }
            await loadPage(index)
            if imageURLs[index] != nil {
                await MainActor.run { _ = self.retryingPages.removeValue(forKey: index) }
                return
            }
            if errorPages.contains(index) { return }
            guard !Task.isCancelled else { return }
            let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
        }
        guard !Task.isCancelled else { return }
        await MainActor.run {
            self.errorPages.insert(index)
            self.errorMessages[index] = "加载超时，请点击重试"
            self.retryingPages.removeValue(forKey: index)
        }
    }

    func loadPage(_ index: Int) async {
        guard index >= 0, index < totalPages else { return }
        guard imageURLs[index] == nil else { return }
        guard !loadingPages.contains(index) else { return }

        // 优先本地 (Fix D-1: 通过 DownloadManager 统一路径，本地找不到时回退网络)
        if isDownloaded, let dir = downloadDir {
            if let localURL = SpiderInfoFile.getLocalImageURL(in: dir, pageIndex: index) {
                await MainActor.run {
                    self.imageURLs[index] = localURL.absoluteString
                    self.errorPages.remove(index)
                }
                return
            }
            // 本地文件缺失 — 不 return，继续尝试网络加载
        }

        // URL 缓存
        if let cached = GalleryCache.shared.getImageURL(gid: gid, page: index) {
            await MainActor.run {
                self.imageURLs[index] = cached
                self.errorPages.remove(index)
            }
            return
        }

        loadingPages.insert(index)
        defer { loadingPages.remove(index) }

        do {
            let site = GalleryActionService.siteBaseURL
            let pageUrl: String

            if let pToken = pTokens[index] {
                pageUrl = "\(site)s/\(pToken)/\(gid)-\(index + 1)"
            } else {
                let pToken = try await fetchPToken(page: index)
                pTokens[index] = pToken
                pageUrl = "\(site)s/\(pToken)/\(gid)-\(index + 1)"
            }

            guard let url = URL(string: pageUrl) else { return }

            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
                             forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 15

            let (data, _) = try await Self.session.data(for: request)
            let html = String(data: data, encoding: .utf8) ?? ""

            if let m = Self.imgSrcPattern.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let r = Range(m.range(at: 1), in: html) {
                let imgUrl = String(html[r])
                GalleryCache.shared.putImageURL(imgUrl, gid: gid, page: index)
                await MainActor.run {
                    self.imageURLs[index] = imgUrl
                    self.errorPages.remove(index)
                }
            } else {
                debugLog("[Reader] Failed to extract image URL from page HTML for page \(index)")
                await MainActor.run { _ = self.errorPages.insert(index) }
                return
            }

            if let m = Self.showKeyPattern.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let r = Range(m.range(at: 1), in: html) {
                showKeys[index] = String(html[r])
            }
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            if !Task.isCancelled {
                debugLog("[Reader] Page \(index) load error: \(error.localizedDescription)")
            }
        }
    }

    func retryLoadPage(_ index: Int) async {
        await MainActor.run {
            self.imageURLs[index] = nil
            self.cachedImages.removeValue(forKey: index)
            self.errorPages.remove(index)
            self.errorMessages.removeValue(forKey: index)
            self.retryingPages.removeValue(forKey: index)
            self.downloadProgress.removeValue(forKey: index)
            self.retryGeneration[index, default: 0] += 1
        }
        Self.imageCache.removeObject(forKey: cacheKey(for: index))
        pTokens.removeValue(forKey: index)
        GalleryCache.shared.removeImageURL(gid: gid, page: index)
        loadingPages.remove(index)
        await loadPageWithRetry(index)
        await downloadImageData(index)
    }

    /// 预加载 — 前 1 页 + 后 preloadImage 页 (并行)
    func preload(around page: Int) async {
        let preloadNum = AppSettings.shared.preloadImage
        let lo = max(0, page - 1)
        let hi = min(totalPages - 1, page + preloadNum)
        guard lo <= hi else { return }

        var pagesToLoad: [Int] = []
        for i in lo...hi where imageURLs[i] == nil && !loadingPages.contains(i) {
            pagesToLoad.append(i)
        }

        await withTaskGroup(of: Void.self) { group in
            for p in pagesToLoad {
                group.addTask {
                    await self.loadPage(p)
                    await self.downloadImageData(p)
                }
            }
        }
    }

    private func fetchPToken(page: Int) async throws -> String {
        let site = GalleryActionService.siteBaseURL
        let detailPage = page / 20
        let urlStr = "\(site)g/\(gid)/\(token)/\(detailPage > 0 ? "?p=\(detailPage)" : "")"
        guard let url = URL(string: urlStr) else {
            throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Bad URL"])
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
                         forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, _) = try await Self.session.data(for: request)
        let html = String(data: data, encoding: .utf8) ?? ""

        let range = NSRange(html.startIndex..., in: html)
        let matches = Self.pTokenUrlPattern.matches(in: html, range: range)

        for m in matches {
            guard let ptRange = Range(m.range(at: 1), in: html),
                  let pnRange = Range(m.range(at: 3), in: html) else { continue }
            let pt = String(html[ptRange])
            let pn = Int(html[pnRange]) ?? 0
            pTokens[pn - 1] = pt
        }

        if let pt = pTokens[page] { return pt }
        throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "pToken not found"])
    }
}
