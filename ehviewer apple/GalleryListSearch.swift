import Foundation
import EhModels

/// Query syntax shared by browsing interfaces. Focus, token appearance and the
/// decision to submit stay with the caller.
nonisolated enum GallerySearchQuery {
    static func fieldQuery(tokens: [String], text: String) -> String {
        let typed = text.trimmingCharacters(in: .whitespaces)
        return (tokens + (typed.isEmpty ? [] : [typed])).joined(separator: " ")
    }

    static func tokensAfterSubmitting(_ tokens: [String], text: String) -> [String] {
        let typed = text.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty, !tokens.contains(typed) else { return tokens }
        return tokens + [typed]
    }

    nonisolated struct Field: Equatable {
        let tokens: [String]
        let text: String

        var submittedQuery: String {
            GallerySearchQuery.tokensAfterSubmitting(tokens, text: text).joined(separator: " ")
        }
    }

    /// The editor's chips always precede its text. Promote only the leading
    /// recognized qualifiers and leave the suffix untouched. A token after
    /// plain text, an unfinished quote, or an unusual separator stays literal.
    static func restoredField(_ query: String, knownQualifiers: Set<String> = []) -> Field {
        var tokens: [String] = []
        var rest = query[...]
        while !rest.isEmpty {
            var inQuotes = false
            var end = rest.startIndex
            while end < rest.endIndex {
                let character = rest[end]
                if character.isWhitespace && !inQuotes { break }
                if character == "\"" { inQuotes.toggle() }
                rest.formIndex(after: &end)
            }
            let term = rest[..<end]
            guard !inQuotes, let colon = term.firstIndex(of: ":"),
                  knownQualifiers.contains(term[..<colon].lowercased()),
                  term.index(after: colon) < term.endIndex else { break }
            if end == rest.endIndex {
                tokens.append(String(term))
                rest = rest[end...]
                break
            }
            let next = rest.index(after: end)
            guard rest[end] == " ", next < rest.endIndex, !rest[next].isWhitespace else { break }
            tokens.append(String(term))
            rest = rest[next...]
        }
        return Field(tokens: tokens, text: String(rest))
    }

    static func exactTag(_ tag: String) -> String {
        guard let colon = tag.firstIndex(of: ":") else { return "\"\(tag)$\"" }
        let namespace = String(tag[tag.startIndex..<colon])
        let value = String(tag[tag.index(after: colon)...])
        guard !namespace.isEmpty, !value.isEmpty else { return "\"\(tag)$\"" }
        return "\(namespace):\"\(value)$\""
    }
}

/// Category is the only non-default filter written by the current Quick Search
/// editor. A missing, invalid, or all-selected mask keeps the original request.
nonisolated struct GalleryBrowseSearch: Equatable, Hashable {
    let query: String
    let savedCategory: Int?

    var initialFilters: GalleryListRequest.Filters {
        .init(category: savedCategory ?? 0)
    }

    init(query: String, savedCategory: Int? = nil) {
        self.query = query
        let all = EhCategory.all.rawValue
        if !query.isEmpty, let savedCategory, savedCategory > 0,
           savedCategory != all, (savedCategory & ~all) == 0 {
            self.savedCategory = savedCategory
        } else {
            self.savedCategory = nil
        }
    }
}

/// Immutable description of a list's source and applied filters. It has no UI,
/// global settings, network or cache dependency: a browsing session supplies
/// the site and uses the same description to request and cache its response.
nonisolated struct GalleryListRequest: Sendable {
    nonisolated enum Source: Sendable {
        case home
        case subscription
        case popular
        case toplist(period: Int)
        case search(keyword: String)
        case tag(keyword: String)
        case favorites(slot: Int)
    }

    nonisolated struct Filters: Sendable {
        var mode: ListUrlBuilder.Mode = .normal
        /// The existing cache used the settings search mode's raw value,
        /// which differs from the protocol mode (e.g. subscription: 1 vs 5).
        var cacheMode = 0
        var category = 0
        var advanceSearch = -1
        var minRating = -1
        var pageFrom = -1
        var pageTo = -1

        fileprivate var cacheSignature: String {
            "\(cacheMode)|\(category)|\(advanceSearch)|\(minRating)|\(pageFrom)-\(pageTo)"
        }
    }

    let source: Source
    let filters: Filters
    let favoriteKeyword: String?

    init(source: Source, filters: Filters = .init(), favoriteKeyword: String? = nil) {
        self.source = source
        self.filters = filters
        self.favoriteKeyword = favoriteKeyword
    }

    func pageURL(_ page: Int, site: EhSite) -> String {
        switch source {
        case .home:
            return buildListURL(mode: filters.mode, page: page, site: site)
        case .subscription:
            return buildListURL(mode: .subscription, page: page, site: site)
        case .popular:
            return EhURL.popularUrl(for: site)
        case .toplist(let period):
            return EhURL.topListUrl(period: period, page: page)
        case .search(let keyword):
            return buildListURL(mode: filters.mode, keyword: keyword, page: page, site: site)
        case .tag(let keyword):
            let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? keyword
            let baseURL = "\(EhURL.host(for: site))tag/\(encoded)"
            return page > 0 ? "\(baseURL)/\(page)" : baseURL
        case .favorites(let slot):
            return buildFavoritesURL(slot: slot, parameter: "page=\(page)", site: site)
        }
    }

    func jumpBaseURL(site: EhSite) -> String {
        if case .favorites(let slot) = source {
            // Existing jumps without a server cursor omit the favorites search.
            let baseURL = EhURL.favoritesUrl(for: site)
            return slot < 0 ? baseURL : "\(baseURL)?favcat=\(slot)"
        }
        return pageURL(0, site: site)
    }

    func dateSeekBaseURL(site: EhSite) -> String? {
        switch source {
        case .home, .search, .tag: return pageURL(0, site: site)
        default: return nil
        }
    }

    func favoritesDateURL(day: String, site: EhSite) -> String? {
        guard case let .favorites(slot) = source else { return nil }
        return buildFavoritesURL(slot: slot, parameter: "seek=\(day)", site: site)
    }

    func cacheKey(page: Int) -> String {
        switch source {
        case .home: return "home:\(filters.cacheSignature):\(page)"
        case .subscription: return "watched:\(filters.cacheSignature):\(page)"
        case .popular: return "popular:\(page)"
        case .toplist(let period): return "toplist:\(period):\(page)"
        case .search(let keyword): return "search:\(keyword):\(filters.cacheSignature):\(page)"
        case .tag(let keyword): return "tag:\(keyword):\(page)"
        case .favorites(let slot): return "fav:\(slot):\(favoriteKeyword ?? ""):\(page)"
        }
    }

    private func buildListURL(
        mode: ListUrlBuilder.Mode, keyword: String? = nil, page: Int, site: EhSite
    ) -> String {
        var builder = ListUrlBuilder()
        builder.mode = mode
        builder.keyword = keyword
        builder.pageIndex = page
        builder.category = filters.category
        builder.advanceSearch = filters.advanceSearch
        builder.minRating = filters.minRating
        builder.pageFrom = filters.pageFrom
        builder.pageTo = filters.pageTo
        return builder.build(site: site)
    }

    private func buildFavoritesURL(slot: Int, parameter: String, site: EhSite) -> String {
        let baseURL = EhURL.favoritesUrl(for: site)
        var url = slot < 0 ? "\(baseURL)?\(parameter)" : "\(baseURL)?favcat=\(slot)&\(parameter)"
        if let keyword = favoriteKeyword, !keyword.isEmpty {
            let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
            url += "&f_search=\(encoded)"
        }
        return url
    }
}
