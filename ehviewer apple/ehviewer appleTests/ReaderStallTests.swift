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
