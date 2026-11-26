import Foundation
import Testing
import EhModels
import EhSettings
@testable import EhSpider

struct DownloadQualityTests {
    @Test func independentSessionCookiesRetainAuthenticationAndNeverMutateSource() throws {
        let source = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let web = try #require(URL(string: EhURL.host(for: .eHentai)))
        let api = try #require(URL(string: EhURL.apiUrl(for: .eHentai)))
        let foreign = try #require(URL(string: "https://fixture.invalid/"))
        for (name, value) in [("uconfig", "xr_980-xl_1-2-3-oi_y"), ("ipb_member_id", "synthetic")] {
            let cookie = try #require(HTTPCookie(properties: [
                .name: name, .value: value, .domain: ".e-hentai.org", .path: "/", .secure: "TRUE",
            ]))
            source.setCookie(cookie)
        }
        let first = SpiderQueen.sessionConfiguration(inactivity: 15, proxy: .init(), downloadQuality: .x780,
                                                     sourceCookies: source)
        let second = SpiderQueen.sessionConfiguration(inactivity: 15, proxy: .init(), downloadQuality: .original,
                                                      sourceCookies: source)
        let firstCookies = try #require(first.httpCookieStorage)
        let secondCookies = try #require(second.httpCookieStorage)
        #expect(firstCookies !== secondCookies && firstCookies !== source && secondCookies !== source)
        #expect(firstCookies.cookies(for: api)?.first { $0.name == "uconfig" }?.value == "xl_1-2-3-xr_780-oi_n")
        #expect(firstCookies.cookies(for: web)?.first { $0.name == "ipb_member_id" }?.value == "synthetic")
        #expect(secondCookies.cookies(for: web)?.first { $0.name == "uconfig" }?.value == "xl_1-2-3-xr_a-oi_n")
        #expect(source.cookies(for: web)?.first { $0.name == "uconfig" }?.value == "xr_980-xl_1-2-3-oi_y")
        #expect(firstCookies.cookies(for: foreign)?.isEmpty ?? true)
    }

    @Test(arguments: [
        QualityCase(quality: .original, hasOriginal: true, expectedFile: "original.png"),
        QualityCase(quality: .original, hasOriginal: false, expectedFile: "scaled.png"),
        QualityCase(quality: .x780, hasOriginal: true, expectedFile: "scaled.png"),
    ])
    func downloadSelectsCorrectImageAndDoesNotCopyUnratedReaderCache(test: QualityCase) async throws {
        let gid = Int64.random(in: 91_000_000...99_000_000)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cachePath = directory.appendingPathComponent("reader-cache")
        try FileManager.default.createDirectory(at: cachePath, withIntermediateDirectories: true)
        let gallery = GalleryInfo(gid: gid, token: "neutral", title: "Download quality", pages: 1)
        let fixture = QualityTransport(hasOriginal: test.hasOriginal)
        let info = SpiderInfo(gid: gid, token: gallery.token, pages: 1, pTokenMap: [0: "abcd"])
        let cache = SimpleDiskCache(directory: cachePath, maxSize: 8192)
        let den = SpiderDen(galleryID: gid, mode: .download, downloadDirectory: directory, readerCache: cache)
        #expect(cache.set(Data([0xFF, 0xD8, 0xFF, 0xD9]), forKey: "image_\(gid)_0"))
        let spider = SpiderQueen(galleryInfo: gallery, spiderInfo: info, mode: .download, spiderDen: den,
                                imageRequestTimeout: 10, downloadQuality: test.quality) {
            try await fixture.receive($0)
        }
        await spider.startDownload()
        #expect(await fixture.imageRequests == [test.expectedFile])
        let path = try #require(await spider.getLocalImageUrl(0))
        #expect(try Data(contentsOf: path) == Data(test.expectedFile.utf8))
    }
}

struct QualityCase: Sendable {
    let quality: DownloadQuality
    let hasOriginal: Bool
    let expectedFile: String
}

private actor QualityTransport {
    let hasOriginal: Bool
    private(set) var imageRequests: [String] = []
    init(hasOriginal: Bool) { self.hasOriginal = hasOriginal }

    func receive(_ request: URLRequest) throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let type: String
        let data: Data
        if url.path.hasPrefix("/s/") {
            type = "text/html"
            data = Data(("""
                <img id="img" src="https://fixture.invalid/scaled.png">
                """ + (hasOriginal ? "<a href=\"https://fixture.invalid/original.png\">Download original</a>" : "")).utf8)
        } else {
            #expect(url.host == "fixture.invalid")
            type = "image/png"
            imageRequests.append(url.lastPathComponent)
            data = Data(url.lastPathComponent.utf8)
        }
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                                     headerFields: ["Content-Type": type]))
        return (data, response)
    }
}
