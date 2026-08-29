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
import EhAPI
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

    // dominantColors 已移除 — 节省 OLED 电量，使用纯黑背景

    // MARK: - Private (不驱动 UI，无需触发 SwiftUI 刷新)

    /// Perf: 以下属性仅用于内部状态管理，不被任何 View 读取，
    /// 标记 @ObservationIgnored 避免写入时触发冗余 body 重绘
    @ObservationIgnored private var pTokens: [Int: String] = [:]
    @ObservationIgnored private var showKeys: [Int: String] = [:]
    /// 每页最近一次页面返回的 nl key — 用于跳过挂掉的 H@H 节点 (对齐 Android skipHathKey)
    @ObservationIgnored private var skipHathKeys: [Int: String] = [:]
    /// 已经用过的 nl key — 服务器重复返回同一个 key 说明没有别的节点了，不再重试
    @ObservationIgnored private var usedSkipHathKeys: [Int: Set<String>] = [:]
    @ObservationIgnored private var loadingPages: Set<Int> = []
    @ObservationIgnored private var downloadingImages: Set<Int> = []
    /// 正在进行的单页下载。由 ViewModel 持有，不随视图或预加载任务被取消。
    @ObservationIgnored private var downloadTasks: [Int: Task<Void, Never>] = [:]
    /// 后台预加载任务 —— 翻页时取消上一轮，避免快速翻页堆积并发请求
    @ObservationIgnored private var preloadTask: Task<Void, Never>?
    /// 上一次预加载的锚点页 —— 用来推断翻页方向
    @ObservationIgnored private var lastPreloadAnchor: Int?
    @ObservationIgnored private var downloadDir: URL?

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
    /// 对于 GIF 动画: 直接使用 PlatformImage(data:) 保留所有帧，不做降采样
    nonisolated private static func downsampledImage(data: Data) -> PlatformImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false  // 不缓存原始数据
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else { return nil }

        // GIF 动画检测: 多帧图片直接解码，保留动画帧
        // CGImageSourceCreateThumbnailAtIndex 只提取第一帧, 会丢失动画
        let frameCount = CGImageSourceGetCount(source)
        if frameCount > 1 {
            return PlatformImage(data: data)
        }

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

    // MARK: - Double Page Logic

    /// 用户在阅读器底栏手动切换过双页时记在这里。
    /// 没有它的话，旋转屏幕触发的 updateLayout 会把手动选择直接覆盖掉。
    var userDoublePageOverride: Bool?

    /// 手动切换双页 —— 记录覆盖并立即重算
    func toggleDoublePage() {
        let next = !isDoublePageEnabled
        userDoublePageOverride = next
        isDoublePageEnabled = next
        computeSpreads()
        syncSpreadIndex()
    }

    /// 根据屏幕尺寸更新双页模式 — 仅横屏 + 宽度 > 700pt 时启用
    /// 修复: iPad 竖屏不再触发双页模式
    func updateLayout(screenWidth: CGFloat, screenHeight: CGFloat) {
        let shouldDouble = userDoublePageOverride
            ?? (screenWidth > screenHeight && screenWidth > 700)
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

    // MARK: - Dominant Color (已移除)
    // 平均色计算已移除 — 节省 OLED 电量，使用纯黑背景

    // MARK: - Memory Management

    /// 主动释放距当前页过远的图片，防止 OOM
    /// Perf: 批量移除 — 构建新字典后一次性赋值，避免 N 次 Observable 通知
    func evictDistantPages(from page: Int) {
        // 保留范围跟随预加载窗口，避免刚预取的页被立刻淘汰
        let radius = retentionRadius
        let lo = max(0, page - radius)
        let hi = min(max(0, totalPages - 1), page + radius)
        let keepRange = lo...hi

        // 先只挑出要删的 key —— 不整份拷贝字典。
        // 大画廊里 cachedImages 可能有几十项，每次翻页都拷一遍是白花的开销。
        let doomed = cachedImages.keys.filter { !keepRange.contains($0) }
        guard !doomed.isEmpty else { return }

        // 图片本体仍在 NSCache 里，这里只是把它移出 Observable 层，
        // 回头翻回来由 restoreCachedImages 直接取回，不需要重新下载。
        for p in doomed {
            cachedImages.removeValue(forKey: p)
        }

        // 真正离得远的页，把还在跑的下载停掉。
        //
        // 下载任务已经不随视图/预加载被取消了（见 downloadImageData），
        // 所以「不再需要的页别再占带宽」这件事得在这里显式做一次。
        // 用比保留半径更宽的窗口：刚滑过去一两页就掐掉，用户一回头
        // 又得从头下，那正是要避免的浪费。
        let cancelLo = max(0, page - radius * 2)
        let cancelHi = min(max(0, totalPages - 1), page + radius * 2)
        for p in activeDownloadPages() where p < cancelLo || p > cancelHi {
            cancelDownload(p)
        }
    }

    /// 当前有下载在跑的页
    private func activeDownloadPages() -> [Int] {
        Array(downloadTasks.keys)
    }

    /// 从 NSCache 恢复当前页附近的图片到 Observable 层
    /// 切换阅读模式 (水平 ↔ 垂直) 时调用，避免已下载的图片因 eviction 被移出
    /// cachedImages 后需要重新网络下载
    /// 同步取图：Observable 层没有就直接问 NSCache。
    ///
    /// 视图此前只读 cachedImages，而 evictDistantPages 会把远处的图从
    /// 那一层移走（NSCache 里其实还在）。于是快速翻回去时，明明内存里有图，
    /// 界面却落回「正在下载」那个转圈——而且它连进度都没有，因为根本没有
    /// 下载在跑。NSCache 查一次是常数时间，直接在 body 里问它就行。
    func image(at index: Int) -> PlatformImage? {
        if let img = cachedImages[index] { return img }
        return Self.imageCache.object(forKey: cacheKey(for: index))
    }

    func restoreCachedImages(around page: Int) {
        let radius = retentionRadius
        let lo = max(0, page - radius)
        let hi = min(max(0, totalPages - 1), page + radius)
        var restored = false
        for p in lo...hi {
            if cachedImages[p] == nil {
                let key = cacheKey(for: p)
                if let img = Self.imageCache.object(forKey: key) {
                    cachedImages[p] = img
                    restored = true
                }
            }
        }
        if restored {
            debugLog("[Reader] Restored cached images around page \(page)")
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



        // 私有状态
        pTokens.removeAll()
        showKeys.removeAll()
        skipHathKeys.removeAll()
        usedSkipHathKeys.removeAll()
        preloadTask?.cancel()
        preloadTask = nil
        lastPreloadAnchor = nil
        loadingPages.removeAll()
        downloadingImages.removeAll()
        downloadDir = nil
    }

    // MARK: - Setup (Fix D-1, B-1: 从 DownloadManager 查询真实下载状态，不再信任调用方传入的 Bool)

    /// 检查本地下载目录 — 替代旧的硬编码 `isDownloaded` + `gid-token` 路径
    /// 有下载记录且目录里至少有一张图就启用本地读取，缺失的页由 loadPage 逐页回退网络
    func setupLocalGallery() async {
        // ★ 不再要求"整本下载完成"才读本地 (对齐 Android SpiderDen: 逐页判断)
        //   之前只要 isGalleryFullyDownloaded 判错 (下载中断、少一页、目录存在但文件不全)，
        //   整本都会退回网络加载 —— 表现为"下载完了还是很慢 / 断网完全打不开" (issue #8 问题二)
        //   loadPage 里本地文件缺失时仍会逐页回退网络，因此这里放宽是安全的
        let dir = await DownloadManager.shared.localGalleryDirectory(gid: gid)
        self.downloadDir = dir
        self.isDownloaded = dir != nil
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

        preloadTask?.cancel()
        preloadTask = Task { [weak self] in
            guard let self else { return }
            await self.preload(around: self.currentPage)
        }
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

        // 释放远处页面
        evictDistantPages(from: page)

        // 预加载不阻塞翻页: 原先 await preload 会把整个 TaskGroup 等完
        // (默认 5 页 = 6 次网络往返)，翻页手势要等它结束才算完成，大画廊尤其明显。
        // 改为后台推进，并在下次翻页时取消上一次未完成的预加载。
        preloadTask?.cancel()
        preloadTask = Task { [weak self] in
            await self?.preload(around: page)
        }
    }

    /// 下载图片数据到 NSCache，带进度追踪
    /// 下载某一页。**同一页同时只会有一个真正的下载在跑**，重复调用是等它。
    ///
    /// 下载任务由 ViewModel 持有，不挂在调用方的 Task 上。这一点很重要：
    /// 之前它是被视图的 `.task` 和预加载任务共同持有的，于是
    ///
    ///   - 用户滑过某一页 → 视图消失 → `.task` 取消 → 下到 99% 的字节全扔掉
    ///   - 滑回来 → 占位符重建 → 从头再下一遍
    ///   - 翻页触发 `preloadTask?.cancel()` → 同样把进行中的下载腰斩
    ///
    /// 表现就是「明明加载到 100% 了又重新开始」，流量翻倍。图片下到一半的
    /// 字节没有任何复用价值，取消它省不下什么，重下却要付全额。
    func downloadImageData(_ index: Int) async {
        if let inFlight = downloadTasks[index] {
            // 已经有人在下这一页，等它就行，不要再发一个请求
            await inFlight.value
            return
        }
        // Task {} 不继承调用方的取消状态：视图消失、预加载被取消，
        // 都不会再打断已经开始的下载。要停只能显式调 cancelDownload。
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performImageDownload(index)
        }
        downloadTasks[index] = task
        await task.value
        downloadTasks[index] = nil
    }

    /// 显式取消某一页的下载。只在这一页确实不再需要时调
    /// （evictDistantPages 判定它已经离得太远）。
    func cancelDownload(_ index: Int) {
        downloadTasks[index]?.cancel()
        downloadTasks[index] = nil
    }

    private func performImageDownload(_ index: Int) async {
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
        // 内存里没有 → 先看磁盘缓存。
        //
        // 此前只有内存 NSCache：退出阅读器、或者图被内存压力挤掉之后，
        // 同一页要重新从网络下一遍。这是「同一本看两遍付两份流量」的来源，
        // 也是设置里那个「阅读缓存大小」一直没有真正生效的原因——
        // 阅读器根本没往那块缓存里写过东西。
        if let cached = SpiderDen.cachedImageData(gid: gid, page: index),
           let img = await Task.detached(priority: .userInitiated, operation: {
               Self.downsampledImage(data: cached)
           }).value {
            Self.imageCache.setObject(img, forKey: key, cost: Self.decodedCost(of: img))
            await MainActor.run { self.cachedImages[index] = img }
            return
        }

        guard let urlString = imageURLs[index], let initialURL = URL(string: urlString) else { return }

        // 已下载的画廊读的是 file:// —— 直接读盘解码就行。
        //
        // 此前本地文件也被塞进下面那整套网络流程：进度追踪、4 次重试、
        // 换 H@H 节点……对一个本地文件这些全无意义，却实实在在拖慢了显示，
        // 表现就是「明明已经下载了，翻页还在转圈」。
        if initialURL.isFileURL {
            if let data = try? Data(contentsOf: initialURL),
               let img = await Task.detached(priority: .userInitiated, operation: {
                   Self.downsampledImage(data: data)
               }).value {
                Self.imageCache.setObject(img, forKey: key, cost: Self.decodedCost(of: img))
                await MainActor.run {
                    self.cachedImages[index] = img
                    self.downloadProgress.removeValue(forKey: index)
                    self.errorPages.remove(index)
                }
            } else {
                await MainActor.run {
                    self.errorPages.insert(index)
                    self.errorMessages[index] = "本地文件读取失败"
                }
            }
            return
        }

        guard !downloadingImages.contains(index) else { return }
        // 可变: 换 H@H 节点后 URL 会变 (对齐 Android SpiderQueen 的 nl= 重试)
        var url = initialURL
        downloadingImages.insert(index)
        defer { downloadingImages.remove(index) }

        // 立即设置初始进度 0，让 UI 渲染圆形进度条而非纯 spinner
        await MainActor.run {
            if self.downloadProgress[index] == nil {
                self.downloadProgress[index] = 0.0
            }
        }

        let maxAttempts = 4
        for attempt in 0..<maxAttempts {
            do {
                var request = URLRequest(url: url)
                request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
                                 forHTTPHeaderField: "User-Agent")
                request.setValue(GalleryActionService.siteBaseURL, forHTTPHeaderField: "Referer")
                request.timeoutInterval = 60

                // 使用 bytes(for:) 流式读取 + 手动进度追踪
                // ⚠️ download(for:delegate:) 的 async 包装不转发 URLSessionDownloadDelegate 的
                //    didWriteData 回调，导致进度始终为 0 → 直接跳到 100%
                // bytes(for:) 虽逐字节迭代，但配合 16KB 缓冲区按 chunk 更新进度，开销可控
                let (asyncBytes, response) = try await Self.session.bytes(for: request)
                let expectedLength = response.expectedContentLength > 0
                    ? response.expectedContentLength
                    : Int64(2_000_000) // 估算 ~2MB
                var data = Data(capacity: Int(min(expectedLength, 10_000_000)))
                var received: Int64 = 0
                var lastReportedProgress: Double = 0.0
                let chunkSize = 16_384 // 16KB — 每累计一个 chunk 检查是否需要更新进度
                var buffer = [UInt8]()
                buffer.reserveCapacity(chunkSize)

                for try await byte in asyncBytes {
                    buffer.append(byte)
                    if buffer.count >= chunkSize {
                        data.append(contentsOf: buffer)
                        received += Int64(buffer.count)
                        buffer.removeAll(keepingCapacity: true)
                        // 每 5% 进度变化更新一次 UI
                        let progress = min(0.95, Double(received) / Double(expectedLength))
                        if progress - lastReportedProgress >= 0.05 {
                            lastReportedProgress = progress
                            let p = progress
                            await MainActor.run {
                                self.downloadProgress[index] = p
                            }
                        }
                    }
                }
                // 处理剩余不足一个 chunk 的数据
                if !buffer.isEmpty {
                    data.append(contentsOf: buffer)
                }

                // 下载完成 → 标记 100%，让用户看到从进度到解码的过渡
                await MainActor.run {
                    self.downloadProgress[index] = 1.0
                }

                // 图片解码移到后台线程，避免阻塞 MainActor
                let img = await Task.detached(priority: .userInitiated) {
                    Self.downsampledImage(data: data)
                }.value

                if let img = img {
                    // 先落缓存：这一页以后再看就不用再下了。
                    // 写的是 Caches/ 下受 readCacheSize 约束的那块，超了自动淘汰。
                    SpiderDen.cacheImageData(data, gid: gid, page: index)

                    // 阅读时同步下载 —— 这是「下载」不是「缓存」：
                    // 它把图写进 Documents/download 并登记下载任务，默认关闭。
                    await syncDownloadIfEnabled(index: index, data: data, url: url)

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
                await MainActor.run { _ = self.downloadProgress.removeValue(forKey: index) }
                return
            } catch let urlError as URLError where urlError.code == .cancelled {
                await MainActor.run { _ = self.downloadProgress.removeValue(forKey: index) }
                return
            } catch {
                if Task.isCancelled {
                    await MainActor.run { _ = self.downloadProgress.removeValue(forKey: index) }
                    return
                }
                debugLog("[Reader] Image download error page \(index) attempt \(attempt + 1): \(error.localizedDescription)")

                // ★ 兜底 1: 改走 EhAPI 的域名前置直连回退
                //   TLS 握手失败 / DNS 解析失败时裸 session 永远失败 (issue #6)
                if Self.shouldFallbackToEhAPI(error) {
                    if let data = try? await EhAPI.shared.fetchImageData(
                        url: url.absoluteString,
                        referer: GalleryActionService.siteBaseURL
                    ), !data.isEmpty,
                       let img = await Task.detached(priority: .userInitiated, operation: {
                           Self.downsampledImage(data: data)
                       }).value {
                        Self.imageCache.setObject(img, forKey: self.cacheKey(for: index), cost: Self.decodedCost(of: img))
                        await MainActor.run {
                            self.cachedImages[index] = img
                            self.errorPages.remove(index)
                            self.downloadProgress.removeValue(forKey: index)
                            self.evictDistantPages(from: self.currentPage)
                        }
                        return
                    }
                }

                if Task.isCancelled { return }

                // ★ 兜底 2: 换一个 H@H 节点 (对齐 Android SpiderQueen 的 nl= 重试)
                //   节点掉线 / 证书异常时，同一个 URL 重试多少次都没用，必须换节点
                if attempt >= 1, let newURL = await switchHathNode(index) {
                    url = newURL
                    continue
                }

                if attempt < maxAttempts - 1 {
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

    /// 阅读时同步下载 — 浏览未下载的画廊时把看过的图片顺手存进下载目录
    ///
    /// 对齐 Android 上游 2026-06-16「添加"阅读时同步下载"功能」。
    /// Android 是在 SpiderDen 的写管道里分流；Apple 端阅读器自己下图，所以挂在这里。
    /// 已经在读本地文件 (isDownloaded) 时不重复写。
    private func syncDownloadIfEnabled(index: Int, data: Data, url: URL) async {
        guard AppSettings.shared.syncDownloadWhileReading else { return }
        guard !isDownloaded else { return }          // 本地已有整本，无需再存
        guard !url.isFileURL else { return }         // 读的就是本地文件
        guard let info = GalleryCache.shared.getDetail(gid: gid)?.info else { return }

        // 扩展名优先用图片 URL 上的，拿不到就按数据头猜
        var ext = "." + url.pathExtension.lowercased()
        if url.pathExtension.isEmpty { ext = Self.imageExtension(for: data) }

        await DownloadManager.shared.saveWhileReading(
            gallery: info, pageIndex: index, data: data, extension: ext
        )
    }

    /// 按文件头判断图片扩展名 (对齐 SpiderDen.detectImageExtension)
    private static func imageExtension(for data: Data) -> String {
        guard data.count >= 12 else { return ".jpg" }
        let b = [UInt8](data.prefix(12))
        if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return ".jpg" }
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return ".png" }
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return ".gif" }
        if b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return ".webp" }
        return ".jpg"
    }

    /// 换一个 H@H 节点重新获取图片 URL — 对齐 Android SpiderQueen 的 `?nl=<skipHathKey>` 重试
    ///
    /// E-Hentai 把图片分发到用户自建的 H@H 节点上，某个节点掉线 / 证书过期 / 被墙时，
    /// 该页会一直下载失败。带上 nl= 参数重新请求页面，服务器就会换一个节点。
    /// 这是"检索和预览都正常、点进阅读加载不出图片"最常见的原因之一 (issue #6)。
    private func switchHathNode(_ index: Int) async -> URL? {
        guard let key = skipHathKeys[index], !key.isEmpty else { return nil }
        var used = usedSkipHathKeys[index] ?? []
        // 同一个 key 再次出现 → 服务器已经没有别的节点可分配 (对齐 Android leakSkipHathKey)
        guard !used.contains(key), used.count < 3 else { return nil }
        used.insert(key)
        usedSkipHathKeys[index] = used

        guard let pToken = pTokens[index] else { return nil }
        let site = GalleryActionService.siteBaseURL
        var pageUrl = "\(site)s/\(pToken)/\(gid)-\(index + 1)"
        pageUrl += pageUrl.contains("?") ? "&nl=\(key)" : "?nl=\(key)"

        guard let result = try? await EhAPI.shared.getGalleryPage(url: pageUrl),
              !result.imageUrl.isEmpty,
              let newURL = URL(string: result.imageUrl) else { return nil }

        skipHathKeys[index] = result.skipHathKey
        if let showKey = result.showKey { showKeys[index] = showKey }
        GalleryCache.shared.putImageURL(result.imageUrl, gid: gid, page: index)
        await MainActor.run { self.imageURLs[index] = result.imageUrl }
        debugLog("[Reader] Page \(index): switched H@H node → \(newURL.host ?? "?")")
        return newURL
    }

    /// 是否值得改走 EhAPI 的域名前置回退 (对应 EhAPI.shouldTryDirectFallback)
    private static func shouldFallbackToEhAPI(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .secureConnectionFailed, .cannotConnectToHost, .cannotFindHost,
             .dnsLookupFailed, .timedOut, .networkConnectionLost,
             .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return true
        default:
            return false
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

            // ★ 统一走 EhAPI (对齐 Android EhEngine.getGalleryPage):
            //   Cookie 清洁 + 速率限制 + 自动重试 + 域名前置直连回退,
            //   不再用裸 URLSession 直连 —— 那会在 DNS 污染/SNI 拦截时直接 TLS 失败 (issue #6)
            //   同时用 GalleryPageParser 解析, 图片 URL 中的 &amp; 等实体会被正确反转义
            let result = try await EhAPI.shared.getGalleryPage(url: pageUrl)
            let imgUrl = result.imageUrl
            guard !imgUrl.isEmpty else {
                debugLog("[Reader] Failed to extract image URL from page HTML for page \(index)")
                // 抓不到图片 URL 通常意味着 EH 改了页面结构，留个现场
                if let html = try? await EhAPI.shared.fetchHTML(url: pageUrl) {
                    LogManager.shared.saveParseErrorBody(html, context: "gallery-page-\(gid)-\(index + 1)")
                }
                await MainActor.run { _ = self.errorPages.insert(index) }
                return
            }
            GalleryCache.shared.putImageURL(imgUrl, gid: gid, page: index)
            await MainActor.run {
                self.imageURLs[index] = imgUrl
                self.errorPages.remove(index)
            }
            if let key = result.showKey {
                showKeys[index] = key
            }
            skipHathKeys[index] = result.skipHathKey
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
        usedSkipHathKeys.removeValue(forKey: index)
        GalleryCache.shared.removeImageURL(gid: gid, page: index)
        loadingPages.remove(index)
        await loadPageWithRetry(index)
        await downloadImageData(index)
    }

    /// 预加载 — 前 1 页 + 后 preloadImage 页 (并行)
    // MARK: - 动态预加载

    /// 设备档位决定预加载窗口 —— Mac / iPad 内存和带宽都更宽裕，
    /// iPhone 上激进预加载反而会挤掉当前页的解码时机
    static var platformPreloadBudget: Int {
        #if os(macOS)
        return 12
        #else
        let memoryGB = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
        if UIDevice.current.userInterfaceIdiom == .pad { return memoryGB >= 8 ? 10 : 7 }
        return memoryGB >= 6 ? 6 : 4
        #endif
    }

    /// 实际生效的预加载页数 = 用户设置与设备预算取较小值
    private var effectivePreloadCount: Int {
        max(1, min(AppSettings.shared.preloadImage, Self.platformPreloadBudget))
    }

    /// 需要常驻 Observable 层的页数 —— 必须 ≥ 预加载窗口，
    /// 否则刚预加载好的页会被 evictDistantPages 立刻扔掉，来回空转
    var retentionRadius: Int {
        // 比预加载窗口宽出一截。窗口贴太紧时，快速翻页会把刚划过的几页
        // 立刻淘汰，回头一看又是转圈。图片本体仍在 NSCache 里，
        // 这里放宽的只是 Observable 层的常驻量。
        max(12, effectivePreloadCount * 2 + 4)
    }

    /// 这一页卡死了吗 —— 没图、没报错、也没有任何人在为它干活。
    ///
    /// 这个状态是真实存在的，不是理论上的：`downloadImageData` 开头有
    /// `guard !downloadingImages.contains(index) else { return }`，而下载任务
    /// 被取消时（翻页会 `preloadTask?.cancel()`）走的是 CancellationError 分支，
    /// 那里只清掉 downloadProgress，`defer` 再把 index 从 downloadingImages 摘掉。
    /// 于是出现这样一串：
    ///
    ///   1. 预加载正在下第 N 页，进度已经到 100%
    ///   2. 用户翻页 → preloadTask 取消
    ///   3. onPageChange(N) 调 downloadImageData(N)，但此刻 N 还在
    ///      downloadingImages 里 → 直接 return
    ///   4. 被取消的那个任务收尾：清进度、从 downloadingImages 移除
    ///
    /// 最后没有任何任务在跑，进度是 nil，图也没有——视图落到
    /// 「下载图片中…」那个无限转圈的分支，而且永远不会自己好。
    func isStalled(_ index: Int) -> Bool {
        !isImageReady(index)
            && !errorPages.contains(index)
            && !downloadingImages.contains(index)
            && !loadingPages.contains(index)
    }

    /// 盯着某一页，直到它出图或出错。
    ///
    /// 由占位视图的 `.task` 驱动：占位符在屏幕上就一直看着，视图消失时
    /// SwiftUI 取消这个 Task，看护自然结束。用轮询而不是一次性重试，是因为
    /// 卡死可以发生在任意时刻（取消随时可能来），一次性的 `.task` 只在
    /// 出现时跑一次，之后再卡就没人管了。
    func superviseLoading(of index: Int) async {
        while !Task.isCancelled {
            if isImageReady(index) || errorPages.contains(index) { return }
            if isStalled(index) {
                if imageURLs[index] == nil {
                    await loadPageWithRetry(index)
                } else {
                    await downloadImageData(index)
                }
            }
            // 只在占位符还挂着时轮询，间隔取得比人眼察觉卡顿的阈值大一点
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// 这一页的图片已经在手上了吗（Observable 层或 NSCache 里）。
    /// 预加载的取舍全看它——问「URL 有没有」是问错了问题。
    func isImageReady(_ index: Int) -> Bool {
        if cachedImages[index] != nil { return true }
        return Self.imageCache.object(forKey: cacheKey(for: index)) != nil
    }

    /// 预加载 —— 方向感知 + 由近及远
    ///
    /// 相比原来的固定窗口有三点改进:
    ///   1. 按翻页方向倾斜: 往后翻就多备后面的页，回头页只留 1~2 页兜底
    ///   2. 按距离排序后分批发出，保证「下一页」永远排在「下五页」前面拿到带宽
    ///   3. 每批之间检查取消，快速连翻时上一轮会被立刻中止
    func preload(around page: Int) async {
        let budget = effectivePreloadCount
        let forward = lastPreloadAnchor.map { page >= $0 } ?? true
        lastPreloadAnchor = page

        // 顺着阅读方向多铺，逆向只留少量回看余量
        let ahead = forward ? budget : max(1, budget / 3)
        let behind = forward ? max(1, budget / 4) : budget

        let lo = max(0, page - behind)
        let hi = min(totalPages - 1, page + ahead)
        guard lo <= hi else { return }

        // 判据是「图片数据到没到」，不是「URL 解析没解析」。
        //
        // 这里原本写的是 `imageURLs[$0] == nil`：一旦某页的 URL 解析过，
        // 它就永远进不了候选，于是 downloadImageData 再也不会为它跑。
        // 结果就是翻到那一页才开始现场下载——左右翻页模式下每翻一页都要等，
        // 预加载看起来完全没生效。
        let candidates = (lo...hi)
            .filter { p in
                p != page
                    && !isImageReady(p)
                    && !loadingPages.contains(p)
                    && !downloadingImages.contains(p)
            }
            // 距离近的先来；同距离时优先阅读方向那一侧
            .sorted {
                let d0 = abs($0 - page), d1 = abs($1 - page)
                if d0 != d1 { return d0 < d1 }
                return forward ? ($0 > $1) : ($0 < $1)
            }
        guard !candidates.isEmpty else { return }

        // 分批而不是一次性全丢进 TaskGroup:
        // 全量并发时第 6 页可能比第 1 页先回来，用户等的恰恰是第 1 页
        let batchSize = 3
        for chunk in stride(from: 0, to: candidates.count, by: batchSize) {
            if Task.isCancelled { return }
            let batch = candidates[chunk..<min(chunk + batchSize, candidates.count)]
            await withTaskGroup(of: Void.self) { group in
                for p in batch {
                    group.addTask { [weak self] in
                        guard let self, !Task.isCancelled else { return }
                        await self.loadPage(p)
                        guard !Task.isCancelled else { return }
                        await self.downloadImageData(p)
                    }
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

        // 同样走 EhAPI 的回退链路, 不再裸连 (issue #6)
        let html = try await EhAPI.shared.fetchHTML(url: url.absoluteString)

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
