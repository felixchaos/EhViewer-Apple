//
//  GalleryFilterTests.swift
//  ehviewer appleTests
//
//  过滤规则此前**从来没有被应用过**：FilterView 能增删改查，记录也写进了
//  数据库，但整个项目没有任何地方读它们——「屏蔽这个标签」点完，被屏蔽的
//  画廊照常出现在列表里。这组测试守住两件事：规则能匹配对，以及匹配的
//  边界（命名空间）不能放宽或收紧。
//

import Testing
import EhModels
@testable import ehviewer_apple

@MainActor
struct GalleryFilterTests {

    @Test func listReplacementAndPaginationKeepFiltering() {
        let model = makeListModel()
        model.galleries = [GalleryInfo(gid: 1), GalleryInfo(gid: 2)]
        #expect(model.galleries.map(\.gid) == [1])
        #expect(model.filteredOutCount == 1)

        model.galleries.append(contentsOf: [GalleryInfo(gid: 3), GalleryInfo(gid: 4)])
        #expect(model.galleries.map(\.gid) == [1, 3])
        #expect(model.filteredOutCount == 1)
    }

    @Test func favoriteSubscriptWriteKeepsExistingVisibleList() {
        let model = makeListModel()
        model.galleries = [GalleryInfo(gid: 1), GalleryInfo(gid: 2), GalleryInfo(gid: 3)]
        model.galleries[0].favoriteSlot = 5
        #expect(model.galleries.map(\.gid) == [1, 3])
        #expect(model.galleries.map(\.favoriteSlot) == [5, -2])
        model.galleries[0].favoriteSlot = -1
        #expect(model.galleries.map(\.favoriteSlot) == [-1, -2])
    }

    @Test func repeatedEndTriggersDoNotIssueDuplicateRequestsOrAppendDuplicates() async {
        var callCount = 0
        let first = "https://example.invalid/?next=1"
        let second = "https://example.invalid/?next=2"
        let model = GalleryListViewModel(filterGalleries: { _ in 0 }, listRequest: { url in
            callCount += 1
            await Task.yield()
            if url == first {
                return GalleryListResult(galleries: [GalleryInfo(gid: 1), GalleryInfo(gid: 2), GalleryInfo(gid: 2)],
                                         pages: -1, nextHref: second)
            }
            #expect(url == second)
            return GalleryListResult(galleries: [GalleryInfo(gid: 2)], pages: -1, nextHref: first)
        })
        model.galleries = [GalleryInfo(gid: 1), GalleryInfo(gid: 1)]
        #expect(model.galleries.map(\.gid) == [1])
        model.hasMore = true
        model.nextHref = first
        for _ in 0..<2 {
            async let a: Void = model.loadMore(mode: .home)
            async let b: Void = model.loadMore(mode: .home)
            _ = await (a, b)
        }
        await model.loadMore(mode: .home)
        #expect(model.galleries.map(\.gid) == [1, 2])
        #expect(callCount == 2)
        #expect(!model.hasMore)
    }

    @Test func refreshingInvalidatesEarlierPaginationInEitherCompletionOrder() async throws {
        for oldFinishesFirst in [true, false] {
            typealias Continuation = CheckedContinuation<GalleryListResult, any Error>
            let next = "https://example.invalid/?next=old"
            var oldRequest: Continuation?
            var refresh: Continuation?
            let model = GalleryListViewModel(filterGalleries: { _ in 0 }, listRequest: { url in
                try await withCheckedThrowingContinuation { continuation in
                    if url == next { oldRequest = continuation }
                    else { refresh = continuation }
                }
            })
            defer {
                oldRequest?.resume(throwing: CancellationError())
                refresh?.resume(throwing: CancellationError())
            }
            model.galleries = [GalleryInfo(gid: 1)]
            model.hasMore = true
            model.nextHref = next
            let loadMore = Task { await model.loadMore(mode: .home) }
            for _ in 0..<100 where oldRequest == nil { try await Task.sleep(for: .milliseconds(1)) }
            let old = try #require(oldRequest)
            let replacement = Task { await model.refreshAsync(mode: .home) }
            for _ in 0..<100 where refresh == nil { try await Task.sleep(for: .milliseconds(1)) }
            let fresh = try #require(refresh)
            let oldResult = GalleryListResult(galleries: [GalleryInfo(gid: 2)], pages: -1,
                                              nextHref: "https://example.invalid/stale")
            let newResult = GalleryListResult(galleries: [GalleryInfo(gid: 3), GalleryInfo(gid: 3)], pages: -1,
                                              nextHref: "https://example.invalid/fresh")
            if oldFinishesFirst {
                oldRequest = nil
                old.resume(returning: oldResult)
                await loadMore.value
                #expect(model.galleries.map(\.gid) == [1])
                #expect(model.isLoading)
                refresh = nil
                fresh.resume(returning: newResult)
                await replacement.value
            } else {
                refresh = nil
                fresh.resume(returning: newResult)
                await replacement.value
                oldRequest = nil
                old.resume(returning: oldResult)
                await loadMore.value
            }
            #expect(model.galleries.map(\.gid) == [3])
            #expect(model.nextHref == "https://example.invalid/fresh")
            #expect(!model.isLoading)
        }
    }

    private func makeListModel() -> GalleryListViewModel {
        GalleryListViewModel(filterGalleries: { galleries in
            let count = galleries.count
            galleries.removeAll { $0.gid % 2 == 0 }
            return count - galleries.count
        })
    }

    // MARK: - 标签匹配（对齐 Android EhFilter.matchTag）

    /// 裸标签能挡住任何命名空间下的同名标签
    @Test func bareFilterMatchesNamespacedTag() {
        #expect(GalleryFilterEngine.tagMatches("female:big ass", "big ass"))
        #expect(GalleryFilterEngine.tagMatches("male:big ass", "big ass"))
    }

    /// 带命名空间的规则只挡同一命名空间
    @Test func namespacedFilterOnlyMatchesSameNamespace() {
        #expect(GalleryFilterEngine.tagMatches("female:big ass", "female:big ass"))
        #expect(!GalleryFilterEngine.tagMatches("male:big ass", "female:big ass"))
    }

    /// 标签名必须完全相等，不做子串匹配 —— 否则 `ass` 会顺手挡掉 `big ass`
    @Test func tagNameMustMatchExactly() {
        #expect(!GalleryFilterEngine.tagMatches("female:big ass", "ass"))
        #expect(!GalleryFilterEngine.tagMatches("female:bigass", "big ass"))
    }

    /// 裸标签对裸标签
    @Test func bareToBare() {
        #expect(GalleryFilterEngine.tagMatches("translated", "translated"))
        #expect(!GalleryFilterEngine.tagMatches("translated", "translate"))
    }
}
