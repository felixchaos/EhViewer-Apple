import Foundation
import Testing
import EhModels
@testable import EhAPI

struct GalleryNetworkContractTests {
    private let fixtureURL = URL(string: "https://fixture.invalid/list")!

    private func http(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: fixtureURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    @Test func homeRequestUsesDestinationSiteAndBypassesStaleCache() throws {
        let home = try EhRequestBuilder.galleryList(url: EhURL.hostEX, fallbackSite: .eHentai)
        #expect(home.url?.absoluteString == EhURL.hostEX)
        #expect(home.value(forHTTPHeaderField: "Referer") == EhURL.hostEX)
        #expect(home.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(home.httpMethod == "GET")
        #expect(home.value(forHTTPHeaderField: "Accept") == EhRequestBuilder.acceptHTML)
        #expect(home.value(forHTTPHeaderField: "Host") == nil)

        let other = try EhRequestBuilder.galleryList(url: fixtureURL.absoluteString, fallbackSite: .exHentai)
        #expect(other.value(forHTTPHeaderField: "Referer") == EhURL.hostEX)
    }

    @Test func topListInEXContextRemainsOnESiteIncludingPagination() throws {
        let firstPage = EhURL.topListUrl(period: 15)
        let next = try #require(EhURL.topListNavigationUrl("\(EhURL.hostEX)toplist.php?tl=15&p=2"))
        for url in [firstPage, next] {
            // Home now uses the shared gallery-list request path for toplist.
            let list = try EhRequestBuilder.galleryList(url: url, fallbackSite: .exHentai)
            #expect(list.url?.host == EhURL.domainE)
            #expect(list.value(forHTTPHeaderField: "Referer") == EhURL.hostE)
            #expect(list.cachePolicy == .reloadIgnoringLocalCacheData)

            let dedicated = try EhRequestBuilder.topList(url: url)
            #expect(dedicated.url == list.url)
            #expect(dedicated.value(forHTTPHeaderField: "Referer") == EhURL.topListUrl())
        }
        #expect(next == EhURL.topListUrl(period: 15, page: 2))
    }

    @Test func invalidURLDoesNotConsultFallbackSite() {
        #expect(throws: EhError.self) {
            try EhRequestBuilder.galleryList(url: "https://[", fallbackSite: {
                Issue.record("An invalid URL must not consult the fallback setting")
                return .eHentai
            }())
        }
        #expect(throws: EhError.self) {
            try EhRequestBuilder.topList(url: "https://[")
        }
    }

    @Test func unsupportedResponseAndHTTPFailureRemainDistinguishable() {
        let unsupported = URLResponse(url: fixtureURL, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        guard case .networkError(let reason) = EhResponsePolicy.failure(for: unsupported, data: Data()) else {
            Issue.record("Expected a non-HTTP response to be rejected")
            return
        }
        #expect(reason == "Invalid response")

        guard case .httpError(let status, let body) = EhResponsePolicy.failure(
            for: http(403), data: Data("fixture denial".utf8)
        ) else {
            Issue.record("Expected HTTP failure classification")
            return
        }
        #expect(status == 403)
        #expect(body == "fixture denial")
        #expect(EhResponsePolicy.failure(for: http(200), data: Data("fixture content".utf8)) == nil)
    }

    @Test func authSentinelsAreNarrowAndWinBeforeGenericHTTPError() {
        let headers = [
            "Content-Disposition": "inline; filename=\"sadpanda.jpg\"",
            "Content-Type": "image/gif",
            "Content-Length": "9615",
        ]
        guard case .sadPanda = EhResponsePolicy.failure(for: http(403, headers: headers), data: Data()) else {
            Issue.record("Expected all three sentinel headers to take precedence")
            return
        }
        for missing in headers.keys {
            let partial = headers.filter { $0.key != missing }
            #expect(EhResponsePolicy.failure(for: http(200, headers: partial), data: Data()) == nil)
        }

        for home in [EhURL.hostEX, String(EhURL.hostEX.dropLast())] {
            guard case .igneousWrong = EhResponsePolicy.failure(for: http(200), data: Data(), requestUrl: home) else {
                Issue.record("Expected empty EX homepage classification")
                continue
            }
        }
        #expect(EhResponsePolicy.failure(for: http(200), data: Data(), requestUrl: EhURL.hostE) == nil)
        #expect(EhResponsePolicy.failure(for: http(200), data: Data(), requestUrl: EhURL.hostEX + "popular") == nil)
        #expect(EhResponsePolicy.failure(for: http(204), data: Data(), requestUrl: EhURL.hostEX) == nil)
    }

    @Test func accessSentinelsInSuccessBodyDoNotLookLikeEmptyGallery() {
        let ban = "Your IP address has been temporarily banned. Expires in 3 minutes."
        guard case .ipBanned(let duration) = EhResponsePolicy.failure(for: http(200), data: Data(ban.utf8)) else {
            Issue.record("Expected IP-ban response classification")
            return
        }
        #expect(duration == "Expires in 3 minutes")

        let denial = #"<img src="https://exhentai.org/img/kokomade.jpg">"#
        guard case .kokomade = EhResponsePolicy.failure(for: http(200), data: Data(denial.utf8)) else {
            Issue.record("Expected access denial classification")
            return
        }
    }

    @Test func cancellationDoesNotQualifyForRetryOrDirectFallback() {
        let cancelled = URLError(.cancelled)
        #expect(!EhAPI.isRetryableError(cancelled))
        #expect(!EhAPI.shouldTryDirectFallback(cancelled))
        #expect(!EhAPI.shouldTryDirectFallback(CancellationError()))
        #expect(EhError.localizedMessage(for: cancelled) == EhError.cancelled.localizedDescription)

        let timeout = URLError(.timedOut)
        #expect(EhAPI.isRetryableError(timeout))
        #expect(EhAPI.shouldTryDirectFallback(timeout))

        let offline = URLError(.notConnectedToInternet)
        #expect(EhAPI.isRetryableError(offline))
        #expect(!EhAPI.shouldTryDirectFallback(offline))
    }
}
