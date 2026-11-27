import Foundation
import Testing
import EhModels
@testable import EhAPI

struct ThumbnailRequestPolicyTests {
    @Test func publicCoverTriesNumberedHostOnlyAfterBase() throws {
        let original = try #require(URL(string: "https://EHGT.org/w/cover%20one.png?k=ehgt.org%2F#fixture"))
        let candidates = ThumbnailRequestPolicy.candidates(for: original, site: .eHentai, fixLink: false)
        #expect(candidates.map { $0.host?.lowercased() } == ["ehgt.org", "gt1.ehgt.org"])
        #expect(candidates.last?.absoluteString == "https://gt1.ehgt.org/w/cover%20one.png?k=ehgt.org%2F#fixture")
    }

    @Test func coverToggleChangesPreferredHostWithOriginalAsSafeFallback() throws {
        let original = try #require(URL(string: "https://gt2.ehgt.org/w/cover%20one.png?k=42"))
        #expect(ThumbnailRequestPolicy.candidates(for: original, site: .eHentai, fixLink: false) == [original])
        #expect(ThumbnailRequestPolicy.candidates(for: original, site: .eHentai, fixLink: true).map(\.host)
                == ["ehgt.org", "gt1.ehgt.org", "gt2.ehgt.org"])
        #expect(ThumbnailRequestPolicy.candidates(for: original, site: .exHentai, fixLink: false).map(\.host)
                == ["gt2.ehgt.org", "exhentai.org"])
        let fixed = ThumbnailRequestPolicy.candidates(for: original, site: .exHentai, fixLink: true)
        #expect(fixed.map(\.absoluteString) == ["https://exhentai.org/t/w/cover%20one.png?k=42", original.absoluteString])
    }

    @Test(arguments: [
        "https://exhentai.org/t/neutral.png",
        "https://example.invalid/https://ehgt.org/neutral.png",
        "https://ehgt.org.example.invalid/neutral.png",
        "https://gt4.ehgt.org/neutral.png",
        "https://ehgt.org:8443/neutral.png",
        "https://somebody@ehgt.org/neutral.png",
        "http://ehgt.org/neutral.png",
    ])
    func nonCDNAndExistingEXLinksNeverRewrite(url: String) throws {
        let original = try #require(URL(string: url))
        for site in EhSite.allCases {
            for fix in [false, true] {
                #expect(ThumbnailRequestPolicy.candidates(for: original, site: site, fixLink: fix) == [original])
            }
        }
    }

    @Test func thumbnailSessionUsesAppliedProxyAndPreservesCache() {
        let configured = URLSession(configuration: ThumbnailRequestPolicy.configuration(
            proxy: .init(mode: 1, host: "proxy.invalid", port: 4312)))
        let disabled = URLSession(configuration: ThumbnailRequestPolicy.configuration(
            proxy: .init(mode: 0, host: "proxy.invalid", port: 4312)))
        defer {
            configured.invalidateAndCancel()
            disabled.invalidateAndCancel()
        }
        #expect(configured.configuration.connectionProxyDictionary?["HTTPSProxy"] as? String == "proxy.invalid")
        #expect(configured.configuration.connectionProxyDictionary?["HTTPSPort"] as? Int == 4312)
        #expect(configured.configuration.connectionProxyDictionary?["HTTPProxy"] as? String == "proxy.invalid")
        #expect(disabled.configuration.connectionProxyDictionary == nil)
        #expect(configured.configuration.httpAdditionalHeaders?["User-Agent"] as? String == EhRequestBuilder.userAgent)
        #expect(configured.configuration.urlCache === URLCache.shared)
        #expect(configured.configuration.httpCookieStorage === HTTPCookieStorage.shared)
    }
}
