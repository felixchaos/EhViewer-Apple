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
@testable import ehviewer_apple

@MainActor
struct GalleryFilterTests {

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
