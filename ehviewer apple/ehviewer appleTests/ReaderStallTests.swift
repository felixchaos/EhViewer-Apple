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
