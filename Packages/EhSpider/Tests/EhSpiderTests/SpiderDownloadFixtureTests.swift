import Foundation
import Testing
import EhModels
@testable import EhSpider

private actor FixtureDownloadTransport {
    enum FixtureFailure: Error { case unexpectedRequest }
    private(set) var imageRequests: [Int] = []
    private(set) var finished: [Int] = []
    private(set) var peak = 0
    private var active = 0
    private var attempts: [Int: Int] = [:]
    // A neutral, one-pixel PNG.
    static let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aewoAAAAASUVORK5CYII=")!

    func receive(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        if url.path.hasPrefix("/s/"), let page = Int(url.lastPathComponent.split(separator: "-").last ?? "") {
            let html = "<img id=\"img\" src=\"https://fixture.invalid/\(page).png\">"
            return (Data(html.utf8), response(url, contentType: "text/html"))
        }
        guard url.host == "fixture.invalid", let page = Int(url.deletingPathExtension().lastPathComponent) else {
            throw FixtureFailure.unexpectedRequest
        }
        imageRequests.append(page)
        active += 1
        peak = max(peak, active)
        defer { active -= 1 }
        attempts[page, default: 0] += 1
        if page == 1 && attempts[page] == 1 {
            try await Task.sleep(for: .milliseconds(160))
            throw URLError(.timedOut)
        }
        try await Task.sleep(for: .milliseconds(20))
        finished.append(page)
        return (Self.image, response(url, contentType: "image/png"))
    }

    private func response(_ url: URL, contentType: String) -> URLResponse {
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": contentType])!
    }
}

@Suite struct SpiderDownloadFixtureTests {
    @Test func passesAStalledPageAndStoresOtherPagesBeforeRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gallery = GalleryInfo(gid: -29, token: "neutral", title: "Synthetic download", pages: 6)
        let transport = FixtureDownloadTransport()
        let info = SpiderInfo(gid: gallery.gid, token: gallery.token, pages: gallery.pages,
                              pTokenMap: Dictionary(uniqueKeysWithValues: (0..<6).map { ($0, "abcd") }))
        let den = SpiderDen(galleryID: gallery.gid, mode: .download, downloadDirectory: directory)
        let spider = SpiderQueen(galleryInfo: gallery, spiderInfo: info, mode: .download, spiderDen: den,
                                imageRequestTimeout: 10) { request in try await transport.receive(request) }
        await spider.startDownload()

        let arrivals = await transport.imageRequests
        #expect(arrivals.count == 7)
        #expect(Set(arrivals.prefix(6)) == Set(1...6))
        #expect(arrivals.last == 1)
        #expect(await transport.finished.last == 1)
        for page in 0..<6 {
            #expect(await spider.getPageState(page) == SpiderQueen.stateFinish)
            let path = try #require(await spider.getLocalImageUrl(page))
            #expect(try Data(contentsOf: path) == FixtureDownloadTransport.image)
        }
    }
}
