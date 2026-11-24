import EhDatabase
import EhModels

/// Translate only explicitly versioned snapshots. Older records keep their historical global
/// query/category/rating behavior, regardless of the screen from which a user opens them.
nonisolated enum BrowseQuickSearchSnapshot {
    private static let storageVersion = 1

    nonisolated enum Replay {
        case legacy(GalleryBrowseSearch)
        case snapshot(GalleryBrowseSearch)
    }

    static func save(_ browse: GalleryBrowseSearch) -> QuickSearchRecord? {
        let filters = browse.initialFilters
        // Other Browse sources are not represented by a list-search snapshot.
        guard browse.showsResults, supports(filters.mode) else { return nil }
        var record = QuickSearchRecord(
            name: browse.query.isEmpty ? (filters.mode == .subscription ? "订阅筛选" : "画廊筛选") : nil,
            mode: filters.mode.rawValue,
            category: filters.category,
            keyword: browse.query
        )
        record.browseSnapshotVersion = storageVersion
        record.advanceSearch = filters.advanceSearch
        record.minRating = filters.minRating
        record.pageFrom = filters.pageFrom
        record.pageTo = filters.pageTo
        return record
    }

    static func replay(_ saved: QuickSearchRecord) -> Replay? {
        if let version = saved.browseSnapshotVersion {
            guard version == storageVersion,
                  let mode = ListUrlBuilder.Mode(rawValue: saved.mode), supports(mode) else { return nil }
            var filters: GalleryListRequest.Filters = mode == .subscription ? .subscriptionSearch : .init()
            filters.category = saved.category
            filters.advanceSearch = saved.advanceSearch
            filters.minRating = saved.minRating
            filters.pageFrom = saved.pageFrom
            filters.pageTo = saved.pageTo
            let browse = GalleryBrowseSearch(query: saved.keyword ?? "", applying: filters)
            return browse.showsResults ? .snapshot(browse) : nil
        }
        guard let keyword = saved.keyword, !keyword.isEmpty else { return nil }
        return .legacy(.init(query: keyword, savedCategory: saved.category, savedMinimumRating: saved.minRating))
    }

    static func scopeTitle(_ saved: QuickSearchRecord) -> String? {
        guard saved.browseSnapshotVersion == storageVersion else { return nil }
        switch ListUrlBuilder.Mode(rawValue: saved.mode) {
        case .normal: return "全站"
        case .subscription: return "订阅"
        default: return nil
        }
    }

    private static func supports(_ mode: ListUrlBuilder.Mode) -> Bool {
        mode == .normal || mode == .subscription
    }
}
