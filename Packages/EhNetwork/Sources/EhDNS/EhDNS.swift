import Foundation
import EhSettings

// MARK: - EhDNS 自定义 DNS 解析 (对应 Android EhHosts.kt)
// 内置 IP 地址绕过 DNS 污染，支持中国用户直连
// 注意: 域名前置 (Domain Fronting) 在 iOS/macOS 的 URLSession 中无法正确工作
// URL 域名替换为 IP 会破坏 TLS SNI，导致证书验证失败
// 因此默认禁用，依赖系统 DNS / 代理 / VPN 解析域名

public final class EhDNS: @unchecked Sendable {
    public static let shared = EhDNS()

    /// 是否启用自定义 DNS — 从 AppSettings 读取，与设置界面联动
    public var isEnabled: Bool {
        AppSettings.shared.builtInHosts || AppSettings.shared.domainFronting || AppSettings.shared.dnsOverHttps
    }

    /// 内置 Hosts 映射 (对应 Android builtInHosts)
    /// IP 地址与 Android 版本对齐
    private static let builtInHosts: [String: [String]] = [
        // E-Hentai 主站 (对齐 Android EhHosts.kt)
        "e-hentai.org": ["104.20.18.168", "104.20.19.168", "172.67.2.238"],
        "api.e-hentai.org": ["37.48.89.44", "81.171.10.48", "178.162.139.24"],
        "upload.e-hentai.org": ["94.100.28.57", "94.100.29.73"],
        "forums.e-hentai.org": ["94.100.18.243", "104.20.18.168"],

        // ExHentai (对齐 Android: 12 个 IP)
        "exhentai.org": [
            "178.175.128.251", "178.175.128.252", "178.175.128.253", "178.175.128.254",
            "178.175.129.251", "178.175.129.252", "178.175.129.253", "178.175.129.254",
            "178.175.132.19", "178.175.132.20", "178.175.132.21", "178.175.132.22",
        ],
        "s.exhentai.org": [
            "178.175.129.253", "178.175.129.254",
            "178.175.128.253", "178.175.128.254",
            "178.175.132.21", "178.175.132.22",
        ],

        // 缩略图 CDN (对齐 Android)
        "ehgt.org": ["37.48.89.44", "81.171.10.48", "178.162.139.24"],
        "gt0.ehgt.org": ["37.48.89.44", "81.171.10.48", "178.162.139.24"],
        "gt1.ehgt.org": ["37.48.89.44", "81.171.10.48", "178.162.139.24"],
        "gt2.ehgt.org": ["37.48.89.44", "81.171.10.48", "178.162.139.24"],
        "gt3.ehgt.org": ["37.48.89.44", "81.171.10.48", "178.162.139.24"],

        // 上传服务器 (对齐 Android)
        "upld.e-hentai.org": ["94.100.28.57", "94.100.29.73"],
        "upld.exhentai.org": ["178.175.132.22", "178.175.128.254"],

        // Repo / Raw
        "repo.e-hentai.org": ["94.100.28.57", "94.100.29.73"],
        "raw.githubusercontent.com": ["185.199.108.133", "185.199.109.133", "185.199.110.133", "185.199.111.133"],
    ]

    /// 用户自定义 Hosts (优先于内置)
    private var userHosts: [String: [String]] = [:]
    /// 用于保护 userHosts 的并发访问
    private let lock = NSLock()

    /// DNS-over-HTTPS 提供商 URL
    public enum DoHProvider: String, CaseIterable, Sendable {
        case cloudflare = "https://cloudflare-dns.com/dns-query"
        case google = "https://dns.google/dns-query"
        case aliDNS = "https://dns.alidns.com/dns-query"
    }

    private init() {}

    // MARK: - 解析

    /// 获取指定主机名的 IP 地址列表
    /// 对齐 Android: 随机打乱实现负载均衡
    public func resolve(host: String) -> [String] {
        guard isEnabled else { return [] }
        return forceResolve(host: host)
    }

    /// 异步解析 — 优先使用 DNS-over-HTTPS（若启用），回退到内置 Hosts
    /// 调用方在需要动态解析时应优先使用此方法
    public func resolveAsync(host: String) async -> [String] {
        guard isEnabled else { return [] }

        // 如果用户启用了 DoH，优先走 DoH
        if AppSettings.shared.dnsOverHttps {
            do {
                let ips = try await resolveViaDoH(host: host)
                if !ips.isEmpty { return ips }
            } catch {
                // DoH 失败，静默回退到内置 Hosts
            }
        }

        // 回退到内置 Hosts 解析
        return forceResolve(host: host)
    }

    /// 强制解析 — 无视 isEnabled 设置，直接从内置 Hosts 解析
    /// 用于: VPN 代理 503 回退时，绕过 HTTP 代理同时使用真实 IP (非 fake-ip)
    public func forceResolve(host: String) -> [String] {
        // 用户自定义优先
        lock.lock()
        let userIps = userHosts[host]
        lock.unlock()
        if let ips = userIps, !ips.isEmpty {
            return ips.shuffled()  // 对齐 Android: Collections.shuffle()
        }
        // 回退到内置
        if let ips = Self.builtInHosts[host], !ips.isEmpty {
            return ips.shuffled()  // 对齐 Android: Collections.shuffle()
        }
        return []  // 回退到系统 DNS
    }

    /// 使用 DNS-over-HTTPS 异步解析域名
    public func resolveViaDoH(host: String, provider: DoHProvider = .cloudflare) async throws -> [String] {
        guard let url = URL(string: "\(provider.rawValue)?name=\(host)&type=A") else {
            throw EhDNSError.invalidUrl
        }

        var request = URLRequest(url: url)
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 5

        let (data, _) = try await URLSession.shared.data(for: request)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = json["Answer"] as? [[String: Any]]
        else {
            throw EhDNSError.parseError
        }

        let ips = answers.compactMap { answer -> String? in
            guard let type = answer["type"] as? Int, type == 1,
                  let data = answer["data"] as? String
            else { return nil }
            return data
        }

        return ips
    }

    // MARK: - 用户自定义

    public func setUserHost(_ host: String, ips: [String]) {
        lock.lock()
        userHosts[host] = ips
        lock.unlock()
    }

    public func removeUserHost(_ host: String) {
        lock.lock()
        userHosts.removeValue(forKey: host)
        lock.unlock()
    }

    public func clearUserHosts() {
        lock.lock()
        userHosts.removeAll()
        lock.unlock()
    }

    // MARK: - URLSession 集成 (Domain Fronting)

    /// 替换请求 URL 中的域名为 IP (手动 Domain Fronting)
    /// 对应 Android OkHttp Dns 接口的自动 DNS 替换
    /// 仅在 isEnabled 为 true 时生效
    public func applyDomainFronting(to request: URLRequest) -> URLRequest {
        guard isEnabled else { return request }
        return forceDomainFronting(to: request)
    }

    /// 强制域名前置 — 无视 isEnabled 设置
    /// 用于: VPN 代理 503 回退时，绕过 HTTP 代理同时使用内置 DNS 真实 IP
    /// 避免 Clash fake-ip 模式下 TLS 握手失败
    public func forceDomainFronting(to request: URLRequest) -> URLRequest {
        guard let url = request.url, let host = url.host else { return request }

        let ips = forceResolve(host: host)
        guard let ip = ips.first else { return request }  // 无内置 IP 则原样返回

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = ip

        guard let newUrl = components?.url else { return request }

        var modifiedRequest = URLRequest(url: newUrl)
        modifiedRequest.allHTTPHeaderFields = request.allHTTPHeaderFields
        modifiedRequest.httpMethod = request.httpMethod
        modifiedRequest.httpBody = request.httpBody
        modifiedRequest.timeoutInterval = request.timeoutInterval
        // 设置原始 Host 头 (关键: TLS delegate 会从此 header 读取原始域名做证书验证)
        modifiedRequest.setValue(host, forHTTPHeaderField: "Host")

        // 手动携带 Cookie (关键: URL 域名变成 IP 后, HTTPCookieStorage 不会自动匹配 cookies)
        if let cookies = HTTPCookieStorage.shared.cookies(for: url), !cookies.isEmpty {
            let cookieHeaders = HTTPCookie.requestHeaderFields(with: cookies)
            for (key, value) in cookieHeaders {
                // 如果原始请求已有 Cookie header, 合并; 否则直接设置
                if let existing = modifiedRequest.value(forHTTPHeaderField: key), !existing.isEmpty {
                    modifiedRequest.setValue("\(existing); \(value)", forHTTPHeaderField: key)
                } else {
                    modifiedRequest.setValue(value, forHTTPHeaderField: key)
                }
            }
        }

        return modifiedRequest
    }
}

// MARK: - 错误类型

public enum EhDNSError: LocalizedError, Sendable {
    case invalidUrl
    case parseError
    case noResult

    public var errorDescription: String? {
        switch self {
        case .invalidUrl: return "Invalid DoH URL"
        case .parseError: return "Failed to parse DNS response"
        case .noResult: return "No DNS result found"
        }
    }
}
