import Foundation
import EhModels
import EhSettings

/// Routing shared by gallery cover surfaces; rewriting applies only to known thumbnail hosts.
public enum ThumbnailRequestPolicy {
    public static func candidates(for url: URL, site: EhSite, fixLink: Bool) -> [URL] {
        let preferred = preferredURL(for: url, site: site, fixLink: fixLink)
        var candidates = [preferred]
        if let alternate = fallbackURL(for: preferred, site: site), alternate != preferred {
            candidates.append(alternate)
        }
        if !candidates.contains(url) { candidates.append(url) }
        return candidates
    }

    static func preferredURL(for original: URL, site: EhSite, fixLink: Bool) -> URL {
        guard fixLink, let components = cdnComponents(of: original) else { return original }
        return replacingCDN(components, site: site) ?? original
    }

    static func fallbackURL(for url: URL, site: EhSite) -> URL? {
        guard var components = cdnComponents(of: url) else { return nil }
        if site == .exHentai {
            return replacingCDN(components, site: site)
        }
        guard components.host?.lowercased() == "ehgt.org" else { return nil }
        components.host = "gt1.ehgt.org"
        return components.url
    }

    private static func cdnComponents(of url: URL) -> URLComponents? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil, components.port == nil,
              let host = components.host?.lowercased(),
              ["ehgt.org", "gt0.ehgt.org", "gt1.ehgt.org", "gt2.ehgt.org", "gt3.ehgt.org"].contains(host)
        else { return nil }
        return components
    }

    private static func replacingCDN(_ original: URLComponents, site: EhSite) -> URL? {
        var components = original
        if site == .exHentai {
            components.host = EhURL.domainEX
            components.percentEncodedPath = "/t" + (original.percentEncodedPath.isEmpty ? "/" : original.percentEncodedPath)
        } else {
            components.host = "ehgt.org"
        }
        return components.url
    }

    static func configuration(proxy: ProxySettings) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = .shared
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.httpMaximumConnectionsPerHost = 6
        config.urlCache = URLCache.shared
        config.requestCachePolicy = .useProtocolCachePolicy
        config.httpAdditionalHeaders = ["User-Agent": EhRequestBuilder.userAgent]
        config.connectionProxyDictionary = proxy.connectionProxyDictionary
        return config
    }
}
