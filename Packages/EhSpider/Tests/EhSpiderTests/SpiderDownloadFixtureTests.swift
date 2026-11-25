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
    private(set) var previewRequests: [Int] = []
    private let previewWidth: Int?
    private let totalPages: Int

    init(previewWidth: Int? = nil, totalPages: Int = 6) {
        self.previewWidth = previewWidth
        self.totalPages = totalPages
    }
    // A neutral, one-pixel PNG.
    static let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aewoAAAAASUVORK5CYII=")!

    func receive(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        if url.path.hasPrefix("/g/"), let previewWidth {
            let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "p" })?.value.flatMap(Int.init) ?? 0
            previewRequests.append(page)
            try await Task.sleep(for: .milliseconds(35))
            let start = page * previewWidth
            let html = (start..<max(start, min(start + previewWidth, totalPages))).map {
                "<a href=\"/s/abcd/29-\($0 + 1)\">Preview</a>"
            }.joined()
            return (Data(html.utf8), response(url, contentType: "text/html"))
        }
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
        if previewWidth == nil && page == 1 && attempts[page] == 1 {
            try await Task.sleep(for: .milliseconds(160))
            throw URLError(.timedOut)
        }
        try await Task.sleep(for: .milliseconds(previewWidth == nil ? 20 : 1))
        finished.append(page)
        return (Self.image, response(url, contentType: "image/png"))
    }

    private func response(_ url: URL, contentType: String) -> URLResponse {
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": contentType])!
    }
}

@Suite struct SpiderDownloadFixtureTests {
    @Test(arguments: [20, 40, 60])
    func downloadsEveryPageWithoutSeedTokensAndSharesPreviewRequests(width: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let total = 90
        let gallery = GalleryInfo(gid: 29, token: "neutral", title: "Synthetic download", pages: total)
        let transport = FixtureDownloadTransport(previewWidth: width, totalPages: total)
        let info = SpiderInfo(gid: gallery.gid, token: gallery.token, pages: total)
        let den = SpiderDen(galleryID: gallery.gid, mode: .download, downloadDirectory: directory)
        let spider = SpiderQueen(galleryInfo: gallery, spiderInfo: info, mode: .download, spiderDen: den,
                                imageRequestTimeout: 10) { request in try await transport.receive(request) }
        await spider.startDownload()

        #expect(await transport.imageRequests.sorted() == Array(1...total))
        #expect(await transport.previewRequests.sorted() == Array(0...((total - 1) / width)))
        #expect(await spider.getSpiderInfo().previewPerPage == width)
        for page in 0..<total {
            let path = try #require(await spider.getLocalImageUrl(page))
            #expect(try Data(contentsOf: path) == FixtureDownloadTransport.image)
        }
    }

    @Test func resumeRechecksStalePreviewWidthWithoutRedownloadingFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gallery = GalleryInfo(gid: 29, token: "neutral", title: "Synthetic resume", pages: 42)
        let transport = FixtureDownloadTransport(previewWidth: 40, totalPages: gallery.pages)
        let info = SpiderInfo(gid: gallery.gid, token: gallery.token, pages: gallery.pages,
                              previewPerPage: 20)
        let den = SpiderDen(galleryID: gallery.gid, mode: .download, downloadDirectory: directory)
        await den.setMode(.download)
        for page in 0..<40 {
            try #require(await den.write(data: FixtureDownloadTransport.image, index: page, extension: ".png"))
        }
        let spider = SpiderQueen(galleryInfo: gallery, spiderInfo: info, mode: .download, spiderDen: den,
                                imageRequestTimeout: 10) { request in try await transport.receive(request) }
        await spider.startDownload()

        #expect(await transport.previewRequests == [0, 1])
        #expect(await transport.imageRequests.sorted() == [41, 42])
        #expect(await spider.getSpiderInfo().previewPerPage == 40)
        for page in 0..<gallery.pages {
            #expect(await spider.getPageState(page) == SpiderQueen.stateFinish)
        }
    }

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
