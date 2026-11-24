import EhModels
import Foundation

/// Projection of the display order only; it never changes queue priority or persistence.
public struct DownloadListOrder: Equatable, Sendable {
    public enum Key: String, CaseIterable, Sendable {
        case queue, galleryID, created, rating, title, fileSize
    }

    public var key: Key = .queue
    public var ascending = true
    public init() {}

    public func apply(to tasks: [DownloadTask], measuredSizes: [Int64: Int64]) -> [DownloadTask] {
        guard key != .queue else { return tasks }
        return tasks.enumerated().sorted { lhs, rhs in
            let a = lhs.element, b = rhs.element
            let result: ComparisonResult
            switch key {
            case .queue: return lhs.offset < rhs.offset
            case .galleryID: result = compare(a.gallery.gid, b.gallery.gid)
            case .created: result = compare(a.createdAt, b.createdAt)
            case .rating:
                let r = a.gallery.rating, s = b.gallery.rating
                if r.isFinite != s.isFinite { return r.isFinite }
                result = r.isFinite ? compare(r, s) : .orderedSame
            case .title: result = a.gallery.bestTitle.localizedStandardCompare(b.gallery.bestTitle)
            case .fileSize:
                let sizeA = measuredSizes[a.gallery.gid], sizeB = measuredSizes[b.gallery.gid]
                switch (sizeA, sizeB) {
                case let (.some(x), .some(y)): result = compare(x, y)
                case (.some, .none): return true
                case (.none, .some): return false
                case (.none, .none): result = .orderedSame
                }
            }
            return result == .orderedSame ? lhs.offset < rhs.offset
                : result == (ascending ? .orderedAscending : .orderedDescending)
        }.map(\.element)
    }

    private func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        if a < b { return .orderedAscending }
        if a > b { return .orderedDescending }
        return .orderedSame
    }
}

public enum DownloadListCategory: Hashable, Sendable {
    case all, known(EhCategory), unknown

    public static let options: [Self] = [.all] + knownCategories.map(Self.known) + [.unknown]
    private static let knownCategories: [EhCategory] = [
        .misc, .doujinshi, .manga, .artistCG, .gameCG, .imageSet, .cosplay, .asianPorn, .nonH, .western
    ]

    public func includes(_ category: EhCategory) -> Bool {
        switch self {
        case .all: return true
        case .known(let expected): return category == expected
        case .unknown: return !Self.knownCategories.contains(category)
        }
    }
}
