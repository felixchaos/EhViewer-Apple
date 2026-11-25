import Foundation
import EhModels
import EhSettings
import EhParser

// MARK: - SpiderQueen (对应 Android SpiderQueen.java)
// 画廊图片加载引擎核心，使用 Swift Actor 保证线程安全
// 原始 Android 版本使用 AsyncTask + Thread 池，此处使用 structured concurrency

public actor SpiderQueen {

    // MARK: - 状态常量 (与 Android 保持一致)

    public static let stateNone    = 0
    public static let stateLoading = 1
    public static let stateFinish  = 2
    public static let stateFailed  = 3

    public enum Mode: Sendable {
        case read      // 阅读模式 (顺序预加载)
        case download  // 下载模式 (全量下载)
    }

    // MARK: - 属性

    public let galleryInfo: GalleryInfo
    public private(set) var spiderInfo: SpiderInfo
    private var mode: Mode
    private var pageStates: [Int]       // 每页的加载状态
    private var imageUrls: [String?]    // 每页的图片 URL
    private var showKey: String?        // showpage API 的 showKey
    private var activeTasks: [Int: Task<Void, Never>] = [:]
    private let previewRequests = DownloadPreviewRequests()
    // Persisted geometry may describe a different thumbnail setting.
    private var downloadPreviewWidth: Int?

    /// 并发下载数 — 从 AppSettings 读取用户设置 (对齐 Android SpiderQueen.mWorkerPool 大小)
    private var maxConcurrent: Int {
        min(5, AppSettings.shared.multiThreadDownload)
    }

    private let receive: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let imageRequestTimeout: TimeInterval

    /// 在全局速率限制下发起网络请求 — 防止跨实例并发失控 (V-09)
    /// 所有 SpiderQueen 实例共享同一个 EhRateLimiter，全局最多 5 个并发图片请求
    private func rateLimitedData(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await EhRateLimiter.shared.acquireImageSlot()
        do {
            // A cancelled waiter may still receive the slot. Return it
            // without starting a new request for a retired transfer.
            try Task.checkCancellation()
            let result = try await receive(request)
            await EhRateLimiter.shared.releaseImageSlot()
            return result
        } catch {
            await EhRateLimiter.shared.releaseImageSlot()
            throw error
        }
    }

    /// 图片存储管理器 (对应 Android SpiderDen)
    private let spiderDen: SpiderDen

    /// 回调通知
    public weak var delegate: SpiderDelegate?

    // MARK: - 生命周期

    public init(galleryInfo: GalleryInfo, spiderInfo: SpiderInfo, mode: Mode = .read) {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = .shared
        let inactivity = TimeInterval(max(10, min(120, AppSettings.shared.downloadTimeout)))
        configuration.timeoutIntervalForRequest = inactivity
        configuration.timeoutIntervalForResource = inactivity * 4
        let session = URLSession(configuration: configuration)
        let den = SpiderDen(galleryInfo: galleryInfo, mode: mode == .download ? .download : .read)
        self.init(galleryInfo: galleryInfo, spiderInfo: spiderInfo, mode: mode, spiderDen: den,
                  imageRequestTimeout: inactivity) { request in try await session.data(for: request) }
    }

    init(
        galleryInfo: GalleryInfo, spiderInfo: SpiderInfo, mode: Mode, spiderDen: SpiderDen,
        imageRequestTimeout: TimeInterval, receive: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) {
        self.galleryInfo = galleryInfo
        self.spiderInfo = spiderInfo
        self.mode = mode
        self.spiderDen = spiderDen
        self.receive = receive
        self.imageRequestTimeout = imageRequestTimeout

        let pageCount = max(0, galleryInfo.pages)
        self.pageStates = Array(repeating: Self.stateNone, count: pageCount)
        self.imageUrls = Array(repeating: nil, count: pageCount)
    }

    // MARK: - 公共接口

    /// 请求加载指定页面 (对应 Android request)
    public func request(index: Int, force: Bool = false) {
        guard index >= 0 && index < pageStates.count else { return }

        if !force && (pageStates[index] == Self.stateLoading || pageStates[index] == Self.stateFinish) {
            return
        }

        pageStates[index] = Self.stateLoading

        // 取消旧任务
        activeTasks[index]?.cancel()

        // 启动新任务
        let task = Task { [weak self] in
            guard let self = self else { return }
            await self.loadPage(index: index)
        }
        activeTasks[index] = task
    }

    /// 批量预加载 (对应 Android preloadPages)
    public func preload(around index: Int, range: Int = 5) {
        let start = max(0, index - 1)
        let end = min(pageStates.count, index + range)

        for i in start..<end {
            request(index: i)
        }
    }

    /// 开始下载模式 (对应 Android setMode(MODE_DOWNLOAD))
    /// 使用 TaskGroup 实现并发控制，等待所有页面下载完成后再返回
    public func startDownload() async {
        guard !Task.isCancelled else { return }
        mode = .download

        // Wait for storage before any worker starts, including when the
        // download was opened before the init-time mode task had run.
        await spiderDen.setMode(.download)
        let pending = pageStates.indices.filter { pageStates[$0] != Self.stateFinish }
        await DownloadPageBatch.run(pages: pending, concurrency: maxConcurrent,
                                    retryDelay: Self.retryDelay) { [weak self] index, finalAttempt in
            guard let self else { return false }
            return await self.downloadPageAttempt(index: index, finalAttempt: finalAttempt)
        }
    }

    private func downloadPageAttempt(index: Int, finalAttempt: Bool) async -> Bool {
        guard !Task.isCancelled else { return false }
        pageStates[index] = Self.stateLoading
        return await loadPage(index: index, batched: true, finalAttempt: finalAttempt)
    }

    private nonisolated static func retryDelay(_ attempt: Int) async {
        let base = max(500, min(2_000, AppSettings.shared.downloadDelay))
        try? await Task.sleep(for: .milliseconds(base * (1 << attempt)))
    }

    /// 获取页面状态
    public func getPageState(_ index: Int) -> Int {
        guard index >= 0 && index < pageStates.count else { return Self.stateNone }
        return pageStates[index]
    }

    /// 获取页面图片 URL (远程或本地)
    public func getImageUrl(_ index: Int) -> String? {
        guard index >= 0 && index < imageUrls.count else { return nil }
        return imageUrls[index]
    }

    /// 获取本地图片文件 URL (用于显示已下载的图片)
    public func getLocalImageUrl(_ index: Int) async -> URL? {
        return await spiderDen.getImageFileURL(index: index)
    }

    /// 读取图片数据 (从缓存或下载目录)
    public func getImageData(_ index: Int) async -> Data? {
        return await spiderDen.read(index: index)
    }

    /// 取消所有任务
    public func cancelAll() {
        for (_, task) in activeTasks {
            task.cancel()
        }
        activeTasks.removeAll()
    }

    /// 设置回调代理
    public func setDelegate(_ delegate: SpiderDelegate?) {
        self.delegate = delegate
    }

    /// 获取当前 SpiderInfo (包含已更新的 pTokenMap)
    public func getSpiderInfo() -> SpiderInfo {
        return spiderInfo
    }

    /// 更新 pToken (用于外部添加)
    public func updatePToken(index: Int, token: String) {
        spiderInfo.pTokenMap[index] = token
    }

    // MARK: - 核心加载管线 (对应 Android SpiderQueen.run)

    /// 加载单页图片 (对齐 Android SpiderWorker.downloadImage 最多重试 5 次)
    /// 管线: 检查缓存 → 获取 pToken → 构建页面 URL → 获取图片 URL → 下载图片 → 存储
    @discardableResult
    private func loadPage(index: Int, batched: Bool = false, finalAttempt: Bool = true) async -> Bool {
        let maxRetries = batched ? 1 : 5
        var lastError: Error?

        for attempt in 0..<maxRetries {
            do {
                try Task.checkCancellation()
                // 0. 检查是否已在缓存/下载目录中 (快速路径)
                if await spiderDen.contain(index: index) {
                    pageStates[index] = Self.stateFinish
                    if let fileUrl = await spiderDen.getImageFileURL(index: index) {
                        imageUrls[index] = fileUrl.absoluteString
                        await delegate?.onPageLoaded(index: index, imageUrl: fileUrl.absoluteString)
                    }
                    activeTasks.removeValue(forKey: index)
                    return false
                }

                // 1. 获取 pToken
                let pToken = try await getPToken(for: index)

                // 2. 获取图片 URL
                let imageUrl: String
                let originImageUrl: String?
                if showKey == nil {
                    let result = try await fetchPageHtml(gid: galleryInfo.gid, index: index, pToken: pToken)
                    showKey = result.showKey
                    imageUrl = result.imageUrl
                    originImageUrl = result.originImageUrl
                } else {
                    // showKey is guaranteed non-nil here
                    let currentShowKey = showKey ?? ""
                    let result = try await fetchPageApi(
                        gid: galleryInfo.gid,
                        index: index,
                        pToken: pToken,
                        showKey: currentShowKey
                    )
                    if let newShowKey = result.showKey {
                        showKey = newShowKey
                    }
                    imageUrl = result.imageUrl
                    originImageUrl = result.originImageUrl
                }

                // 2.5 如果用户启用了"下载原始图片"且有原图 URL，优先使用 (对齐 Android downloadOriginImage)
                let finalImageUrl: String
                if AppSettings.shared.downloadOriginImage,
                   let origin = originImageUrl, !origin.isEmpty {
                    finalImageUrl = origin
                } else {
                    finalImageUrl = imageUrl
                }

                // 3. URL 有效性
                guard !finalImageUrl.isEmpty else {
                    throw SpiderError.emptyImageUrl
                }

                // 4. 509 检测
                if finalImageUrl.contains("509.gif") || finalImageUrl.contains("509s.gif") {
                    pageStates[index] = Self.stateFailed
                    await delegate?.onImageLimitReached()
                    activeTasks.removeValue(forKey: index)
                    return false
                }

                // 5. 下载图片并存储
                try Task.checkCancellation()
                try await downloadAndStore(imageUrl: finalImageUrl, index: index)
                try Task.checkCancellation()

                // 6. 保存结果
                imageUrls[index] = finalImageUrl
                pageStates[index] = Self.stateFinish
                await delegate?.onPageLoaded(index: index, imageUrl: finalImageUrl)
                activeTasks.removeValue(forKey: index)
                return false

            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    pageStates[index] = Self.stateNone
                    activeTasks.removeValue(forKey: index)
                    return false
                }
                if let error = error as? SpiderError, case .diskFull = error {
                    pageStates[index] = Self.stateFailed
                    activeTasks.removeValue(forKey: index)
                    return false
                }
                lastError = error
                if batched {
                    // A failed page must release its worker before retrying;
                    // finish attempting untouched pages before backing off.
                    showKey = nil
                    if !finalAttempt {
                        pageStates[index] = Self.stateNone
                        return true
                    }
                } else {
                    if attempt > 0 { showKey = nil }
                    if attempt < maxRetries - 1 { await Self.retryDelay(attempt) }
                }
            }
        }

        // 所有重试失败
        pageStates[index] = Self.stateFailed
        await delegate?.onPageFailed(index: index, error: lastError ?? SpiderError.networkError)
        activeTasks.removeValue(forKey: index)
        return false
    }

    /// 下载图片并存储到 SpiderDen (对齐 Android: 共享 session 保持 cookies)
    private func downloadAndStore(imageUrl: String, index: Int) async throws {
        guard let url = URL(string: imageUrl) else {
            throw SpiderError.invalidUrl
        }

        // 使用带 cookies 的 session 下载图片
        var request = URLRequest(url: url)
        request.timeoutInterval = imageRequestTimeout
        let (data, response) = try await rateLimitedData(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw SpiderError.networkError
        }

        // 检查数据有效性 (反劫持检测 - 纯文本响应)
        if data.count < 1000 {
            // 检查是否为纯文本（可能被劫持）
            if let text = String(data: data, encoding: .utf8),
               text.contains("<html") || text.contains("<!DOCTYPE") {
                throw SpiderError.antiHijackDetected
            }
        }

        // 从 URL 或 Content-Type 获取扩展名
        let ext = getImageExtension(from: imageUrl, response: httpResponse)

        // 存储到 SpiderDen（先检查磁盘空间）
        if !SpiderDen.hasSufficientDiskSpace(bytes: Int64(data.count) + 10 * 1024 * 1024) {
            // 磁盘满: 通知代理暂停所有下载，不再重试当前页
            await delegate?.onDiskFull()
            throw SpiderError.diskFull
        }

        try Task.checkCancellation()
        let success = await spiderDen.write(data: data, index: index, extension: ext)
        if !success {
            throw SpiderError.storageFailed
        }
    }

    /// 获取图片扩展名
    private func getImageExtension(from url: String, response: HTTPURLResponse) -> String {
        // 从 URL 提取
        if let urlObj = URL(string: url) {
            let ext = urlObj.pathExtension.lowercased()
            if !ext.isEmpty && SpiderDen.supportedExtensions.contains(".\(ext)") {
                return ".\(ext)"
            }
        }

        // 从 Content-Type 推断
        if let contentType = response.value(forHTTPHeaderField: "Content-Type") {
            if contentType.contains("jpeg") || contentType.contains("jpg") {
                return ".jpg"
            } else if contentType.contains("png") {
                return ".png"
            } else if contentType.contains("gif") {
                return ".gif"
            } else if contentType.contains("webp") {
                return ".webp"
            }
        }

        return ".jpg" // 默认
    }

    // MARK: - pToken 管理

    /// 获取指定页面的 pToken (对齐 Android SpiderQueen.getPTokenFromInternet)
    private func getPToken(for index: Int) async throws -> String {
        // 优先从 SpiderInfo 缓存获取
        if let token = spiderInfo.pTokenMap[index] {
            return token
        }

        if mode == .download {
            // Learn current geometry even when the first missing image is far
            // into a resumed transfer. Never divide by a guessed page size.
            if downloadPreviewWidth == nil {
                try await loadDownloadPreview(page: 0, covering: index)
            }
            if let token = spiderInfo.pTokenMap[index] { return token }
            guard let width = downloadPreviewWidth else { throw SpiderError.pTokenNotFound }
            try await loadDownloadPreview(page: index / width, covering: index)
        } else {
            let detailPage = index / (spiderInfo.previewPerPage > 0 ? spiderInfo.previewPerPage : 20)
            let tokens = try await fetchPreviewTokens(page: detailPage)
            try Task.checkCancellation()
            spiderInfo.pTokenMap.merge(tokens) { _, new in new }
        }
        guard let token = spiderInfo.pTokenMap[index] else { throw SpiderError.pTokenNotFound }
        return token
    }

    private func loadDownloadPreview(page: Int, covering index: Int) async throws {
        _ = try await previewRequests.load(page: page) {
            try await self.cacheDownloadPreview(page: page, covering: index)
        }
        try Task.checkCancellation()
    }

    private func cacheDownloadPreview(page: Int, covering index: Int) async throws -> [Int: String] {
        // Commit the shared result before releasing the in-flight request.
        // A queued worker whose token is now cached must not fetch it again.
        if page == 0, downloadPreviewWidth != nil { return [:] }
        if page > 0, spiderInfo.pTokenMap[index] != nil { return [:] }

        let tokens = try await fetchPreviewTokens(page: page)
        try Task.checkCancellation()
        spiderInfo.pTokenMap.merge(tokens) { _, new in new }
        // Only the first page establishes width; the last can be shorter.
        // Do not learn an incorrect width from a sparse/malformed response.
        if page == 0, tokens.keys.allSatisfy({ $0 < tokens.count }) {
            downloadPreviewWidth = tokens.count
            spiderInfo.previewPerPage = tokens.count
        }
        return tokens
    }

    private func fetchPreviewTokens(page detailPage: Int) async throws -> [Int: String] {
        let site = AppSettings.shared.gallerySite
        let siteUrl = EhURL.host(for: site)
        let urlStr = "\(siteUrl)g/\(galleryInfo.gid)/\(galleryInfo.token)/\(detailPage > 0 ? "?p=\(detailPage)" : "")"
        guard let url = URL(string: urlStr) else {
            throw SpiderError.invalidUrl
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue(EhURL.referer(for: site), forHTTPHeaderField: "Referer")
        request.timeoutInterval = 15

        let (data, response) = try await rateLimitedData(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw SpiderError.networkError
        }
        let html = String(data: data, encoding: .utf8) ?? ""

        // Extract 1-based preview URLs; only merge tokens for this gallery.
        let pattern = try NSRegularExpression(pattern: #"/s/([0-9a-f]+)/(\d+)-(\d+)"#)
        let matches = pattern.matches(in: html, range: NSRange(html.startIndex..., in: html))
        var tokens: [Int: String] = [:]
        for m in matches {
            guard let ptRange = Range(m.range(at: 1), in: html),
                  let gidRange = Range(m.range(at: 2), in: html),
                  let pnRange = Range(m.range(at: 3), in: html),
                  Int64(html[gidRange]) == galleryInfo.gid,
                  let page = Int(html[pnRange]), page > 0, page <= galleryInfo.pages else { continue }
            tokens[page - 1] = String(html[ptRange])
        }
        guard !tokens.isEmpty else { throw SpiderError.pTokenNotFound }
        return tokens
    }

    // MARK: - 网络请求

    /// 通过 GET 获取页面 HTML (首次, 获取 showKey)
    private func fetchPageHtml(gid: Int64, index: Int, pToken: String) async throws -> PageResult {
        let site = AppSettings.shared.gallerySite
        let urlString = EhURL.pageUrl(gid: gid, index: index, pToken: pToken, site: site)
        guard let url = URL(string: urlString) else {
            throw SpiderError.invalidUrl
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(EhURL.referer(for: site), forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await rateLimitedData(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw SpiderError.networkError
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw SpiderError.invalidResponseData
        }

        let result = try GalleryPageParser.parse(html)
        return PageResult(
            imageUrl: result.imageUrl,
            showKey: result.showKey,
            skipHathKey: result.skipHathKey,
            originImageUrl: result.originImageUrl
        )
    }

    /// 通过 POST API 获取图片 URL (showpage)
    private func fetchPageApi(gid: Int64, index: Int, pToken: String, showKey: String) async throws -> PageResult {
        let site = AppSettings.shared.gallerySite
        guard let url = URL(string: EhURL.apiUrl(for: site)) else {
            throw SpiderError.invalidUrl
        }

        let jsonBody: [String: Any] = [
            "method": "showpage",
            "gid": gid,
            "page": index + 1,   // 服务端 1-based
            "imgkey": pToken,
            "showkey": showKey
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: jsonBody)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(EhURL.referer(for: site), forHTTPHeaderField: "Referer")
        request.setValue(EhURL.origin(for: site), forHTTPHeaderField: "Origin")
        request.httpBody = jsonData
        request.timeoutInterval = 15

        let (data, response) = try await rateLimitedData(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw SpiderError.networkError
        }

        let result = try GalleryPageApiParser.parse(data)
        return PageResult(
            imageUrl: result.imageUrl,
            showKey: result.showKey,
            skipHathKey: result.skipHathKey,
            originImageUrl: result.originImageUrl
        )
    }

    private struct PageResult {
        var imageUrl: String
        var showKey: String?
        var skipHathKey: String?
        var originImageUrl: String?
    }
}

// MARK: - SpiderDelegate

public protocol SpiderDelegate: AnyObject, Sendable {
    func onPageLoaded(index: Int, imageUrl: String) async
    func onPageFailed(index: Int, error: Error) async
    func onImageLimitReached() async
    func onDownloadProgress(downloaded: Int, total: Int) async
    func onDiskFull() async
}

// MARK: - 错误

public enum SpiderError: LocalizedError, Sendable {
    case pTokenNotFound
    case emptyImageUrl
    case imageLimitReached
    case antiHijackDetected
    case invalidUrl
    case networkError
    case invalidResponseData
    case notImplemented
    case storageFailed
    case diskFull

    public var errorDescription: String? {
        switch self {
        case .pTokenNotFound: return "pToken not found"
        case .emptyImageUrl: return "Empty image URL"
        case .imageLimitReached: return "509 Image limit reached"
        case .antiHijackDetected: return "Anti-hijack: pure text response"
        case .invalidUrl: return "Invalid URL"
        case .networkError: return "Network request failed"
        case .invalidResponseData: return "Invalid response data"
        case .notImplemented: return "Not implemented"
        case .storageFailed: return "Failed to save image to disk"
        case .diskFull: return "磁盘空间不足，无法保存图片"
        }
    }
}
