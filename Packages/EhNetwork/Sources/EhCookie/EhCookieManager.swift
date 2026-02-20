import Foundation

// MARK: - EhCookieManager (对应 Android EhCookieStore.java)
// 管理 E-Hentai / ExHentai 的认证 Cookie

public final class EhCookieManager: @unchecked Sendable {
    public static let shared = EhCookieManager()

    private let storage: HTTPCookieStorage

    /// Cookie 写操作队列 — 匹配 HTTPCookieStorage 内部 XPC 守护进程的 Default QoS，
    /// 避免 User-initiated 线程阻塞在低优先级 XPC 同步上导致优先级反转 (Hang Risk)
    private let writeQueue = DispatchQueue(label: "com.ehviewer.cookie.write", qos: .default)

    // MARK: - Cookie 名称常量

    public static let keyIPBMemberId = "ipb_member_id"
    public static let keyIPBPassHash = "ipb_pass_hash"
    public static let keyIgneous = "igneous"
    public static let keyStarRecentViews = "star"
    public static let keyYay = "yay"
    public static let keyNW = "nw"               // nw=1 跳过内容警告
    public static let keySP = "sp"               // 预览页面偏好
    public static let keyHathPerks = "hath_perks"
    public static let keySK = "sk"               // Session Key
    public static let keyS  = "s"
    public static let keyUConfig = "uconfig"     // 用户配置 (需过滤)

    // MARK: - Host 常量

    public static let domainEhentai = ".e-hentai.org"
    public static let domainExhentai = ".exhentai.org"
    public static let domainForums = "forums.e-hentai.org"

    private init() {
        storage = HTTPCookieStorage.shared
        // 在初始化时确保 nw=1 已注入
        injectNWCookie()
    }

    // MARK: - 登录状态检查

    /// 是否已登录 E-Hentai
    public var isSignedIn: Bool {
        let cookies = getCookies(for: Self.domainEhentai)
        return cookies[Self.keyIPBMemberId] != nil
            && cookies[Self.keyIPBPassHash] != nil
    }

    /// 是否拥有 ExHentai 访问权限
    /// 校验 igneous 值有效性 — 排除 "mystery", "0", "", "yay" 等已知失效值 (V-14)
    public var hasExhentaiAccess: Bool {
        let cookies = getCookies(for: Self.domainExhentai)
        guard let _ = cookies[Self.keyIPBMemberId],
              let _ = cookies[Self.keyIPBPassHash],
              let igneous = cookies[Self.keyIgneous] else {
            return false
        }
        // igneous 为空、"mystery"、"0"、"yay" 均表示权限已失效
        let invalidValues: Set<String> = ["mystery", "0", "", "yay"]
        return !invalidValues.contains(igneous.lowercased())
    }

    // MARK: - 读取 Cookie

    /// 获取指定域名的所有 Cookie 键值对
    public func getCookies(for domain: String) -> [String: String] {
        guard let url = URL(string: "https://\(domain.trimmingCharacters(in: .init(charactersIn: ".")))") else {
            return [:]
        }
        let cookies = storage.cookies(for: url) ?? []
        return Dictionary(uniqueKeysWithValues: cookies.map { ($0.name, $0.value) })
    }

    /// 获取特定 Cookie 值
    public func getCookie(name: String, for domain: String) -> String? {
        getCookies(for: domain)[name]
    }

    /// 获取 ipb_member_id
    public var memberId: String? {
        getCookie(name: Self.keyIPBMemberId, for: Self.domainEhentai)
    }

    /// 获取 ipb_pass_hash
    public var passHash: String? {
        getCookie(name: Self.keyIPBPassHash, for: Self.domainEhentai)
    }

    /// 获取 igneous
    public var igneous: String? {
        getCookie(name: Self.keyIgneous, for: Self.domainExhentai)
    }

    // MARK: - 写入 Cookie

    /// 设置单个 Cookie
    public func setCookie(name: String, value: String, domain: String, path: String = "/") {
        let properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path,
            .secure: "TRUE",
            .expires: Date.distantFuture,
        ]
        if let cookie = HTTPCookie(properties: properties) {
            writeQueue.async { [storage] in
                storage.setCookie(cookie)
            }
        }
    }

    /// 登录后同步 Cookie 到 ExHentai 域名
    /// 对应 Android 代码: 登录后将 memberId/passHash 复制到 ExHentai 域名
    public func syncLoginCookies() {
        guard let memberId = memberId, let passHash = passHash else { return }

        // 同步到 exhentai
        setCookie(name: Self.keyIPBMemberId, value: memberId, domain: Self.domainExhentai)
        setCookie(name: Self.keyIPBPassHash, value: passHash, domain: Self.domainExhentai)

        // nw=1 跳过内容警告页面 (Android 硬编码注入)
        injectNWCookie()
    }

    /// 注入 nw=1 Cookie (对应 Android EhCookieStore 中的硬编码 nw=1)
    /// 跳过画廊的内容警告页面
    public func injectNWCookie() {
        setCookie(name: Self.keyNW, value: "1", domain: Self.domainEhentai)
        setCookie(name: Self.keyNW, value: "1", domain: Self.domainExhentai)
    }

    // MARK: - Cookie 请求拦截 (对应 Android EhCookieStore.loadForRequest)

    /// 应用请求前 Cookie 清洁: 确保 nw=1 存在，移除 uconfig
    /// 应在每次请求前调用（对应 Android 的 loadForRequest() 覆写）
    /// 应用请求前 Cookie 清洁
    /// 严格对齐 Android EhCookieStore.loadForRequest:
    ///   - 仅对 e-hentai.org 做 nw=1 注入 + uconfig 过滤
    ///   - ExHentai 不做任何过滤 (Android L87: checkTips = domainMatch(url, DOMAIN_E))
    public func sanitizeCookiesForRequest(url: URL) {
        guard let host = url.host else { return }

        // Android: checkTips = domainMatch(url, DOMAIN_E)  —— 仅 E 站
        let isEh = host.hasSuffix("e-hentai.org")
        guard isEh else { return }  // ExHentai 不做过滤

        let cookies = storage.cookies(for: url) ?? []

        // 确保 nw=1 存在 (对应 Android 每次请求注入 sTipsCookie)
        let hasNW = cookies.contains { $0.name == Self.keyNW && $0.value == "1" }
        if !hasNW {
            setCookie(name: Self.keyNW, value: "1", domain: Self.domainEhentai)
        }

        // 移除 uconfig cookie (对应 Android EhCookieStore L97: if KEY_UCONFIG.equals(name) continue)
        let uconfigCookies = cookies.filter { $0.name == Self.keyUConfig }
        if !uconfigCookies.isEmpty {
            writeQueue.async { [storage] in
                for cookie in uconfigCookies {
                    storage.deleteCookie(cookie)
                }
            }
        }
    }

    // MARK: - 清除 Cookie

    /// 登出: 清除所有 EH/EX Cookie
    public func signOut() {
        clearCookies(for: Self.domainEhentai)
        clearCookies(for: Self.domainExhentai)
        clearCookies(for: Self.domainForums)
    }

    /// 清除 igneous Cookie — Sad Panda 检测后自动调用 (V-15)
    /// 清除后 hasExhentaiAccess 将返回 false，提示用户重新登录
    public func clearIgneous() {
        guard let url = URL(string: "https://exhentai.org") else { return }
        let cookies = storage.cookies(for: url) ?? []
        let igneousCookies = cookies.filter { $0.name == Self.keyIgneous }
        if !igneousCookies.isEmpty {
            writeQueue.async { [storage] in
                for cookie in igneousCookies {
                    storage.deleteCookie(cookie)
                }
            }
        }
    }

    /// 清除指定域名的所有 Cookie
    public func clearCookies(for domain: String) {
        guard let url = URL(string: "https://\(domain.trimmingCharacters(in: .init(charactersIn: ".")))") else {
            return
        }
        let cookies = storage.cookies(for: url) ?? []
        if !cookies.isEmpty {
            writeQueue.async { [storage] in
                for cookie in cookies {
                    storage.deleteCookie(cookie)
                }
            }
        }
    }

    // MARK: - 导入/导出 (用于备份恢复)

    /// 导出所有 EH 相关 Cookie
    public func exportCookies() -> [CookieData] {
        let domains = [Self.domainEhentai, Self.domainExhentai, Self.domainForums]
        var result: [CookieData] = []
        for domain in domains {
            guard let url = URL(string: "https://\(domain.trimmingCharacters(in: .init(charactersIn: ".")))") else {
                continue
            }
            let cookies = storage.cookies(for: url) ?? []
            for cookie in cookies {
                result.append(CookieData(
                    name: cookie.name,
                    value: cookie.value,
                    domain: cookie.domain,
                    path: cookie.path
                ))
            }
        }
        return result
    }

    /// 导入 Cookie
    public func importCookies(_ cookies: [CookieData]) {
        for data in cookies {
            setCookie(name: data.name, value: data.value, domain: data.domain, path: data.path)
        }
    }
}

// MARK: - Cookie 数据模型

public struct CookieData: Codable, Sendable {
    public var name: String
    public var value: String
    public var domain: String
    public var path: String

    public init(name: String, value: String, domain: String, path: String = "/") {
        self.name = name; self.value = value; self.domain = domain; self.path = path
    }
}
