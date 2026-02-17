import Foundation
import EhModels

// MARK: - EhFilterManager (对应 Android EhFilter.java 运行时过滤逻辑)
// 使用 EhFilter 条目列表对画廊进行过滤

@MainActor @Observable
public final class EhFilterManager: @unchecked Sendable {
    public static let shared = EhFilterManager()

    /// 过滤器列表 (从数据库加载)
    public var filters: [EhFilter] = []

    private init() {}

    // MARK: - 过滤器管理

    public func addFilter(_ filter: EhFilter) {
        filters.append(filter)
    }

    public func removeFilter(at index: Int) {
        guard filters.indices.contains(index) else { return }
        filters.remove(at: index)
    }

    public func toggleFilter(at index: Int) {
        guard filters.indices.contains(index) else { return }
        filters[index].isEnabled.toggle()
    }

    // MARK: - 过滤执行 (对应 Android EhFilter.filterTitle/Uploader/Tag/TagNamespace/Commenter/Comment)

    /// 检查画廊是否应被过滤 (返回 true = 需要隐藏)
    public func shouldFilter(_ gallery: GalleryInfo) -> Bool {
        let enabledFilters = filters.filter(\.isEnabled)
        guard !enabledFilters.isEmpty else { return false }

        for filter in enabledFilters {
            switch filter.mode {
            case .title:
                if filterTitle(gallery, pattern: filter.text) { return true }
            case .uploader:
                if filterUploader(gallery, name: filter.text) { return true }
            case .tag:
                if filterTag(gallery, tag: filter.text) { return true }
            case .tagNamespace:
                if filterTagNamespace(gallery, namespace: filter.text) { return true }
            case .commenter:
                // 评论者过滤在画廊列表层面无法执行，需要在详情页过滤
                break
            case .comment:
                // 评论内容过滤同上
                break
            }
        }
        return false
    }

    /// 过滤列表 (移除被过滤的画廊)
    public func filterGalleries(_ galleries: [GalleryInfo]) -> [GalleryInfo] {
        let enabledFilters = filters.filter(\.isEnabled)
        guard !enabledFilters.isEmpty else { return galleries }
        return galleries.filter { !shouldFilter($0) }
    }

    // MARK: - 各模式匹配

    /// 标题过滤 (对应 Android filterTitle — 正则匹配)
    private func filterTitle(_ gallery: GalleryInfo, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            // 如果不是合法正则，降级为包含匹配
            let lower = pattern.lowercased()
            return gallery.title?.lowercased().contains(lower) == true
                || gallery.titleJpn?.lowercased().contains(lower) == true
        }

        if let title = gallery.title {
            let range = NSRange(title.startIndex..., in: title)
            if regex.firstMatch(in: title, range: range) != nil { return true }
        }
        if let titleJpn = gallery.titleJpn {
            let range = NSRange(titleJpn.startIndex..., in: titleJpn)
            if regex.firstMatch(in: titleJpn, range: range) != nil { return true }
        }
        return false
    }

    /// 上传者过滤 (对应 Android filterUploader — 精确匹配)
    private func filterUploader(_ gallery: GalleryInfo, name: String) -> Bool {
        gallery.uploader?.caseInsensitiveCompare(name) == .orderedSame
    }

    /// 标签过滤 (对应 Android filterTag — 包含匹配)
    private func filterTag(_ gallery: GalleryInfo, tag: String) -> Bool {
        guard let tags = gallery.simpleTags else { return false }
        let lower = tag.lowercased()
        return tags.contains(where: { $0.lowercased() == lower })
    }

    /// 命名空间过滤 (对应 Android filterTagNamespace — 前缀匹配)
    private func filterTagNamespace(_ gallery: GalleryInfo, namespace: String) -> Bool {
        guard let tags = gallery.simpleTags else { return false }
        let prefix = namespace.lowercased() + ":"
        return tags.contains(where: { $0.lowercased().hasPrefix(prefix) })
    }
}
