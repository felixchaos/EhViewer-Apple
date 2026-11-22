//
//  ReaderStallTests.swift
//  ehviewer appleTests
//
//  阅读器「进度到 100% 之后掉回无限转圈」的那个死状态。
//
//  成因：downloadImageData 开头有
//  `guard !downloadingImages.contains(index) else { return }`，而下载被取消时
//  （每次翻页都会 preloadTask?.cancel()）只清 downloadProgress、并在 defer 里
//  把 index 从 downloadingImages 摘掉。于是可能出现：预加载正在下第 N 页 →
//  用户翻页把它取消 → onPageChange(N) 撞上还没摘干净的 downloadingImages 直接
//  返回 → 取消的任务收尾。最后没有任何任务在跑，这一页永远停在转圈上。
//
//  isStalled 是自愈看护 superviseLoading 的判据，这里守着它：漏判就等于
//  bug 原样回来，误判则会在正常下载途中重复发起请求。
//

import Testing
import EhModels
import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
@testable import ehviewer_apple

@MainActor
struct ReaderStallTests {

    private func makeViewModel() -> ReaderViewModel {
        let vm = ReaderViewModel()
        vm.gid = 1
        vm.token = "t"
        vm.totalPages = 10
        return vm
    }

    /// 地址已解析、图没拿到、没报错、没人在下 → 就是那个死状态
    @Test func stalledWhenNothingIsInFlight() {
        let vm = makeViewModel()
        vm.imageURLs[3] = "https://example.invalid/3.jpg"

        #expect(vm.isStalled(3))
    }

    /// 图已经在手上 → 不是死状态，别再去发请求
    @Test func notStalledWhenImageReady() {
        let vm = makeViewModel()
        vm.imageURLs[3] = "https://example.invalid/3.jpg"
        vm.cachedImages[3] = PlatformImage()

        #expect(!vm.isStalled(3))
    }

    /// 已经判定失败 → 交给错误界面的「重新加载」，看护不该抢
    @Test func notStalledWhenErrored() {
        let vm = makeViewModel()
        vm.imageURLs[3] = "https://example.invalid/3.jpg"
        vm.errorPages.insert(3)

        #expect(!vm.isStalled(3))
    }

    /// 连地址都还没有也算死状态：解析 pToken 这一步同样会被翻页取消，
    /// 卡在那一层一样是永久转圈
    @Test func stalledBeforeURLResolved() {
        let vm = makeViewModel()

        #expect(vm.isStalled(5))
    }
}

// MARK: - 标签精确搜索式

/// 点列表行里的标签 chip 要能真的搜到东西。
///
/// 带命名空间的标签此前是原样透传的：`female:big ass` 里的空格把它拆成
/// `female:big` 和 `ass` 两个词，搜不到任何结果。而不含空格的标签
/// （`parody:haikyuu!!`）恰好是好的，所以这个 bug 只在一部分标签上出现。
@MainActor
struct TagQueryTests {

    @Test func namespacedTagWithSpaceIsQuoted() {
        #expect(GalleryListView.exactTagQuery(for: "female:big ass") == "female:\"big ass$\"")
    }

    @Test func bareTagIsQuoted() {
        #expect(GalleryListView.exactTagQuery(for: "big ass") == "\"big ass$\"")
    }

    @Test func namespacedTagWithoutSpaceStillQuoted() {
        #expect(GalleryListView.exactTagQuery(for: "parody:haikyuu!!") == "parody:\"haikyuu!!$\"")
    }

    /// 冒号在开头或结尾时不拆，整体当成裸标签处理，别拼出 `:"..."` 这种废式子
    @Test func degenerateColonsFallBackToBareForm() {
        #expect(GalleryListView.exactTagQuery(for: ":x") == "\":x$\"")
        #expect(GalleryListView.exactTagQuery(for: "x:") == "\"x:$\"")
    }
}

@MainActor
struct ReaderResizeTests {
    @Test func unfoldingAndRefoldingPreserveTheSecondaryLogicalPage() {
        let vm = ReaderViewModel()
        vm.totalPages = 10
        vm.currentPage = 4
        vm.lazyCurrentPage = 4
        vm.computeSpreads()

        vm.updateLayout(screenWidth: 820, screenHeight: 650)
        #expect(vm.isDoublePageEnabled)
        #expect(vm.currentSpreadIndex == 2)
        #expect(vm.pageTurnTarget(forSpreadID: 2) == nil)
        #expect(vm.pageTurnTarget(forSpreadID: 3) == 5)
        #expect(vm.pageTurnTarget(forSpreadID: nil) == nil)

        vm.lazyCurrentPage = 1 // stale scroll anchor from the old single-page view
        vm.updateLayout(screenWidth: 410, screenHeight: 800)
        #expect(!vm.isDoublePageEnabled)
        #expect(vm.currentPage == 4)
        #expect(vm.lazyCurrentPage == 4)
        #expect(vm.currentSpreadIndex == 4)
    }

    @Test func rotationKeepsCoverAndVerticalAnchorAndHonorsManualMode() {
        let vm = ReaderViewModel()
        vm.totalPages = 10
        vm.currentPage = 0
        vm.verticalScrollPage = 0
        vm.updateLayout(screenWidth: 820, screenHeight: 650)
        #expect(vm.spreads.first?.pages == [0])
        #expect(vm.verticalScrollPage == 0)
        #expect(vm.pageTurnTarget(forSpreadID: 0) == nil)
        vm.toggleDoublePage()
        vm.updateLayout(screenWidth: 1024, screenHeight: 680)
        #expect(!vm.isDoublePageEnabled)
        #expect(vm.currentPage == 0)
    }
}

@MainActor
struct ReaderOpeningTests {
    private func withStore(_ operation: (ReaderProgressStore, UserDefaults) -> Void) throws {
        let suite = "ehviewer.reader-opening.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        operation(ReaderProgressStore(defaults: defaults), defaults)
    }

    @Test func explicitPageOverridesResumeWithoutFallingBackForInvalidLinks() throws {
        try withStore { progress, _ in
            progress.save(4, for: 42)
            #expect(progress.openingPage(for: 42, requested: 0, pageCount: 6) == 0)
            #expect(progress.openingPage(for: 42, requested: 5, pageCount: 6) == 5)
            #expect(progress.openingPage(for: 42, requested: -1, pageCount: 6) == nil)
            #expect(progress.openingPage(for: 42, requested: 6, pageCount: 6) == nil)
            #expect(progress.openingPage(for: 42, requested: 0, pageCount: 0) == nil)
        }
    }

    @Test func persistedResumeUsesExistingKeysAndGalleryIsolation() throws {
        try withStore { progress, defaults in
            defaults.set(9, forKey: "reading_progress_42")
            #expect(progress.openingPage(for: 42, requested: nil, pageCount: 5) == 4)
            #expect(progress.openingPage(for: 42, requested: nil, pageCount: 0) == nil)
            #expect(progress.openingPage(for: 43, requested: nil, pageCount: 9) == nil)

            progress.save(0, for: 43)
            let reopened = ReaderProgressStore(defaults: defaults)
            #expect(reopened.openingPage(for: 43, requested: nil, pageCount: 9) == 0)
            #expect(defaults.object(forKey: "reading_progress_43") as? Int == 0)
            #expect(defaults.object(forKey: "reading_progress_42") as? Int == 9)
        }
    }

    @Test func sameGalleryReentryResynchronizesAllReaderAnchors() throws {
        try withStore { progress, _ in
            let vm = ReaderViewModel()
            vm.gid = 42
            vm.token = "fixture"
            vm.totalPages = 12
            vm.currentPage = 1
            vm.isDoublePageEnabled = true
            vm.computeSpreads()
            progress.save(7, for: 42)

            #expect(!vm.prepareForGallery(targetGid: 42, targetToken: "fixture"))
            vm.applyOpeningPage(nil, galleryID: 42, progress: progress)
            #expect(vm.currentPage == 7)
            #expect(vm.lazyCurrentPage == 7)
            #expect(vm.verticalScrollPage == 7)
            #expect(vm.currentSpreadIndex == vm.spreadIndex(for: 7))

            vm.applyOpeningPage(3, galleryID: 42, progress: progress)
            #expect(vm.currentPage == 3)
            #expect(vm.lazyCurrentPage == 3)
            #expect(vm.verticalScrollPage == 3)
            #expect(vm.currentSpreadIndex == vm.spreadIndex(for: 3))

            vm.applyOpeningPage(12, galleryID: 42, progress: progress)
            #expect(vm.currentPage == 3)
            vm.saveReadingProgress(for: 42, progress: progress)
            #expect(progress.savedPage(for: 42) == 3)
        }
    }
}

struct ReaderPagingCommitTests {
    @Test func abortedGestureDoesNotCommitTransientCandidate() {
        var paging = ReaderPagingCommit()
        paging.begin(from: 1)
        // Moving/decelerating can cross other native anchors. No commit is
        // requested until we're told which anchor actually settled.
        paging.begin(from: 1)
        #expect(paging.settle(logicalPage: 1, candidate: 1, totalPages: 5) == .unchanged)
        #expect(paging.settle(logicalPage: 1, candidate: 2, totalPages: 5) == .unchanged)
    }

    @Test func settleCommitsOnlyTheLandingPageInEitherDirection() {
        var paging = ReaderPagingCommit()
        paging.begin(from: 1)
        paging.begin(from: 1) // interrupted inertia stays in the same session
        #expect(paging.settle(logicalPage: 1, candidate: 3, totalPages: 5) == .move(to: 3))
        paging.begin(from: 3)
        #expect(paging.settle(logicalPage: 3, candidate: 2, totalPages: 5) == .move(to: 2))
    }

    @Test func concurrentExplicitJumpWinsEvenBeforeItsObserverRuns() {
        var paging = ReaderPagingCommit()
        paging.begin(from: 1)
        #expect(paging.settle(logicalPage: 4, candidate: 2, totalPages: 5) == .restoreExplicitAnchor)

        paging.begin(from: 1)
        paging.explicitPageChanged()
        paging.begin(from: 1)
        #expect(paging.settle(logicalPage: 1, candidate: 2, totalPages: 5) == .restoreExplicitAnchor)

        paging.begin(from: 1)
        #expect(paging.settle(logicalPage: 1, candidate: 2, totalPages: 5) == .move(to: 2))
    }

    @Test func nilOrInvalidFinalAnchorDoesNotChangeProgress() {
        for candidate in [nil, -1, 5] {
            var paging = ReaderPagingCommit()
            paging.begin(from: 1)
            #expect(paging.settle(logicalPage: 1, candidate: candidate, totalPages: 5) == .unchanged)
        }
    }
}

@MainActor
struct ReaderDownloadedPageIOTests {
    @Test func loadingAFileDoesNotRunOnTheMainThreadAndClearsExistingError() async {
        let vm = ReaderViewModel()
        vm.gid = 900010001001
        let url = URL(fileURLWithPath: "/fixture-only/00000001.png")
        vm.imageURLs[0] = url.absoluteString
        vm.errorPages.insert(0)
        vm.downloadProgress[0] = 0.5

        let gate = HeldReaderFileDecode()
        let task = Task {
            await vm.loadDownloadedPage(0, from: url, source: url.absoluteString, decode: { gate.decode($0) })
        }
        var entered = gate.entered.makeAsyncIterator()
        #expect(await entered.next() == false)
        #expect(vm.cachedImages[0] == nil)
        gate.release()
        await task.value
        #expect(vm.cachedImages[0] != nil)
        #expect(!vm.errorPages.contains(0))
        #expect(vm.downloadProgress[0] == nil)
    }

    @Test func cancelledFileReadCannotPublish() async {
        let vm = ReaderViewModel()
        vm.gid = 900010001002
        let url = URL(fileURLWithPath: "/fixture-only/00000001.png")
        vm.imageURLs[0] = url.absoluteString

        let gate = HeldReaderFileDecode()
        let task = Task {
            await vm.loadDownloadedPage(0, from: url, source: url.absoluteString, decode: { gate.decode($0) })
        }
        var entered = gate.entered.makeAsyncIterator()
        #expect(await entered.next() == false)
        task.cancel()
        gate.release()
        await task.value
        #expect(vm.cachedImages[0] == nil)
        #expect(!vm.errorPages.contains(0))
    }

    @Test func oldFileReadCannotPublishAfterSameGalleryIsReopened() async {
        let vm = ReaderViewModel()
        let gid: Int64 = 900010001003
        vm.gid = gid
        let url = URL(fileURLWithPath: "/fixture-only/00000001.png")
        vm.imageURLs[0] = url.absoluteString

        let gate = HeldReaderFileDecode()
        let task = Task {
            await vm.loadDownloadedPage(0, from: url, source: url.absoluteString, decode: { gate.decode($0) })
        }
        var entered = gate.entered.makeAsyncIterator()
        #expect(await entered.next() == false)
        _ = vm.prepareForGallery(targetGid: gid + 1, targetToken: "fixture")
        _ = vm.prepareForGallery(targetGid: gid, targetToken: "fixture")
        vm.imageURLs[0] = url.absoluteString
        gate.release()
        await task.value
        #expect(vm.cachedImages[0] == nil)
        #expect(!vm.errorPages.contains(0))
    }

    @Test func missingDownloadedFileKeepsExistingReadError() async {
        let vm = ReaderViewModel()
        vm.gid = 900010001004
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reader-missing-filename-\(UUID())")
        vm.imageURLs[0] = url.absoluteString
        await vm.loadDownloadedPage(0, from: url, source: url.absoluteString)
        #expect(vm.cachedImages[0] == nil)
        #expect(vm.errorPages.contains(0))
        #expect(vm.errorMessages[0] == "本地文件读取失败")
    }
}

private final class HeldReaderFileDecode: Sendable {
    let entered: AsyncStream<Bool>
    private let continuation: AsyncStream<Bool>.Continuation
    private let wait = DispatchSemaphore(value: 0)

    init() {
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        self.entered = stream
        self.continuation = continuation
    }

    nonisolated func decode(_ url: URL) -> PlatformImage? {
        continuation.yield(Thread.isMainThread)
        continuation.finish()
        // Bound the fixture even if an assertion or task fails before release.
        guard wait.wait(timeout: .now() + 5) == .success else { return nil }
        return PlatformImage()
    }

    func release() { wait.signal() }
}

@MainActor
struct ReaderDiskCacheOwnershipTests {
    @Test func currentMissAllowsTheExistingURLFallback() async {
        let vm = ReaderViewModel()
        vm.gid = 900010001011
        let result = await vm.readPageFromDiskCache(0, lookup: { _, _ in nil })
        #expect(result == .missing)
    }

    @Test func cancelledOrRetriedMissCannotReachFallback() async {
        let vm = ReaderViewModel()
        vm.gid = 900010001012
        let cancelled = HeldReaderCacheLookup()
        let oldTask = Task { await vm.readPageFromDiskCache(0, lookup: { _, _ in await cancelled.read() }) }
        await cancelled.waitUntilStarted()
        oldTask.cancel()
        await cancelled.finish()
        #expect(await oldTask.value == .stale)

        let retried = HeldReaderCacheLookup()
        let newerRetry = Task { await vm.readPageFromDiskCache(0, lookup: { _, _ in await retried.read() }) }
        await retried.waitUntilStarted()
        vm.retryGeneration[0] = 1
        await retried.finish()
        #expect(await newerRetry.value == .stale)
    }

    @Test func oldCacheHitCannotPublishAfterABAContextSwitch() async {
        let vm = ReaderViewModel()
        let original: Int64 = 900010001014
        vm.gid = original
        let hit = HeldReaderCacheLookup()
        let task = Task { await vm.readPageFromDiskCache(0, lookup: { _, _ in await hit.read() }) }
        await hit.waitUntilStarted()
        _ = vm.prepareForGallery(targetGid: original + 1, targetToken: "fixture")
        _ = vm.prepareForGallery(targetGid: original, targetToken: "fixture")
        await hit.finish(with: Data([99]))
        #expect(await task.value == .stale)
        #expect(vm.cachedImages[0] == nil)
    }

    @Test func cancelledLookupCannotDropItsReplacementTaskSlot() async {
        let vm = ReaderViewModel()
        vm.gid = 900010001013
        let old = HeldReaderCacheLookup()
        let replacement = HeldReaderCacheLookup()

        let first = Task { await vm.downloadImageData(0, cacheLookup: { _, _ in await old.read() }) }
        await old.waitUntilStarted()
        vm.cancelDownload(0)
        let current = Task { await vm.downloadImageData(0, cacheLookup: { _, _ in await replacement.read() }) }
        await replacement.waitUntilStarted()
        await old.finish()
        await first.value
        #expect(vm.activeDownloadPages().contains(0))
        await replacement.finish()
        await current.value
        #expect(!vm.activeDownloadPages().contains(0))
    }
}

/// The lookup simulates an already enqueued disk read: caller cancellation
/// doesn't make the actual disk work suddenly return.
private actor HeldReaderCacheLookup {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var result: CheckedContinuation<Data?, Never>?

    func waitUntilStarted() async {
        if !started { await withCheckedContinuation { startWaiter = $0 } }
    }

    func read() async -> Data? {
        await withCheckedContinuation {
            result = $0
            started = true
            startWaiter?.resume()
            startWaiter = nil
        }
    }

    func finish(with bytes: Data? = nil) {
        result?.resume(returning: bytes)
        result = nil
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ReaderDirectResponseOwnershipTests {
    private let fixtureURL = URL(string: "https://image.invalid/fixture.jpg")!

    @Test(arguments: [false, true])
    func staleDirectDecodeCannotWriteAfterGallerySwitch(returnToOriginal: Bool) async {
        let vm = ReaderViewModel()
        let original: Int64 = 900010001020
        vm.gid = original
        let lookup = HeldReaderCacheLookup()
        let active = Task { await vm.downloadImageData(0, cacheLookup: { _, _ in await lookup.read() }) }
        await lookup.waitUntilStarted()
        guard let owner = vm.imageDownloadOwner(for: 0) else {
            await lookup.finish()
            await active.value
            Issue.record("Expected an active page slot")
            return
        }

        let decode = HeldReaderCacheLookup()
        var writes: [Int64] = []
        let response = Task {
            await vm.completeDirectImage(
                0, data: Data([1]), url: fixtureURL, owner: owner,
                decode: { _ = await decode.read(); return PlatformImage() },
                cacheWriter: { _, gallery, _ in writes.append(gallery) },
                persistentWriter: { _, gallery, _ in writes.append(gallery) }
            )
        }
        await decode.waitUntilStarted()
        _ = vm.prepareForGallery(targetGid: original + 1, targetToken: "fixture")
        if returnToOriginal {
            _ = vm.prepareForGallery(targetGid: original, targetToken: "fixture")
        }
        let replacementLookup = HeldReaderCacheLookup()
        let replacement = Task {
            await vm.downloadImageData(0, cacheLookup: { _, _ in await replacementLookup.read() })
        }
        await replacementLookup.waitUntilStarted()
        vm.downloadProgress[0] = 0.25
        await decode.finish()
        await response.value
        await lookup.finish()
        await active.value
        #expect(writes.isEmpty)
        #expect(vm.cachedImages[0] == nil)
        #expect(vm.downloadProgress[0] == 0.25)
        #expect(vm.activeDownloadPages().contains(0))
        await replacementLookup.finish()
        await replacement.value
    }

    @Test func directResponseUsesOriginalKeyAndDoesNotPublishAfterCancellationDuringPersistence() async {
        let vm = ReaderViewModel()
        vm.gid = 900010001022
        let lookup = HeldReaderCacheLookup()
        let active = Task { await vm.downloadImageData(0, cacheLookup: { _, _ in await lookup.read() }) }
        await lookup.waitUntilStarted()
        guard let owner = vm.imageDownloadOwner(for: 0) else {
            await lookup.finish()
            await active.value
            Issue.record("Expected an active page slot")
            return
        }
        let persistence = HeldReaderCacheLookup()
        var writes: [String] = []
        let response = Task {
            await vm.completeDirectImage(
                0, data: Data([1]), url: fixtureURL, owner: owner,
                decode: { PlatformImage() },
                cacheWriter: { _, gid, page in writes.append("cache:\(gid):\(page)") },
                persistentWriter: { _, gid, page in
                    writes.append("persistent:\(gid):\(page)")
                    _ = await persistence.read()
                }
            )
        }
        await persistence.waitUntilStarted()
        #expect(writes == ["cache:900010001022:0", "persistent:900010001022:0"])
        #expect(vm.cachedImages[0] == nil)
        vm.cancelDownload(0)
        await persistence.finish()
        await response.value
        #expect(vm.cachedImages[0] == nil)
        await lookup.finish()
        await active.value
    }
}

#if DEBUG
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ReaderDirectResponsePipelineTests {
    @Test func retryPublishesOnlyTheReplacementStreamAndWritesItsBytes() async throws {
        let original = URL(string: "https://image.invalid/old.png")!
        let replacement = URL(string: "https://image.invalid/new.png")!
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReaderDirectFixtureProtocol.self]
        config.httpCookieStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        let cachedPage = cache.appendingPathComponent("read-cache.png")
        let persistedPage = cache.appendingPathComponent("reading-sync.png")

        let oldHold = HeldReaderCacheLookup()
        let newHold = HeldReaderCacheLookup()
        let vm = ReaderViewModel()
        let gallery: Int64 = 900010001025
        vm.gid = gallery
        vm.totalPages = 1
        vm.imageURLs[0] = original.absoluteString
        var writeKeys: [String] = []
        vm.directResponseFixture = .init(
            session: session, retryURL: replacement,
            beforeDecode: { url in
                if url == original { _ = await oldHold.read() }
                else if url == replacement { _ = await newHold.read() }
            },
            cacheWriter: { data, gid, page in
                writeKeys.append("cache:\(gid):\(page)")
                do { try data.write(to: cachedPage) } catch { Issue.record(error) }
            },
            persistentWriter: { data, gid, page in
                writeKeys.append("persistent:\(gid):\(page)")
                do { try data.write(to: persistedPage) } catch { Issue.record(error) }
            }
        )

        let first = Task { await vm.downloadImageData(0) }
        await oldHold.waitUntilStarted()
        #expect(vm.downloadProgress[0] == 1)
        let retry = Task { await vm.retryLoadPage(0) }
        await newHold.waitUntilStarted()
        #expect(vm.retryGeneration[0] == 1)
        await oldHold.finish()
        await first.value
        #expect(writeKeys.isEmpty)
        #expect(vm.cachedImages[0] == nil)
        #expect(vm.downloadProgress[0] == 1)
        #expect(vm.activeDownloadPages().contains(0))
        await newHold.finish()
        await retry.value

        #expect(writeKeys == ["cache:\(gallery):0", "persistent:\(gallery):0"])
        #expect(try Data(contentsOf: cachedPage) == ReaderDirectFixtureProtocol.replacementPNG)
        #expect(try Data(contentsOf: persistedPage) == ReaderDirectFixtureProtocol.replacementPNG)
        #expect(vm.cachedImages[0]?.size == CGSize(width: 1, height: 1))
        #expect(vm.downloadProgress[0] == nil)
        #expect(vm.errorPages.isEmpty)
        #expect(!vm.activeDownloadPages().contains(0))
    }
}

private final class ReaderDirectFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let originalPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
    )!
    static let replacementPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYPgPAAEDAQAIicLsAAAAAElFTkSuQmCC"
    )!

    // Catch every request from the isolated ephemeral session. Nothing can escape
    // this protocol to a live service, even if production retry constructs a wrong URL.
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.host == "image.invalid",
              url.path == "/old.png" || url.path == "/new.png" else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let data = url.path == "/old.png" ? Self.originalPNG : Self.replacementPNG
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/png", "Content-Length": "\(data.count)"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif

#if os(iOS)
@MainActor struct ReaderSpreadBudgetTests {
    private func page(_ size: CGSize, color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func spread(_ primary: UIImage, _ secondary: UIImage?) -> ReaderViewModel {
        let model = ReaderViewModel()
        model.spreads = [.init(id: 0, primaryPage: 0, secondaryPage: 1)]
        model.cachedImages = [0: primary]
        model.cachedImages[1] = secondary
        return model
    }

    @Test func preservesPrimaryUntilPartnerArrivesAndDoesNotMagnifySourcePixels() throws {
        let first = page(CGSize(width: 1600, height: 2400), color: .red)
        let second = page(CGSize(width: 1600, height: 2400), color: .blue)
        let model = spread(first, nil)
        #expect(model.spreadPresentation(at: 0, direction: .leftToRight)?.image === first)
        model.cachedImages[1] = second
        let image = try #require(model.spreadPresentation(at: 0, direction: .leftToRight)).image
        let cg = try #require(image.cgImage)
        #expect(image.scale == 1)
        #expect(cg.width == 3200)
        #expect(cg.height == 2400)
    }

    @Test func largePairRespectsHardPixelBudgetAndProportions() throws {
        let first = page(CGSize(width: 2600, height: 3600), color: .red)
        let model = spread(first, first)
        let presentation = try #require(model.spreadPresentation(at: 0, direction: .leftToRight))
        let cg = try #require(presentation.image.cgImage)
        #expect(presentation.logicalSize == CGSize(width: 5200, height: 3600))
        #expect(cg.width * cg.height <= 16 * 1024 * 1024)
        #expect(abs(Double(cg.width) / Double(cg.height) - 5200.0 / 3600) < 0.002)
    }

    @Test func boundedRasterKeepsOriginalFixedAndFitScrollGeometry() {
        let raster = page(CGSize(width: 48, height: 36), color: .blue)
        let logical = CGSize(width: 6000, height: 4500)
        func layout(_ mode: ScaleMode, logicalSize: CGSize?) -> CGSize {
            let scroll = ZoomableScrollView(frame: CGRect(x: 0, y: 0, width: 900, height: 450))
            scroll.scaleMode = mode
            scroll.logicalImageSize = logicalSize
            let imageView = UIImageView(image: raster)
            imageView.tag = 1001
            scroll.addSubview(imageView)
            scroll.layoutSubviews()
            return scroll.contentSize
        }
        #expect(layout(.origin, logicalSize: logical) == logical)
        #expect(layout(.fixed, logicalSize: logical) == logical)
        #expect(layout(.fit, logicalSize: logical) == CGSize(width: 600, height: 450))
        #expect(layout(.fitWidth, logicalSize: logical) == CGSize(width: 900, height: 675))
        #expect(layout(.origin, logicalSize: nil) == raster.size)
    }

    @Test func repeatsReuseOneBitmapButDirectionAndReplacementDoNot() throws {
        let first = page(CGSize(width: 32, height: 32), color: .red)
        let second = page(CGSize(width: 32, height: 32), color: .blue)
        let model = spread(first, second)
        let original = try #require(model.spreadPresentation(at: 0, direction: .leftToRight)).image
        #expect(model.spreadPresentation(at: 0, direction: .leftToRight)?.image === original)

        let reversed = try #require(model.spreadPresentation(at: 0, direction: .rightToLeft)).image
        #expect(reversed !== original)
        #expect(model.spreadPresentation(at: 0, direction: .rightToLeft)?.image === reversed)

        model.cachedImages[1] = nil
        #expect(model.spreadPresentation(at: 0, direction: .rightToLeft)?.image === first)
        model.cachedImages[1] = second
        let restored = try #require(model.spreadPresentation(at: 0, direction: .rightToLeft)).image
        #expect(restored !== reversed)

        model.cachedImages[1] = page(CGSize(width: 48, height: 32), color: .green)
        let replacement = try #require(model.spreadPresentation(at: 0, direction: .rightToLeft))
        #expect(replacement.image !== restored)
        #expect(replacement.logicalSize == CGSize(width: 80, height: 32))
    }

    @Test func composingAnotherPairAndDiscardingKeepsAtMostOneEntry() throws {
        let first = page(CGSize(width: 32, height: 32), color: .red)
        let second = page(CGSize(width: 32, height: 32), color: .blue)
        let model = spread(first, second)
        model.spreads.append(.init(id: 1, primaryPage: 1, secondaryPage: 2))
        model.cachedImages[2] = first
        let previous = try #require(model.spreadPresentation(at: 0, direction: .leftToRight)).image
        _ = model.spreadPresentation(at: 1, direction: .leftToRight)
        let current = try #require(model.spreadPresentation(at: 0, direction: .leftToRight)).image
        #expect(current !== previous)
        model.discardSpreadComposition()
        #expect(model.spreadPresentation(at: 0, direction: .leftToRight)?.image !== current)
        _ = model.prepareForGallery(targetGid: 471, targetToken: "fixture")
        #expect(model.spreadPresentation(at: 0, direction: .leftToRight) == nil)
    }

    @Test func enteringVerticalReleasesReuseEvenWhenTheWindowStillSupportsSpreads() throws {
        let first = page(CGSize(width: 32, height: 32), color: .red)
        let second = page(CGSize(width: 32, height: 32), color: .blue)
        let model = spread(first, second)
        model.isDoublePageEnabled = true
        let original = try #require(model.spreadPresentation(at: 0, direction: .leftToRight)).image
        model.discardSpreadOnEnteringVertical(from: .leftToRight, to: .rightToLeft)
        #expect(model.spreadPresentation(at: 0, direction: .leftToRight)?.image === original)
        model.discardSpreadOnEnteringVertical(from: .leftToRight, to: .topToBottom)
        #expect(model.isDoublePageEnabled)
        #expect(model.spreadPresentation(at: 0, direction: .leftToRight)?.image !== original)
    }

    private func rgb(_ image: CGImage, x: Int) throws -> [UInt8] {
        let sample = try #require(image.cropping(to: CGRect(x: x, y: 8, width: 1, height: 1)))
        var pixel = [UInt8](repeating: 0, count: 4)
        let ok = pixel.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                          bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        #expect(ok)
        return pixel
    }

    @Test func originalVisualOrderMatchesBothReadingDirections() throws {
        let first = page(CGSize(width: 32, height: 32), color: .red)
        let second = page(CGSize(width: 32, height: 32), color: .blue)
        let model = spread(first, second)
        let ltr = try #require(model.spreadPresentation(at: 0, direction: .leftToRight)?.image.cgImage)
        let rtl = try #require(model.spreadPresentation(at: 0, direction: .rightToLeft)?.image.cgImage)
        let ltrLeft = try rgb(ltr, x: 8)
        let ltrRight = try rgb(ltr, x: 40)
        let rtlLeft = try rgb(rtl, x: 8)
        let rtlRight = try rgb(rtl, x: 40)
        #expect(ltrLeft == rtlRight)
        #expect(ltrRight == rtlLeft)
        #expect(ltrLeft[0] > ltrLeft[2])
        #expect(ltrRight[2] > ltrRight[0])
    }
}
#endif

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ReaderPageResolverOwnershipTests {
    @Test(arguments: [false, true])
    func oldHTMLCannotPublishOrDropReplacementMarkers(returnToOriginal: Bool) async {
        let vm = ReaderViewModel()
        let original: Int64 = returnToOriginal ? 900010001031 : 900010001032
        let other = original + 100
        vm.gid = original
        vm.totalPages = 1
        defer {
            GalleryCache.shared.removeImageURL(gid: original, page: 0)
            GalleryCache.shared.removeImageURL(gid: other, page: 0)
        }
        let oldPage = HeldReaderCacheLookup()
        let old = ReaderViewModel.PageResolver(
            html: { _ in "/s/aaaa/\(original)-1" },
            page: { _ in _ = await oldPage.read(); return .init(imageUrl: "https://image.invalid/old.png") },
            sleep: { _ in Issue.record("Old retry must stop at its ownership boundary"); throw CancellationError() }
        )
        let first = Task { await vm.loadPageWithRetry(0, resolver: old) }
        await oldPage.waitUntilStarted()
        _ = vm.prepareForGallery(targetGid: other, targetToken: "fixture")
        if returnToOriginal { _ = vm.prepareForGallery(targetGid: original, targetToken: "fixture") }
        let current = vm.gid
        vm.totalPages = 1
        let newPage = HeldReaderCacheLookup()
        let replacement = ReaderViewModel.PageResolver(
            html: { _ in "/s/bbbb/\(current)-1" },
            page: { url in
                #expect(url.hasSuffix("/s/bbbb/\(current)-1"))
                _ = await newPage.read()
                return .init(imageUrl: "https://image.invalid/new.png")
            },
            sleep: { _ in Issue.record("Resolved response must not sleep"); throw CancellationError() }
        )
        let second = Task { await vm.loadPageWithRetry(0, resolver: replacement) }
        await newPage.waitUntilStarted()
        await oldPage.finish()
        await first.value
        #expect(vm.imageURLs[0] == nil)
        #expect(GalleryCache.shared.getImageURL(gid: original, page: 0) == nil)
        #expect(GalleryCache.shared.getImageURL(gid: current, page: 0) == nil)
        #expect(vm.retryingPages[0] == 0)
        #expect(!vm.isStalled(0))
        await newPage.finish()
        await second.value
        #expect(vm.imageURLs[0] == "https://image.invalid/new.png")
        #expect(GalleryCache.shared.getImageURL(gid: current, page: 0) == vm.imageURLs[0])
        #expect(vm.retryingPages[0] == nil)
    }

    @Test func cancelledDiagnosticDoesNotInstallErrorOrLeaveMarkers() async {
        let vm = ReaderViewModel()
        let gid: Int64 = 900010001033
        vm.gid = gid
        vm.totalPages = 1
        let diagnostic = HeldReaderCacheLookup()
        let resolver = ReaderViewModel.PageResolver(
            html: { request in
                if request.contains("/s/") {
                    _ = await diagnostic.read()
                    return "neutral diagnostic"
                }
                return "/s/aaaa/\(gid)-1"
            },
            page: { _ in .init() },
            sleep: { _ in Issue.record("Cancelled diagnostic must not sleep"); throw CancellationError() }
        )
        let task = Task { await vm.loadPageWithRetry(0, resolver: resolver) }
        await diagnostic.waitUntilStarted()
        task.cancel()
        await diagnostic.finish()
        await task.value
        #expect(vm.errorPages.isEmpty)
        #expect(vm.retryingPages.isEmpty)
        #expect(vm.isStalled(0))
    }

    @Test func currentRetryKeepsBackoffAndPublishesSuccessfulURL() async {
        let vm = ReaderViewModel()
        let gid: Int64 = 900010001035
        vm.gid = gid
        vm.totalPages = 1
        defer { GalleryCache.shared.removeImageURL(gid: gid, page: 0) }
        var attempts: [Int] = []
        var delays: [UInt64] = []
        let resolver = ReaderViewModel.PageResolver(
            html: { _ in "/s/aaaa/\(gid)-1" },
            page: { _ in
                attempts.append(vm.retryingPages[0] ?? -1)
                if attempts.count < 3 { throw URLError(.timedOut) }
                return .init(imageUrl: "https://image.invalid/current.png")
            },
            sleep: { delays.append($0) }
        )
        await vm.loadPageWithRetry(0, resolver: resolver)
        #expect(attempts == [0, 1, 2])
        #expect(delays == [1_000_000_000, 2_000_000_000])
        #expect(vm.imageURLs[0] == "https://image.invalid/current.png")
        #expect(vm.retryingPages[0] == nil)
    }

    @Test func galleryTokenResponseDoesNotOverwriteRetriedSiblingButSeedsUnchangedSibling() async {
        let vm = ReaderViewModel()
        let gid: Int64 = 900010001034
        vm.gid = gid
        vm.totalPages = 3
        defer { for i in 0..<3 { GalleryCache.shared.removeImageURL(gid: gid, page: i) } }
        let html = HeldReaderCacheLookup()
        let first = ReaderViewModel.PageResolver(
            html: { _ in
                _ = await html.read()
                return "/s/aaaa/\(gid)-1 /s/bbbb/\(gid)-2 /s/cccc/\(gid)-3"
            },
            page: { _ in .init(imageUrl: "https://image.invalid/first.png") },
            sleep: { _ in throw CancellationError() }
        )
        let old = Task { await vm.loadPage(0, resolver: first) }
        await html.waitUntilStarted()
        vm.retryGeneration[1, default: 0] += 1
        await html.finish()
        await old.value
        let sibling = ReaderViewModel.PageResolver(
            html: { _ in "/s/dddd/\(gid)-2" },
            page: { url in
                #expect(url.hasSuffix("/s/dddd/\(gid)-2") || url.hasSuffix("/s/cccc/\(gid)-3"))
                return .init(imageUrl: url)
            },
            sleep: { _ in throw CancellationError() }
        )
        await vm.loadPage(1, resolver: sibling)
        await vm.loadPage(2, resolver: sibling)
        #expect(vm.imageURLs[1]?.hasSuffix("/s/dddd/\(gid)-2") == true)
        #expect(vm.imageURLs[2]?.hasSuffix("/s/cccc/\(gid)-3") == true)
    }
}

#if DEBUG
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ReaderNavigationMaintenanceTests {
    @Test func suspendedSpreadCannotEvictCurrentPairOrCancelItsPreload() async {
        let vm = ReaderViewModel()
        vm.totalPages = 120
        vm.updateLayout(screenWidth: 1024, screenHeight: 768)
        vm.currentPage = 3
        let oldLoad = HeldReaderCacheLookup()
        let newestPrefetch = HeldReaderCacheLookup()
        var preloadAnchors: [Int] = []
        var newestCancelled: Bool?

        let first = Task {
            await vm.onPageChange(3, load: { page in
                if page == 3 { _ = await oldLoad.read() }
            }, prefetch: { preloadAnchors.append($0) })
        }
        await oldLoad.waitUntilStarted()
        vm.currentPage = 83
        await vm.onPageChange(83, load: { page in
            vm.cachedImages[page] = PlatformImage()
        }, prefetch: { page in
            preloadAnchors.append(page)
            _ = await newestPrefetch.read()
            newestCancelled = Task.isCancelled
        })
        await newestPrefetch.waitUntilStarted()
        #expect(vm.cachedImages[83] != nil && vm.cachedImages[84] != nil)

        await oldLoad.finish()
        await first.value
        #expect(vm.currentPage == 83)
        #expect(vm.cachedImages[83] != nil && vm.cachedImages[84] != nil)
        #expect(preloadAnchors == [83])
        await newestPrefetch.finish()
        // The prefetch task records cancellation only after leaving the fixture.
        // Give it a deterministic completion handshake before asserting.
        await vm.waitForScheduledPrefetchInTests()
        #expect(newestCancelled == false)
    }

    @Test func duplicateCurrentSelectionDoesNotStrandItsResolvingSecondary() async {
        let vm = ReaderViewModel()
        vm.totalPages = 120
        vm.updateLayout(screenWidth: 1024, screenHeight: 768)
        vm.currentPage = 83
        let secondaryHTML = HeldReaderCacheLookup()
        var resolvingSecondary = false
        var secondaryURLReady = false
        var loadedSecondary = 0
        var prefetchOwners: [String] = []
        let resolve: (Int) async -> Void = { page in
            guard page == 84, !resolvingSecondary else { return }
            resolvingSecondary = true
            _ = await secondaryHTML.read()
            secondaryURLReady = true
        }
        let load: (Int) async -> Void = { page in
            if page == 84 {
                guard secondaryURLReady else { return }
                loadedSecondary += 1
            }
            vm.cachedImages[page] = PlatformImage()
        }

        let first = Task {
            await vm.onPageChange(83, resolve: resolve, load: load,
                                  prefetch: { _ in prefetchOwners.append("first") })
        }
        await secondaryHTML.waitUntilStarted()
        await vm.onPageChange(83, resolve: resolve, load: load,
                              prefetch: { _ in prefetchOwners.append("duplicate") })
        await vm.waitForScheduledPrefetchInTests()
        #expect(vm.cachedImages[83] != nil && vm.cachedImages[84] == nil)
        #expect(prefetchOwners == ["duplicate"])

        await secondaryHTML.finish()
        await first.value
        await vm.waitForScheduledPrefetchInTests()
        #expect(vm.cachedImages[84] != nil)
        #expect(loadedSecondary == 1)
        #expect(prefetchOwners == ["duplicate"])
    }

    @Test func returningToSamePageDoesNotReviveOlderMaintenance() async {
        let vm = ReaderViewModel()
        vm.totalPages = 120
        vm.currentPage = 3
        let oldLoad = HeldReaderCacheLookup()
        var preloadAnchors: [Int] = []
        let old = Task {
            await vm.onPageChange(3, load: { _ in _ = await oldLoad.read() },
                                  prefetch: { preloadAnchors.append($0) })
        }
        await oldLoad.waitUntilStarted()
        vm.currentPage = 83
        vm.currentPage = 3
        // Re-selecting the same page already supersedes old work, even before the
        // new callback is scheduled on the actor.
        await oldLoad.finish()
        await old.value
        await vm.waitForScheduledPrefetchInTests()
        #expect(preloadAnchors.isEmpty)
        await vm.onPageChange(3, load: { _ in }, prefetch: { preloadAnchors.append($0) })
        await vm.waitForScheduledPrefetchInTests()
        #expect(preloadAnchors == [3])
    }
}
#endif

@MainActor
struct ReaderSharedMemorySpreadTests {
    private let first = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
    )!
    private let second = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYPgPAAEDAQAIicLsAAAAAElFTkSuQmCC"
    )!

    @Test func drawsWarmSharedPagesBeforeObservableRestoration() async throws {
        let vm = ReaderViewModel()
        vm.gid = 900010001051
        vm.spreads = [.init(id: 0, primaryPage: 0, secondaryPage: 1)]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let firstURL = folder.appendingPathComponent("1.png")
        let secondURL = folder.appendingPathComponent("2.png")
        try first.write(to: firstURL)
        try second.write(to: secondURL)
        vm.imageURLs[0] = firstURL.absoluteString
        vm.imageURLs[1] = secondURL.absoluteString
        await vm.loadDownloadedPage(0, from: firstURL, source: firstURL.absoluteString)
        let primary = try #require(vm.cachedImages[0])

        // Shared-memory primary, genuinely missing secondary: show just the first page.
        vm.cachedImages.removeAll()
        #expect(vm.image(at: 0) === primary)
        #expect(vm.image(at: 1) == nil)
        let fallback = vm.spreadPresentation(at: 0, direction: .leftToRight)
        #expect(fallback?.image === primary)
        #expect(fallback?.logicalSize == nil)

        await vm.loadDownloadedPage(1, from: secondURL, source: secondURL.absoluteString)
        let secondary = try #require(vm.cachedImages[1])
        vm.cachedImages.removeAll()
        #expect(vm.image(at: 0) === primary)
        #expect(vm.image(at: 1) === secondary)
        let composed = try #require(vm.spreadPresentation(at: 0, direction: .leftToRight))
        #expect(composed.image !== primary)
        #expect(composed.image !== secondary)
        #expect(vm.cachedImages.isEmpty)
        #if os(iOS)
        #expect(composed.logicalSize == CGSize(width: 2, height: 1))
        #expect(vm.spreadPresentation(at: 0, direction: .leftToRight)?.image === composed.image)
        #else
        #expect(composed.logicalSize == nil)
        #expect(composed.image.size == NSSize(width: 2, height: 1))
        #endif
    }

}
