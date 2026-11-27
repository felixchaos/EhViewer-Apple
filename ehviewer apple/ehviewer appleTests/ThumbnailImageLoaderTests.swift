import EhModels
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Testing
@testable import ehviewer_apple

@MainActor
struct ThumbnailImageLoaderTests {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgSDsDAAGcATPhsmC5AAAAAElFTkSuQmCC")!

    @Test func publicCoverFallsBackAndDecodesAfterBaseReturns404() async throws {
        let url = try #require(URL(string: "https://ehgt.org/w/\(UUID().uuidString).png"))
        var recorded = [URLRequest]()
        let image = await ThumbnailImageLoader.load(url: url, site: .eHentai, fixCoverLink: false) { req in
            recorded.append(req)
            let isFallback = req.url?.host == "gt1.ehgt.org"
            return (isFallback ? png : Data(), try response(req, status: isFallback ? 200 : 404))
        }
        defer { recorded.forEach { URLCache.shared.removeCachedResponse(for: $0) } }

        #expect(image?.size.width == 1)
        #expect(recorded.compactMap { $0.url?.host } == ["ehgt.org", "gt1.ehgt.org"])
        #expect(recorded.allSatisfy { $0.value(forHTTPHeaderField: "Referer") == "https://e-hentai.org/" })
        #expect(recorded.first.flatMap { URLCache.shared.cachedResponse(for: $0) } == nil)
    }

    @Test func existingNumberedCoverNeverRetriesAnotherHostWhenFixIsOff() async throws {
        let url = try #require(URL(string: "https://gt2.ehgt.org/w/\(UUID().uuidString).png"))
        var recorded = [URLRequest]()
        let image = await ThumbnailImageLoader.load(url: url, site: .eHentai, fixCoverLink: false) { req in
            recorded.append(req)
            // Even a valid bitmap in a 404 should neither display nor cache.
            return (png, try response(req, status: 404))
        }
        defer { recorded.forEach { URLCache.shared.removeCachedResponse(for: $0) } }

        #expect(image == nil)
        #expect(recorded.compactMap(\.url) == [url])
        #expect(recorded.first.flatMap { URLCache.shared.cachedResponse(for: $0) } == nil)
    }

    private func response(_ req: URLRequest, status: Int) throws -> HTTPURLResponse {
        let url = try #require(req.url)
        return try #require(HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"]))
    }
}
