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

    /// The existing token format splits only unquoted spaces; the quoted text
    /// and any initial namespace are retained verbatim.
    static func split(_ query: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for character in query {
            if character == "\"" {
                inQuotes.toggle()
                current.append(character)
            } else if character == " " && !inQuotes {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    static func exactTag(_ tag: String) -> String {
        guard let colon = tag.firstIndex(of: ":") else { return "\"\(tag)$\"" }
        let namespace = String(tag[tag.startIndex..<colon])
        let value = String(tag[tag.index(after: colon)...])
        guard !namespace.isEmpty, !value.isEmpty else { return "\"\(tag)$\"" }
        return "\(namespace):\"\(value)$\""
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
