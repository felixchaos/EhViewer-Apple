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

        static func restoredOnCancel(_ lastApplied: Field?) -> Field {
            lastApplied ?? .init(tokens: [], text: "")
        }

        /// A restored literal used to live before newly selected chips. Keep
        /// that order, but put a truly unsent trailing draft after the new tag,
        /// just as before the refill change.
        func queryPickingTag(_ tag: String, lastApplied: Field?) -> String? {
            guard !tag.isEmpty, !tokens.contains(tag) else { return nil }
            let applied = lastApplied?.text.trimmingCharacters(in: .whitespaces) ?? ""
            let literal = text.trimmingCharacters(in: .whitespaces)
            guard !applied.isEmpty, !literal.isEmpty else {
                return Field(tokens: tokens + [tag], text: text).submittedQuery
            }

            let tail = literal.hasPrefix(applied) ? literal.dropFirst(applied.count) : nil
            if let tail, tail.isEmpty || tail.first?.isWhitespace == true {
                guard !GallerySearchQuery.containsTerm(tag, in: applied) else { return nil }
                return Field(tokens: tokens + [applied, tag], text: String(tail)).submittedQuery
            }

            // An edited literal no longer has a reliable old draft boundary.
            // Preserve its exact order and append the explicit selection.
            guard !GallerySearchQuery.containsTerm(tag, in: literal) else { return nil }
            return Field(tokens: tokens + [literal, tag], text: "").submittedQuery
        }

        /// The suggestion replaces only the unfinished suffix, never an
        /// unchanged applied title. A fresh draft keeps the prior chip behavior.
        func queryPickingSuggestion(_ tag: String, lastApplied: Field?, unfinishedPrefix: String?) -> String? {
            guard !tag.isEmpty, !tokens.contains(tag) else { return nil }
            let applied = lastApplied?.text.trimmingCharacters(in: .whitespaces) ?? ""
            let literal = text.trimmingCharacters(in: .whitespaces)
            let retained: String
            if applied.isEmpty {
                retained = ""
            } else if literal == applied {
                retained = literal
            } else {
                retained = unfinishedPrefix?.trimmingCharacters(in: .whitespaces) ?? literal
            }

            guard !GallerySearchQuery.containsTerm(tag, in: retained) else { return nil }
            let terms = retained.isEmpty ? tokens + [tag] : tokens + [retained, tag]
            return Field(tokens: terms, text: "").submittedQuery
        }
    }

    private static func firstTerm(in text: Substring) -> (end: String.Index, complete: Bool) {
        var inQuotes = false
        var end = text.startIndex
        while end < text.endIndex {
            let character = text[end]
            if character.isWhitespace && !inQuotes { break }
            if character == "\"" { inQuotes.toggle() }
            text.formIndex(after: &end)
        }
        return (end, !inQuotes)
    }

    private static func containsTerm(_ tag: String, in query: String) -> Bool {
        var rest = query[...]
        while !rest.isEmpty {
            let (end, _) = firstTerm(in: rest)
            if rest[..<end] == tag { return true }
            rest = rest[end...].drop(while: \.isWhitespace)
        }
        return false
    }

    /// The editor's chips always precede its text. Promote only the leading
    /// recognized qualifiers and leave the suffix untouched. A token after
    /// plain text, an unfinished quote, or an unusual separator stays literal.
    static func restoredField(_ query: String, knownQualifiers: Set<String> = []) -> Field {
        var tokens: [String] = []
        var rest = query[...]
        while !rest.isEmpty {
            let (end, complete) = firstTerm(in: rest)
            let term = rest[..<end]
            guard complete, let colon = term.firstIndex(of: ":"),
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

/// Supported Quick Search options. A rating alone opens the advanced request
/// gate with a zero option mask: it must not turn on name, tag or page filters.
nonisolated struct GalleryBrowseSearch: Equatable, Hashable {
    let query: String
    let savedCategory: Int?
    let savedMinimumRating: Int?
    let explicitFilters: GalleryListRequest.Filters?

    static func validMinimumRating(_ value: Int?) -> Int? {
        guard let value, (2...5).contains(value) else { return nil }
        return value
    }

    var hasSavedFilters: Bool { savedCategory != nil || savedMinimumRating != nil || explicitFilters != nil }
    var showsResults: Bool { !query.isEmpty || explicitFilters?.supportsKeywordlessSearch == true }
    var clearingAppliedFilters: Self {
        // Clearing advanced options must not silently broaden a subscription search.
        if !query.isEmpty, initialFilters.mode == .subscription {
            return .init(query: query, applying: .subscriptionSearch)
        }
        return .init(query: query)
    }

    var initialFilters: GalleryListRequest.Filters {
        if let explicitFilters { return explicitFilters }
        return .init(category: savedCategory ?? 0, advanceSearch: savedMinimumRating == nil ? -1 : 0,
              minRating: savedMinimumRating ?? -1)
    }

    init(query: String, savedCategory: Int? = nil, savedMinimumRating: Int? = nil) {
        self.query = query
        explicitFilters = nil
        let all = EhCategory.all.rawValue
        if !query.isEmpty, let savedCategory, savedCategory > 0,
           savedCategory != all, (savedCategory & ~all) == 0 {
            self.savedCategory = savedCategory
        } else {
            self.savedCategory = nil
        }
        self.savedMinimumRating = query.isEmpty ? nil : Self.validMinimumRating(savedMinimumRating)
    }

    init(query: String, applying filters: GalleryListRequest.Filters) {
        self.query = ListUrlBuilder.sanitizeKeyword(query)
        savedCategory = nil
        savedMinimumRating = nil
        explicitFilters = filters.normalizedAdvancedSearch
    }

    /// Standalone list screens use the historical Quick Search URL encoding
    /// and category/legacy advanced gates. Only score validation is shared
    /// with the browse route; dormant bounds and flag bits are not activated.
    func standaloneURL(site: EhSite, storedCategory: Int, legacyAdvanced: Bool) -> String {
        let host = EhURL.host(for: site)
        guard var components = URLComponents(string: host) else { return host }
        var items = [URLQueryItem(name: "f_search", value: query)]
        if storedCategory > 0 {
            let excluded = EhCategory.all.rawValue ^ storedCategory
            items.append(URLQueryItem(name: "f_cats", value: String(excluded)))
        }
        if let savedMinimumRating {
            items.append(URLQueryItem(name: "f_srdd", value: String(savedMinimumRating)))
            items.append(URLQueryItem(name: "f_sr", value: "on"))
        }
        if legacyAdvanced || savedMinimumRating != nil {
            items.append(URLQueryItem(name: "advsearch", value: "1"))
        }
        components.queryItems = items
        return components.url?.absoluteString ?? host
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

    nonisolated struct Filters: Sendable, Hashable {
        var mode: ListUrlBuilder.Mode = .normal
        /// The existing cache used the settings search mode's raw value,
        /// which differs from the protocol mode (e.g. subscription: 1 vs 5).
        var cacheMode = 0
        var category = 0
        var advanceSearch = -1
        var minRating = -1
        var pageFrom = -1
        var pageTo = -1

        static let subscriptionSearch = Self(mode: .subscription, cacheMode: 1)

        var supportsKeywordlessSearch: Bool {
            if mode == .subscription { return true }
            guard mode == .normal else { return false }
            return category > 0 || (advanceSearch >= 0 &&
                (minRating >= 2 || pageFrom > 0 || pageTo > 0 || advanceSearch & ~0x003 != 0))
        }

        var normalizedAdvancedSearch: Self {
            var result = self
            let all = EhCategory.all.rawValue
            if category <= 0 || category == all || category & ~all != 0 { result.category = 0 }
            if advanceSearch < 0 {
                result.advanceSearch = -1
                result.minRating = -1
                result.pageFrom = -1
                result.pageTo = -1
            } else {
                result.minRating = GalleryBrowseSearch.validMinimumRating(minRating) ?? -1
                if pageFrom <= 0 { result.pageFrom = -1 }
                if pageTo <= 0 { result.pageTo = -1 }
            }
            return result
        }

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

extension GalleryListRequest.Source {
    /// The tag route's displayed seed isn't a free-text submission. Preserve
    /// its endpoint and identity until the user explicitly applies a query.
    nonisolated static func tagRoute(source: Self, submittedQuery: String?) -> Self {
        guard let submittedQuery else { return source }
        return submittedQuery.isEmpty ? .home : .search(keyword: submittedQuery)
    }
}
