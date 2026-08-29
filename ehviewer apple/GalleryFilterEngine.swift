//
//  GalleryFilterEngine.swift
//  ehviewer apple
//
//  画廊过滤（对齐 Android EhFilter）
//
//  ⚠️ 这套规则此前**从来没有被应用过**：FilterView 能增删改查，记录也确实写进了
//  数据库，但整个项目里没有任何地方读它们——所以「屏蔽这个标签」点完之后，
//  被屏蔽的画廊照常出现在列表里。这个文件就是缺掉的那一半。
//
//  匹配语义逐条对齐 Android EhFilter：
//    标题     filter 文本（小写）是标题（小写）的子串
//    上传者   完全相等
//    标签     命名空间两边都有时必须相同；标签名必须完全相等
//    命名空间 标签的命名空间与 filter 完全相等
//    语言     画廊的 simpleLanguage 与 filter 相等（Android 无此项，是本端扩展）
//

import Foundation
import EhModels
import EhDatabase

@Observable
@MainActor
final class GalleryFilterEngine {
    static let shared = GalleryFilterEngine()

    private(set) var filters: [FilterRecord] = []

    private init() {
        reload()
        NotificationCenter.default.addObserver(
            forName: .galleryFiltersChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func reload() {
        filters = ((try? EhDatabase.shared.getAllFilters()) ?? []).filter(\.enable)
    }

    /// 这一本要不要挡掉
    func shouldHide(_ gallery: GalleryInfo) -> Bool {
        guard !filters.isEmpty else { return false }
        for filter in filters where matches(filter, gallery) { return true }
        return false
    }

    /// 挡掉列表里命中过滤规则的条目，返回被挡掉的数量
    @discardableResult
    func apply(to galleries: inout [GalleryInfo]) -> Int {
        guard !filters.isEmpty else { return 0 }
        let before = galleries.count
        galleries.removeAll { shouldHide($0) }
        return before - galleries.count
    }

    /// 命中这条规则的原因（用于告诉用户「为什么这本被挡了」）
    func matchReason(for gallery: GalleryInfo) -> FilterRecord? {
        filters.first { matches($0, gallery) }
    }

    private func matches(_ filter: FilterRecord, _ gallery: GalleryInfo) -> Bool {
        let text = filter.text?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        guard !text.isEmpty else { return false }

        switch filter.mode {
        case 0:
            return (gallery.title ?? "").lowercased().contains(text)
                || (gallery.titleJpn ?? "").lowercased().contains(text)
        case 1:
            return (gallery.uploader ?? "").lowercased() == text
        case 2:
            return (gallery.simpleTags ?? []).contains { Self.tagMatches($0.lowercased(), text) }
        case 3:
            return (gallery.simpleTags ?? []).contains { tag in
                guard let colon = tag.firstIndex(of: ":") else { return false }
                return tag[tag.startIndex..<colon].lowercased() == text
            }
        case 4:
            // 上传者标签：Android 用它挡「某上传者的某标签」，这里退化成上传者匹配
            return (gallery.uploader ?? "").lowercased() == text
        case 5:
            return (gallery.simpleLanguage ?? "").lowercased() == text
        default:
            return false
        }
    }

    /// 对齐 Android matchTag：命名空间两边都有时必须相同，标签名必须完全相等。
    /// 所以 `big ass` 能挡住 `female:big ass`，而 `female:big ass` 挡不住
    /// `male:big ass`。
    static func tagMatches(_ tag: String, _ filter: String) -> Bool {
        let (tagNS, tagName) = split(tag)
        let (filterNS, filterName) = split(filter)
        if let tagNS, let filterNS, tagNS != filterNS { return false }
        return tagName == filterName
    }

    private static func split(_ s: String) -> (String?, String) {
        guard let colon = s.firstIndex(of: ":") else { return (nil, s) }
        return (String(s[s.startIndex..<colon]), String(s[s.index(after: colon)...]))
    }
}

extension Notification.Name {
    /// 过滤规则增删改后发出，引擎据此重新加载
    static let galleryFiltersChanged = Notification.Name("galleryFiltersChanged")
}
