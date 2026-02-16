import Foundation
import EhModels
import EhSettings
import EhParser
import EhCookie
import EhDNS

// MARK: - EhAPI 核心引擎 (对应 Android EhEngine.java)
// 所有方法使用 async/await，替代 Android 的 AsyncTask 模式

public actor EhAPI {
    public static let shared = EhAPI()

    /// 通用 URLSession (对应 Android mOkHttpClient)
    /// 不使用自定义 delegate — 与 Safari 等系统 App 行为完全一致
    /// 让系统自动处理 TLS 验证和代理路由
    private let session: URLSession

    /// 图片专用 URLSession (对应 Android mImageOkHttpClient，不跟随重定向)
    /// 仅使用最小化 delegate 控制重定向行为
    private let imageSession: URLSession

    /// 域名前置专用 URLSession (内置 DNS 直连 + 自定义 TLS 验证)
    /// 对应 Android: OkHttp 的 Dns 接口 (EhDns.kt) 在 socket 层用内置 IP 解析域名
    /// iOS 无等效接口，因此通过 URL 中替换 IP + Host header 保留域名 + 自定义证书验证实现
    /// 用于: VPN 规则模式分流不当 / DNS 污染 / GFW SNI 拦截时，作为自动回退方案
    private let directSession: URLSession

    /// 域名前置 + 不跟随重定向 (图片请求的回退)
    private let directImageSession: URLSession

    /// 最大重试次数 (超时/连接错误时自动重试)
    private static let maxRetries = 2

    private init() {
        // 共享缓存
        let sharedCache = URLCache(
            memoryCapacity: 20 * 1024 * 1024,    // 20MB (对标 Android getMemoryCacheMaxSize)
            diskCapacity: 320 * 1024 * 1024,      // 320MB (对标 Android Conaco diskCacheMaxSize)
            directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("http_cache")
        )

        // 通用 session — 零自定义，与 Safari 行为完全一致
        // 不设置自定义 delegate，不设置 connectionProxyDictionary
        // 让系统自动处理 VPN/代理/TLS 全部流程
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.httpCookieStorage = .shared
        config.urlCache = sharedCache
        config.allowsCellularAccess = true
        config.waitsForConnectivity = true  // 等待网络就绪再发请求
        session = URLSession(configuration: config)

        // 图片 session — 仅自定义重定向行为 (不跟随重定向)
        let imgConfig = URLSessionConfiguration.default
        imgConfig.timeoutIntervalForRequest = 20
        imgConfig.timeoutIntervalForResource = 20
        imgConfig.httpCookieStorage = .shared
        imgConfig.urlCache = sharedCache
        imgConfig.allowsCellularAccess = true
        imgConfig.waitsForConnectivity = true
        imageSession = URLSession(configuration: imgConfig, delegate: RedirectBlockDelegate(), delegateQueue: nil)

        // === 域名前置回退 Session (对应 Android OkHttp Dns 接口内置域名解析) ===
        // 当主要 session 因 VPN 分流不当 / DNS 污染 / GFW SNI 拦截导致失败时，
        // 使用内置 IP 地址直连服务器，复刻 Android 端的默认行为
        let directConfig = URLSessionConfiguration.default
        directConfig.timeoutIntervalForRequest = 15
        directConfig.timeoutIntervalForResource = 60
        directConfig.httpCookieStorage = .shared
        directConfig.urlCache = sharedCache
        directConfig.allowsCellularAccess = true
        directConfig.connectionProxyDictionary = [:]  // 绕过 HTTP 代理设置
        directSession = URLSession(
            configuration: directConfig,
            delegate: DomainFrontingDelegate(blockRedirects: false),
            delegateQueue: nil
        )

        let directImgConfig = URLSessionConfiguration.default
        directImgConfig.timeoutIntervalForRequest = 15
        directImgConfig.timeoutIntervalForResource = 30
        directImgConfig.httpCookieStorage = .shared
        directImgConfig.urlCache = sharedCache
        directImgConfig.allowsCellularAccess = true
        directImgConfig.connectionProxyDictionary = [:]  // 绕过 HTTP 代理设置
        directImageSession = URLSession(
            configuration: directImgConfig,
            delegate: DomainFrontingDelegate(blockRedirects: true),
            delegateQueue: nil
        )
    }

    // MARK: - 请求辅助

    /// 在发送请求前清洁 Cookie，先走系统代理/VPN，失败后回退到域名前置直连
    /// 对应 Android: OkHttp 默认使用内置 DNS，iOS 需手动实现回退逻辑
    private func sanitizedData(for request: URLRequest) async throws -> (Data, URLResponse) {
        if let url = request.url {
            EhCookieManager.shared.sanitizeCookiesForRequest(url: url)
        }

        // 全局 API 速率限制 — 防止 IP 封禁 (V-08)
        await EhRateLimiter.shared.waitApiSlot()

        do {
            return try await executeWithRetry(maxRetries: Self.maxRetries) {
                try await self.session.data(for: request)
            }
        } catch let error where Self.shouldTryDirectFallback(error) {
            // 主要路径失败 → 尝试域名前置直连 (对应 Android 内置 DNS)
            return try await attemptDomainFronting(for: request, using: directSession, originalError: error)
        }
    }

    /// 不跟随重定向的请求 (对应 Android OkHttpClient followRedirects=false)
    private func noRedirectData(for request: URLRequest) async throws -> (Data, URLResponse) {
        if let url = request.url {
            EhCookieManager.shared.sanitizeCookiesForRequest(url: url)
        }

        // 全局 API 速率限制 — 防止 IP 封禁 (V-08)
        await EhRateLimiter.shared.waitApiSlot()

        do {
            return try await executeWithRetry(maxRetries: Self.maxRetries) {
                try await self.imageSession.data(for: request)
            }
        } catch let error where Self.shouldTryDirectFallback(error) {
            return try await attemptDomainFronting(for: request, using: directImageSession, originalError: error)
        }
    }

    // MARK: - 域名前置回退 (对应 Android OkHttp Dns 接口)

    /// 使用内置 IP 直连服务器 (域名前置)
    /// Android 端 OkHttp 的 Dns 接口在 socket 层替换 IP 不影响 TLS SNI
    /// iOS URLSession 无此能力，因此通过 URL 替换 IP + Host header + 自定义证书验证实现
    private func attemptDomainFronting(
        for request: URLRequest,
        using fallbackSession: URLSession,
        originalError: Error
    ) async throws -> (Data, URLResponse) {
        let frontedRequest = EhDNS.shared.forceDomainFronting(to: request)

        // 如果没有内置 IP (forceDomainFronting 返回原始请求)，直接抛原始错误
        guard frontedRequest.url != request.url else {
            print("[EhAPI] 无内置 IP 可用于域名前置，抛出原始错误")
            throw originalError
        }

        let host = request.url?.host ?? "unknown"
        let ip = frontedRequest.url?.host ?? "unknown"
        print("[EhAPI] 主要请求失败 (\(originalError.localizedDescription))，尝试域名前置直连: \(host) → \(ip)")

        do {
            return try await fallbackSession.data(for: frontedRequest)
        } catch {
            // 域名前置也失败了，抛出原始错误 (用户更容易理解)
            print("[EhAPI] 域名前置也失败: \(error.localizedDescription)")
            throw originalError
        }
    }

    /// 判断是否应该尝试域名前置直连回退
    private static func shouldTryDirectFallback(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .cannotConnectToHost,    // 无法连接 (代理 503 / 连接被拒)
             .cannotFindHost,         // DNS 解析失败
             .dnsLookupFailed,        // DNS 查找失败
             .timedOut,               // 超时 (可能被 GFW RST)
             .networkConnectionLost,  // 连接中断 (代理返回 503)
             .secureConnectionFailed: // TLS 握手失败
            return true
        default:
            return false
        }
    }

    // MARK: - 重试逻辑

    /// 带指数退避的自动重试 (超时/连接失败/DNS 解析失败时重试)
    private func executeWithRetry(
        maxRetries: Int,
        operation: @Sendable () async throws -> (Data, URLResponse)
    ) async throws -> (Data, URLResponse) {
        var lastError: Error?
        for attempt in 0...maxRetries {
            do {
                return try await operation()
            } catch let error as URLError where Self.isRetryableError(error) {
                lastError = error
                if attempt < maxRetries {
                    let delay = Double(attempt + 1) * 1.5  // 1.5s, 3s
                    print("[EhAPI] Request failed (\(error.code.rawValue): \(Self.errorCodeName(error.code))), retry \(attempt + 1)/\(maxRetries) after \(delay)s")
                    try? await Task.sleep(for: .seconds(delay))
                }
            } catch {
                throw error  // 非可重试错误，直接抛出
            }
        }
        throw lastError ?? URLError(.unknown)  // 所有重试都失败
    }

    /// 判断 URLError 是否可重试
    private static func isRetryableError(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut,
             .cannotConnectToHost,
             .networkConnectionLost,
             .secureConnectionFailed,
             .notConnectedToInternet,
             .cannotFindHost,
             .dnsLookupFailed,
             .internationalRoamingOff,
             .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    /// 错误码名称 (用于日志)
    private static func errorCodeName(_ code: URLError.Code) -> String {
        switch code {
        case .timedOut: return "timedOut"
        case .cannotConnectToHost: return "cannotConnectToHost"
        case .networkConnectionLost: return "networkConnectionLost"
        case .notConnectedToInternet: return "notConnectedToInternet"
        case .cannotFindHost: return "cannotFindHost"
        case .dnsLookupFailed: return "dnsLookupFailed"
        default: return "code(\(code.rawValue))"
        }
    }

    // MARK: - 公开 API 方法

    /// 登录 (对应 Android signIn)
    /// 先尝试 API 登录，如果被 Cloudflare 拦截 (403) 则抛出 cloudflare403 提示用户使用网页登录
    public func signIn(username: String, password: String) async throws -> String {
        guard let url = URL(string: EhURL.signInUrl) else {
            throw EhError.invalidUrl
        }

        let request = EhRequestBuilder.buildPostFormRequest(
            url: url,
            formFields: [
                ("UserName", username),
                ("PassWord", password),
                ("submit", "Log me in"),
                ("CookieDate", "1"),
                ("temporary_https", "off"),
            ],
            referer: EhURL.signInReferer,
            origin: EhURL.signInOrigin
        )

        let (data, response) = try await sanitizedData(for: request)

        // 检测 Cloudflare 拦截: forums.e-hentai.org 可能会返回 403 + Cloudflare challenge
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 403 {
            let body = String(data: data, encoding: .utf8) ?? ""
            if body.lowercased().contains("cloudflare") || body.lowercased().contains("cf-") ||
               body.contains("Just a moment") || body.contains("challenge-platform") {
                throw EhError.cloudflare403
            }
        }

        try checkResponse(response, data: data)

        let body = String(data: data, encoding: .utf8) ?? ""
        return try SignInParser.parse(body)
    }

    /// 获取画廊列表 (对应 Android getGalleryList)
    public func getGalleryList(url: String) async throws -> GalleryListResult {
        guard let requestUrl = URL(string: url) else {
            throw EhError.invalidUrl
        }

        let site = AppSettings.shared.gallerySite
        let request = EhRequestBuilder.buildGetRequest(
            url: requestUrl,
            referer: EhURL.referer(for: site)
        )

        let (data, response) = try await sanitizedData(for: request)
        try checkResponse(response, data: data, requestUrl: url)

        let body = String(data: data, encoding: .utf8) ?? ""
        return try GalleryListParser.parse(body)
    }

    /// 获取画廊详情 (对应 Android getGalleryDetail)
    public func getGalleryDetail(url: String) async throws -> GalleryDetail {
        guard let requestUrl = URL(string: url) else {
            throw EhError.invalidUrl
        }

        let site = AppSettings.shared.gallerySite
        let request = EhRequestBuilder.buildGetRequest(
            url: requestUrl,
            referer: EhURL.referer(for: site)
        )

        let (data, response) = try await sanitizedData(for: request)
        try checkResponse(response, data: data)

        let body = String(data: data, encoding: .utf8) ?? ""
        return try GalleryDetailParser.parse(body)
    }

    /// 批量补全画廊信息 (对应 Android fillGalleryListByApi, JSON API: gdata)
    public func fillGalleryListByApi(galleries: inout [GalleryInfo]) async throws {
        let site = AppSettings.shared.gallerySite
        guard let url = URL(string: EhURL.apiUrl(for: site)) else {
            throw EhError.invalidUrl
        }

        // 每次最多 25 项
        let batchSize = 25
        for startIndex in stride(from: 0, to: galleries.count, by: batchSize) {
            let endIndex = min(startIndex + batchSize, galleries.count)
            let batch = galleries[startIndex..<endIndex]

            let gidList = batch.map { [$0.gid, $0.token] as [Any] }
            let jsonBody: [String: Any] = [
                "method": "gdata",
                "gidlist": gidList,
                "namespace": 1,
            ]

            let jsonData = try JSONSerialization.data(withJSONObject: jsonBody)
            let request = EhRequestBuilder.buildPostJSONRequest(
                url: url,
                json: jsonData,
                referer: EhURL.referer(for: site),
                origin: EhURL.origin(for: site)
            )

            let (data, response) = try await sanitizedData(for: request)
            try checkResponse(response, data: data)

            try GalleryApiParser.parse(data, galleries: &galleries)
        }
    }

    /// 评分画廊 (对应 Android rateGallery, JSON API: rategallery)
    public func rateGallery(
        apiUid: Int64, apiKey: String,
        gid: Int64, token: String, rating: Float
    ) async throws -> RateResult {
        let site = AppSettings.shared.gallerySite
        guard let url = URL(string: EhURL.apiUrl(for: site)) else {
            throw EhError.invalidUrl
        }

        let jsonBody: [String: Any] = [
            "method": "rategallery",
            "apiuid": apiUid,
            "apikey": apiKey,
            "gid": gid,
            "token": token,
            "rating": Int(ceil(rating * 2)),  // 重要: rating × 2 向上取整
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: jsonBody)
        let detailUrl = EhURL.galleryDetailUrl(gid: gid, token: token, site: site)
        let request = EhRequestBuilder.buildPostJSONRequest(
            url: url,
            json: jsonData,
            referer: detailUrl,
            origin: EhURL.origin(for: site)
        )

        let (data, response) = try await sanitizedData(for: request)
        try checkResponse(response, data: data)

        return try RateGalleryParser.parse(data)
    }

    /// 获取图片页面信息 (对应 Android getGalleryPageApi, JSON API: showpage)
    public func getGalleryPageApi(
        gid: Int64, index: Int, pToken: String,
        showKey: String, previousPToken: String? = nil
    ) async throws -> GalleryPageResult {
        let site = AppSettings.shared.gallerySite
        guard let url = URL(string: EhURL.apiUrl(for: site)) else {
            throw EhError.invalidUrl
        }

        let jsonBody: [String: Any] = [
            "method": "showpage",
            "gid": gid,
            "page": index + 1,   // 重要: 服务端 1-based
            "imgkey": pToken,
            "showkey": showKey,
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: jsonBody)
        // 对齐 Android: 无 previousPToken 时不发送 Referer (referer=null)
        let referer: String?
        if index > 0, let prev = previousPToken {
            referer = EhURL.pageUrl(gid: gid, index: index - 1, pToken: prev, site: site)
        } else {
            referer = nil
        }

        let request = EhRequestBuilder.buildPostJSONRequest(
            url: url,
            json: jsonData,
            referer: referer,
            origin: EhURL.origin(for: site)
        )

        let (data, response) = try await sanitizedData(for: request)
        try checkResponse(response, data: data)

        return try GalleryPageApiParser.parse(data)
    }

    // MARK: - 收藏 API (对应 Android getFavorites / addFavorites / modifyFavorites)

    /// 获取收藏列表 (对应 Android getFavorites)
    public func getFavorites(url: String) async throws -> GalleryListResult {
        guard let requestUrl = URL(string: url) else {
            throw EhError.invalidUrl
        }

        let site = AppSettings.shared.gallerySite
        let request = EhRequestBuilder.buildGetRequest(
            url: requestUrl,
            referer: EhURL.referer(for: site)
        )

        let (data, response) = try await sanitizedData(for: request)
        try checkResponse(response, data: data)

        let body = String(data: data, encoding: .utf8) ?? ""
        // FavoritesParser 复用 GalleryListParser (对应 Android FavoritesParser.parse)
        return try GalleryListParser.parse(body)
    }

    /// 添加收藏 (对应 Android addFavorites)
    /// dstCat: -1=删除, 0-9=收藏分组
    public func addFavorites(gid: Int64, token: String, dstCat: Int, note: String = "") async throws {
        let site = AppSettings.shared.gallerySite
        let catStr: String
        if dstCat == -1 {
            catStr = "favdel"
        } else if dstCat >= 0 && dstCat <= 9 {
            catStr = String(dstCat)
        } else {
            throw EhError.parseError("Invalid dstCat: \(dstCat)")
        }

        let urlString = EhURL.addFavoritesUrl(gid: gid, token: token, site: site)
        guard let url = URL(string: urlString) else {
            throw EhError.invalidUrl
        }

        let request = EhRequestBuilder.buildPostFormRequest(
            url: url,
            formFields: [
                ("favcat", catStr),
                ("favnote", note),
                ("submit", "Apply Changes"),
                ("update", "1"),
            ],
            referer: urlString,
            origin: EhURL.origin(for: site)
        )

        let (data, response) = try await sanitizedData(for: request)
        try checkResponse(response, data: data)
    }

    /// 批量修改收藏 (对应 Android modifyFavorites)
    public func modifyFavorites(url: String, gidArray: [Int64], dstCat: Int) async throws -> GalleryListResult {
        let catStr: String
        if dstCat == -1 {
            catStr = "delete"
        } else if dstCat >= 0 && dstCat <= 9 {
            catStr = "fav\(dstCat)"
        } else {
            throw EhError.parseError("Invalid dstCat: \(dstCat)")
        }

        guard let requestUrl = URL(string: url) else {
            throw EhError.invalidUrl
        }

        var fields: [(String, String)] = [("ddact", catStr)]
        for gid in gidArray {
            fields.append(("modifygids[]", String(gid)))
        }
        fields.append(("apply", "Apply"))

        let site = AppSettings.shared.gallerySite
        let request = EhRequestBuilder.buildPostFormRequest(
            url: requestUrl,
            formFields: fields,
            referer: url,
            origin: EhURL.origin(for: site)
        )

        let (data, response) = try await sanitizedData(for: request)
        try checkResponse(response, data: data)

        let body = String(data: data, encoding: .utf8) ?? ""
        return try GalleryListParser.parse(body)
    }

    // MARK: - 评论 API (对应 Android commentGallery / voteComment)

    /// 发表/编辑评论 (对应 Android commentGallery)
    public func commentGallery(url: String, comment: String, editId: String? = nil) async throws -> GalleryCommentList {
        guard let requestUrl = URL(string: url) else {
            throw EhError.invalidUrl
        }

        var fields: [(String, String)]
        if let editId = editId {
            fields = [
                ("commenttext_edit", comment),
                ("edit_comment", editId),
            ]
        } else {
            fields = [
                ("commenttext_new", comment),
            ]
        }

        let site = AppSettings.shared.gallerySite
        let request = EhRequestBuilder.buildPostFormRequest(
            url: requestUrl,
            formFields: fields,
            referer: url,
            origin: EhURL.origin(for: site)
        )

        let (data, response) = try await sanitizedData(for: request)
        try checkResponse(response, data: data)

        let body = String(data: data, encoding: .utf8) ?? ""
        return try GalleryDetailParser.parseComments(body)
    }

    /// 评论投票 (对应 Android voteComment, JSON API: votecomment)
    public func voteComment(
        apiUid: Int64, apiKey: String,
        gid: Int64, token: String,
        commentId: Int64, commentVote: Int
    ) async throws -> VoteCommentResult {
        let site = AppSettings.shared.gallerySite
        guard let url = URL(string: EhURL.apiUrl(for: site)) else {
            throw EhError.invalidUrl
        }

        let jsonBody: [String: Any] = [
            "method": "votecomment",
            "apiuid": apiUid,
            "apikey": apiKey,
            "gid": gid,
            "token": token,
            "comment_id": commentId,
            "comment_vote": commentVote,
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: jsonBody)
        let request = EhRequestBuilder.buildPostJSONRequest(
            url: url,
            json: jsonData,
            referer: EhURL.referer(for: site),
            origin: EhURL.origin(for: site)
        )

        let (data, response) = try await sanitizedData(for: request)
        try checkResponse(response, data: data)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let voteScore = json["comment_score"] as? Int,
              let voteState = json["comment_vote"] as? Int
        else {
            throw EhError.parseError("Failed to parse votecomment response")
        }
        return VoteCommentResult(score: voteScore, vote: voteState)
    }

    // MARK: - Token API (对应 Android getGalleryToken, JSON API: gtoken)

    /// 获取画廊 Token (对应 Android getGalleryToken)
    public func getGalleryToken(gid: Int64, gtoken: String, page: Int) async throws -> String {
        let site = AppSettings.shared.gallerySite
        guard let url = URL(string: EhURL.apiUrl(for: site)) else {
            throw EhError.invalidUrl
        }

        let jsonBody: [String: Any] = [
            "method": "gtoken",
            "pagelist": [[gid, gtoken, page + 1]],
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: jsonBody)
        let request = EhRequestBuilder.buildPostJSONRequest(
            url: url,
            json: jsonData,
            referer: EhURL.referer(for: site),
            origin: EhURL.origin(for: site)
        )

        let (data, response) = try await sanitizedData(for: request)
        try checkResponse(response, data: data)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokenList = json["tokenlist"] as? [[String: Any]],
              let first = tokenList.first,
              let token = first["token"] as? String
        else {
            throw EhError.parseError("Failed to parse gtoken response")
        }
        return token
    }

    // MARK: - 预览 API (对应 Android getPreviewSet)

    /// 获取预览页 (对应 Android getPreviewSet)
    public func getPreviewSet(url: String) async throws -> (PreviewSet, Int) {
        guard let requestUrl = URL(string: url) else {
            throw EhError.invalidUrl
        }

        let site = AppSettings.shared.gallerySite
        let request = EhRequestBuilder.buildGetRequest(
            url: requestUrl,
            referer: EhURL.referer(for: site)
        )

        let (data, response) = try await sanitizedData(for: request)
        try checkResponse(response, data: data)

        let body = String(data: data, encoding: .utf8) ?? ""
        let previews = try GalleryDetailParser.parsePreviews(body)
        let pages = try GalleryDetailParser.parsePreviewPages(body)
        return (previews, pages)
    }

    /// 获取全部评论 (通过 hc=1 参数) (对应 Android 加载全部评论)
    public func getAllComments(gid: Int64, token: String) async throws -> GalleryCommentList {
        let site = AppSettings.shared.gallerySite
        let urlStr = "\(EhURL.origin(for: site))/g/\(gid)/\(token)/?hc=1"
        
        guard let requestUrl = URL(string: urlStr) else {
            throw EhError.invalidUrl
        }

        let request = EhRequestBuilder.buildGetRequest(
            url: requestUrl,
            referer: EhURL.referer(for: site)
        )

        let (data, response) = try await sanitizedData(for: request)
        try checkResponse(response, data: data)

        let body = String(data: data, encoding: .utf8) ?? ""
        return try GalleryDetailParser.parseComments(body)
    }

    // MARK: - 排行榜 API (对应 Android getTopList)

    /// 获取排行榜 (对应 Android getTopList)
    public func getTopList(url: String) async throws -> TopListDetail {
        guard let requestUrl = URL(string: url) else {
            throw EhError.invalidUrl
        }

        let request = EhRequestBuilder.buildGetRequest(
            url: requestUrl,
            referer: EhURL.topListUrl()
        )

        let (data, response) = try await sanitizedData(for: request)
        try checkResponse(response, data: data)

        let body = String(data: data, encoding: .utf8) ?? ""
        return try GalleryListParser.parseTopList(body)
    }

    // MARK: - 种子 API (对应 Android getTorrentList)

    /// 获取种子列表 (对应 Android getTorrentList)
    public func getTorrentList(url: String, gid: Int64, token: String) async throws -> [(String, String)] {
        guard let requestUrl = URL(string: url) else {
            throw EhError.invalidUrl
        }

        let detailUrl = EhURL.galleryDetailUrl(gid: gid, token: token, site: AppSettings.shared.gallerySite)
        let request = EhRequestBuilder.buildGetRequest(
            url: requestUrl,
            referer: detailUrl
        )

        let (data, response) = try await sanitizedData(for: request)
        try checkResponse(response, data: data)

        let body = String(data: data, encoding: .utf8) ?? ""
        return TorrentParser.parse(body)
    }

    // MARK: - 归档 API (对应 Android downloadArchive)

    /// 下载归档 (对应 Android downloadArchive)
    public func downloadArchive(gid: Int64, token: String, or: String?, res: String) async throws {
        guard let or = or, !or.isEmpty else {
            throw EhError.parseError("Invalid form param or")
        }
        guard !res.isEmpty else {
            throw EhError.parseError("Invalid res")
        }

        let site = AppSettings.shared.gallerySite
        let urlString = EhURL.downloadArchiveUrl(gid: gid, token: token, or: or, site: site)
        guard let url = URL(string: urlString) else {
            throw EhError.invalidUrl
        }

        let request = EhRequestBuilder.buildPostFormRequest(
            url: url,
            formFields: [("hathdl_xres", res)],
            referer: EhURL.galleryDetailUrl(gid: gid, token: token, site: site),
            origin: EhURL.origin(for: site)
        )

        let (data, response) = try await sanitizedData(for: request)
        try checkResponse(response, data: data)

        let body = String(data: data, encoding: .utf8) ?? ""
        // 检查 "You must have a H@H client" (对应 Android PATTERN_NEED_HATH_CLIENT)
        if body.contains("You must have a H@H client assigned to your account") {
            throw EhError.noHathClient
        }
    }

    // MARK: - 画廊页面 HTML 解析 (对应 Android getGalleryPage)

    /// 获取画廊图片页面 (对应 Android getGalleryPage - HTML版本)
    public func getGalleryPage(url: String) async throws -> GalleryPageResult {
        guard let requestUrl = URL(string: url) else {
            throw EhError.invalidUrl
        }

        let site = AppSettings.shared.gallerySite
        let request = EhRequestBuilder.buildGetRequest(
            url: requestUrl,
            referer: EhURL.referer(for: site)
        )

        let (data, response) = try await sanitizedData(for: request)
        try checkResponse(response, data: data)

        let body = String(data: data, encoding: .utf8) ?? ""
        return try GalleryPageParser.parse(body)
    }

    // MARK: - 以图搜图 (对应 Android imageSearch)

    /// 以图搜图 (对应 Android imageSearch)
    /// - Parameters:
    ///   - imageData: 图片数据 (必须是 JPEG)
    ///   - filename: 文件名
    ///   - useSimilarity: 搜索相似图片 (fs_similar)
    ///   - onlyCovers: 仅搜索封面 (fs_covers)
    ///   - searchExpunged: 搜索已删除画廊 (fs_exp)
    public func imageSearch(
        imageData: Data, filename: String,
        useSimilarity: Bool = true,
        onlyCovers: Bool = false,
        searchExpunged: Bool = false
    ) async throws -> GalleryListResult {
        let site = AppSettings.shared.gallerySite
        let urlString = EhURL.imageLookupUrl(for: site)
        guard let url = URL(string: urlString) else {
            throw EhError.invalidUrl
        }

        // 确保文件名有扩展名
        let fileName = filename.contains(".") ? filename : filename + ".jpg"

        // 构建 multipart 请求
        var parts: [MultipartPart] = []
        parts.append(.file(name: "sfile", filename: fileName, data: imageData, contentType: "image/jpeg"))
        if useSimilarity {
            parts.append(.text(name: "fs_similar", value: "on"))
        }
        if onlyCovers {
            parts.append(.text(name: "fs_covers", value: "on"))
        }
        if searchExpunged {
            parts.append(.text(name: "fs_exp", value: "on"))
        }
        parts.append(.text(name: "f_sfile", value: "File Search"))

        let referer = EhURL.referer(for: site)
        let origin = EhURL.origin(for: site)
        let request = EhRequestBuilder.buildMultipartRequest(
            url: url,
            parts: parts,
            referer: referer,
            origin: origin
        )

        let (data, response) = try await noRedirectData(for: request)

        // 处理 302 重定向 (对应 Android followRedirects=false + 手动跟随)
        if let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode == 302,
           let location = httpResponse.value(forHTTPHeaderField: "Location"),
           let redirectUrl = URL(string: location) {
            let redirectRequest = EhRequestBuilder.buildGetRequest(url: redirectUrl, referer: referer)
            let (redirectData, redirectResponse) = try await sanitizedData(for: redirectRequest)
            try checkResponse(redirectResponse, data: redirectData)
            let body = String(data: redirectData, encoding: .utf8) ?? ""
            var result = try GalleryListParser.parse(body)
            // 批量填充 API 数据
            try await fillGalleryListByApi(galleries: &result.galleries)
            return result
        }

        try checkResponse(response, data: data)
        let body = String(data: data, encoding: .utf8) ?? ""
        var result = try GalleryListParser.parse(body)
        try await fillGalleryListByApi(galleries: &result.galleries)
        return result
    }

    // MARK: - 归档 API (对应 Android getArchiveList / getArchiver / downloadArchiver)

    /// 获取归档列表 (对应 Android getArchiveList)
    public func getArchiveList(url: String, gid: Int64, token: String) async throws -> ArchiveListResult {
        guard let requestUrl = URL(string: url) else {
            throw EhError.invalidUrl
        }

        let site = AppSettings.shared.gallerySite
        let referer = EhURL.galleryDetailUrl(gid: gid, token: token, site: site)
        let request = EhRequestBuilder.buildGetRequest(url: requestUrl, referer: referer)

        let (data, response) = try await sanitizedData(for: request)
        try checkResponse(response, data: data)

        let body = String(data: data, encoding: .utf8) ?? ""
        return try ArchiveParser.parse(body)
    }

    /// 获取归档详情 (对应 Android getArchiver)
    public func getArchiver(url: String, gid: Int64, token: String) async throws -> ArchiverData {
        guard let requestUrl = URL(string: url) else {
            throw EhError.invalidUrl
        }

        let site = AppSettings.shared.gallerySite
        let referer = EhURL.galleryDetailUrl(gid: gid, token: token, site: site)
        let request = EhRequestBuilder.buildGetRequest(url: requestUrl, referer: referer)

        let (data, response) = try await sanitizedData(for: request)
        try checkResponse(response, data: data)

        let body = String(data: data, encoding: .utf8) ?? ""
        return ArchiveParser.parseArchiver(body, isExHentai: site == .exHentai)
    }

    /// 下载归档 - 非 H@H 方式 (对应 Android downloadArchiver)
    /// 返回最终下载 URL
    public func downloadArchiver(url: String, referer: String, dltype: String, dlcheck: String) async throws -> String? {
        guard !url.isEmpty else {
            throw EhError.parseError("Invalid form param url")
        }
        guard !referer.isEmpty else {
            throw EhError.parseError("Invalid form param referer")
        }

        let site = AppSettings.shared.gallerySite
        guard let requestUrl = URL(string: url) else {
            throw EhError.invalidUrl
        }

        let request = EhRequestBuilder.buildPostFormRequest(
            url: requestUrl,
            formFields: [
                ("dltype", dltype),
                ("dlcheck", dlcheck),
            ],
            referer: referer,
            origin: EhURL.origin(for: site)
        )

        let (data, response) = try await sanitizedData(for: request)
        let body = String(data: data, encoding: .utf8) ?? ""

        // 提取重定向 URL: document.location = "..."
        let pattern = try NSRegularExpression(pattern: #"document\.location = "(.*)""#)
        let nsBody = body as NSString
        guard let match = pattern.firstMatch(in: body, range: NSRange(location: 0, length: nsBody.length)),
              let range = Range(match.range(at: 1), in: body) else {
            return nil
        }
        let continueUrl = String(body[range])

        // 跟踪重定向获取最终下载链接
        guard let continueRequestUrl = URL(string: continueUrl) else { return nil }
        let continueRequest = EhRequestBuilder.buildGetRequest(
            url: continueRequestUrl,
            referer: EhURL.origin(for: site)
        )

        let (continueData, continueResponse) = try await sanitizedData(for: continueRequest)
        let continueBody = String(data: continueData, encoding: .utf8) ?? ""

        guard let downloadPath = ArchiveParser.parseArchiverDownloadUrl(continueBody) else {
            return nil
        }

        // 构建完整下载 URL
        if let host = (continueResponse as? HTTPURLResponse)?.url?.host {
            return "https://\(host)\(downloadPath)"
        }
        return downloadPath
    }

    // MARK: - 用户资料 (对应 Android getProfile)

    /// 获取用户资料 (对应 Android getProfile)
    /// 先访问论坛主页提取 profile URL，再访问 profile 页面解析
    public func getProfile() async throws -> ProfileResult {
        // Step 1: 访问论坛主页
        guard let forumsUrl = URL(string: EhURL.forumsUrl) else {
            throw EhError.invalidUrl
        }
        let forumsRequest = EhRequestBuilder.buildGetRequest(url: forumsUrl)
        let (forumsData, forumsResponse) = try await sanitizedData(for: forumsRequest)
        try checkResponse(forumsResponse, data: forumsData)

        let forumsBody = String(data: forumsData, encoding: .utf8) ?? ""
        let profileUrl = try ForumsParser.parseProfileUrl(forumsBody)

        // Step 2: 访问 profile 页面
        guard let profileRequestUrl = URL(string: profileUrl) else {
            throw EhError.invalidUrl
        }
        let profileRequest = EhRequestBuilder.buildGetRequest(
            url: profileRequestUrl,
            referer: EhURL.forumsUrl
        )
        let (profileData, profileResponse) = try await sanitizedData(for: profileRequest)
        try checkResponse(profileResponse, data: profileData)

        let profileBody = String(data: profileData, encoding: .utf8) ?? ""
        return try ProfileParser.parse(profileBody)
    }

    // MARK: - 配额 API (对应 Android getHomeDetail / resetLimit)

    /// 获取主页配额信息 (对应 Android getHomeDetail)
    public func getHomeDetail() async throws -> HomeDetail {
        // 注意: Android 固定使用 HOME_E (e-hentai)
        guard let url = URL(string: EhURL.homeUrl(for: .eHentai)) else {
            throw EhError.invalidUrl
        }

        let request = EhRequestBuilder.buildGetRequest(
            url: url,
            referer: EhURL.referer(for: AppSettings.shared.gallerySite)
        )

        let (data, response) = try await sanitizedData(for: request)
        try checkResponse(response, data: data)

        let body = String(data: data, encoding: .utf8) ?? ""
        return HomeParser.parse(body)
    }

    /// 重置图片配额 (对应 Android resetLimit)
    public func resetLimit() async throws -> HomeDetail {
        guard let url = URL(string: EhURL.homeUrl(for: .eHentai)) else {
            throw EhError.invalidUrl
        }

        let request = EhRequestBuilder.buildPostFormRequest(
            url: url,
            formFields: [("reset_imagelimit", "Reset Limit")],
            referer: EhURL.referer(for: AppSettings.shared.gallerySite)
        )

        let (data, response) = try await sanitizedData(for: request)
        try checkResponse(response, data: data)

        let body = String(data: data, encoding: .utf8) ?? ""
        return HomeParser.parse(body)
    }

    // MARK: - 用户标签 API (对应 Android getWatchedList / addTag / deleteWatchedTag)

    /// 获取用户标签列表 (对应 Android getWatchedList)
    public func getWatchedList(url: String) async throws -> UserTagList {
        guard let requestUrl = URL(string: url) else {
            throw EhError.invalidUrl
        }

        let request = EhRequestBuilder.buildGetRequest(url: requestUrl)
        let (data, response) = try await sanitizedData(for: request)
        try checkResponse(response, data: data)

        let body = String(data: data, encoding: .utf8) ?? ""
        return try MyTagListParser.parse(body)
    }

    /// 添加用户标签 (对应 Android addTag)
    public func addTag(url: String, tag: UserTag) async throws -> UserTagList {
        guard let requestUrl = URL(string: url) else {
            throw EhError.invalidUrl
        }

        let request = EhRequestBuilder.buildPostRawFormRequest(
            url: requestUrl,
            rawBody: tag.addTagParam()
        )

        let (data, response) = try await sanitizedData(for: request)
        try checkResponse(response, data: data)

        let body = String(data: data, encoding: .utf8) ?? ""
        return try MyTagListParser.parse(body)
    }

    /// 删除用户标签 (对应 Android deleteWatchedTag)
    public func deleteWatchedTag(url: String, tag: UserTag) async throws -> UserTagList {
        guard let requestUrl = URL(string: url) else {
            throw EhError.invalidUrl
        }

        let request = EhRequestBuilder.buildPostRawFormRequest(
            url: requestUrl,
            rawBody: tag.deleteParam()
        )

        let (data, response) = try await sanitizedData(for: request)
        try checkResponse(response, data: data)

        let body = String(data: data, encoding: .utf8) ?? ""
        return try MyTagListParser.parse(body)
    }

    // MARK: - 批量收藏 (对应 Android addFavoritesRange)

    /// 批量添加收藏 (对应 Android addFavoritesRange)
    public func addFavoritesRange(gidArray: [Int64], tokenArray: [String], dstCat: Int) async throws {
        precondition(gidArray.count == tokenArray.count, "gidArray and tokenArray must have same length")
        for i in 0..<gidArray.count {
            try await addFavorites(gid: gidArray[i], token: tokenArray[i], dstCat: dstCat)
        }
    }

    // MARK: - EH 新闻 (对应 Android getEhNews)

    /// 获取 EH 新闻 (对应 Android getEhNews)
    public func getEhNews() async throws -> EhNewsDetail {
        guard let url = URL(string: EhURL.newsUrl) else {
            throw EhError.invalidUrl
        }

        let request = EhRequestBuilder.buildGetRequest(url: url)
        let (data, response) = try await sanitizedData(for: request)
        try checkResponse(response, data: data)

        let body = String(data: data, encoding: .utf8) ?? ""
        return EhNewsDetail(rawHtml: body)
    }

    // MARK: - 响应检查 (对应 Android doThrowException)

    private static let sadPandaDisposition = "inline; filename=\"sadpanda.jpg\""
    private static let sadPandaType = "image/gif"
    private static let sadPandaLength = "9615"

    private func checkResponse(_ response: URLResponse, data: Data, requestUrl: String? = nil) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw EhError.networkError("Invalid response")
        }

        // Sad Panda 检测 — 三重检查对齐 Android (EhEngine.java L110-117)
        if httpResponse.value(forHTTPHeaderField: "Content-Disposition") == Self.sadPandaDisposition,
           httpResponse.value(forHTTPHeaderField: "Content-Type") == Self.sadPandaType,
           httpResponse.value(forHTTPHeaderField: "Content-Length") == Self.sadPandaLength {
            // 自动清除失效的 igneous Cookie 并通知 UI (V-15)
            EhCookieManager.shared.clearIgneous()
            NotificationCenter.default.post(name: .ehSadPandaDetected, object: nil)
            throw EhError.sadPanda
        }

        let body = String(data: data, encoding: .utf8) ?? ""

        // Kokomade 检测
        if body.contains("https://exhentai.org/img/kokomade.jpg") {
            throw EhError.kokomade
        }

        // ExHentai 空 body / igneous 错误 (对应 Android EhEngine.java getGalleryList 中的检测)
        if httpResponse.statusCode == 200,
           let url = requestUrl,
           (url == "https://exhentai.org/" || url == "https://exhentai.org"),
           body.isEmpty {
            // 自动清除失效的 igneous Cookie (V-15)
            EhCookieManager.shared.clearIgneous()
            NotificationCenter.default.post(name: .ehSadPandaDetected, object: nil)
            throw EhError.igneousWrong
        }

        // HTTP 错误码
        if httpResponse.statusCode >= 400 {
            throw EhError.httpError(httpResponse.statusCode, body)
        }
    }
}

// MARK: - 重定向控制 Delegate (仅用于图片 session 禁止跟随重定向)

private final class RedirectBlockDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)  // 不跟随重定向
    }
}

// MARK: - 域名前置 TLS 验证 Delegate
// 对应 Android: OkHttp 的 Dns 接口在 socket 层替换 IP 而不影响 TLS SNI 和证书验证
// iOS URLSession 无此能力 — 当 URL host 被替换为 IP 时，TLS SNI 也变成 IP
// 因此需要自定义 TLS 验证: 从 Host header 读取原始域名，用原始域名验证服务器证书

private final class DomainFrontingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let blockRedirects: Bool

    init(blockRedirects: Bool) {
        self.blockRedirects = blockRedirects
        super.init()
    }

    // TLS 认证质询: 当域名前置时，验证服务器证书是否匹配原始域名
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // 从 Host header 获取原始域名 (域名前置时由 forceDomainFronting 设置)
        let originalHost = task.originalRequest?.value(forHTTPHeaderField: "Host")
                        ?? task.currentRequest?.value(forHTTPHeaderField: "Host")
                        ?? challenge.protectionSpace.host

        // 如果 host 没有被替换 (即不是域名前置)，使用默认验证
        if originalHost == challenge.protectionSpace.host {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // 域名前置: 验证证书是否对原始域名有效
        // (URL 中是 IP，但我们需要验证证书对原始域名是否合法)
        let policy = SecPolicyCreateSSL(true, originalHost as CFString)
        SecTrustSetPolicies(serverTrust, policy)

        var error: CFError?
        if SecTrustEvaluateWithError(serverTrust, &error) {
            // 证书对原始域名有效 — 接受连接
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            // 证书对原始域名无效 (可能是共享 IP 返回了错误证书)
            print("[EhAPI] 域名前置 TLS: 证书不匹配 '\(originalHost)' (连接到 \(challenge.protectionSpace.host))")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    // 重定向控制
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(blockRedirects ? nil : request)
    }
}

// MARK: - 错误类型

public enum EhError: LocalizedError, Sendable {
    case invalidUrl
    case sadPanda
    case kokomade
    case httpError(Int, String)
    case parseError(String)
    case networkError(String)
    case imageLimitReached
    case noHathClient
    case cancelled
    case igneousWrong
    /// Cloudflare 403 拦截 — 需要使用网页登录通过验证
    case cloudflare403
    /// 画廊包含攻击性内容 (对应 Android OffensiveException)
    case offensive
    /// 画廊已删除 — pining for the fjords (对应 Android PiningException)
    case pining
    /// 画廊不可用 (对应 Android GalleryUnavailableException)
    case galleryUnavailable
    /// 服务端错误消息 (从 <div class="d"> 提取)
    case serverError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidUrl: return "无效的链接"
        case .sadPanda: return "Sad Panda — 请登录或检查 Cookie"
        case .kokomade: return "今回はここまで — 访问受限"
        case .httpError(let code, _): return "HTTP 错误 \(code)"
        case .cloudflare403: return "Cloudflare 安全验证拦截 — 请使用下方「网页登录」通过验证后登录"
        case .parseError(let msg): return "解析失败: \(msg)"
        case .networkError(let msg): return "网络错误: \(msg)"
        case .imageLimitReached: return "509 — 图片配额已用尽"
        case .noHathClient: return "没有可用的 H@H 客户端"
        case .cancelled: return "请求已取消"
        case .igneousWrong: return "igneous cookie 无效，请重新登录或检查 ExHentai 权限"
        case .offensive: return "该画廊包含攻击性内容，需确认后访问"
        case .pining: return "该画廊已被删除 (pining for the fjords)"
        case .galleryUnavailable: return "该画廊不可用"
        case .serverError(let msg): return msg
        }
    }

    /// 将 URLError 转换为用户友好的中文描述
    public static func localizedMessage(for error: Error) -> String {
        if let ehError = error as? EhError {
            return ehError.localizedDescription
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "请求超时 — 请检查网络连接或代理设置"
            case .notConnectedToInternet:
                return "无网络连接 — 请检查网络设置"
            case .cannotConnectToHost:
                return "无法连接到服务器 — 请检查代理/VPN 设置"
            case .cannotFindHost, .dnsLookupFailed:
                return "域名解析失败 — 请检查 DNS 或开启代理/VPN"
            case .networkConnectionLost:
                return "网络连接中断 — 请稍后重试"
            case .secureConnectionFailed:
                return "安全连接失败 — 请检查代理/VPN 设置"
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot:
                return "证书验证失败 — 请检查代理设置或关闭域名前置"
            case .cancelled:
                return "请求已取消"
            case .dataNotAllowed:
                return "蜂窝数据不可用 — 请检查设置"
            default:
                return "网络错误 (\(urlError.code.rawValue))"
            }
        }
        return error.localizedDescription
    }
}

// MARK: - 通知

public extension Notification.Name {
    /// Sad Panda / igneous 失效检测通知 — UI 应观察并提示用户重新登录
    static let ehSadPandaDetected = Notification.Name("ehSadPandaDetected")
}

// MARK: - API 返回类型 (GalleryListResult, GalleryPageResult, RateResult 定义在 EhModels)
