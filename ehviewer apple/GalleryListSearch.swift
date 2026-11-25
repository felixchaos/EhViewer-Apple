import Foundation
import EhModels
import EhSettings
import EhDownload

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

    fileprivate static func firstTerm(in text: Substring) -> (end: String.Index, complete: Bool) {
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

    fileprivate static func containsTerm(_ tag: String, in query: String) -> Bool {
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
    let scopedFavorite: Bool

    init(source: Source, filters: Filters = .init(), favoriteKeyword: String? = nil, scopedFavorite: Bool = false) {
        self.source = source
        self.filters = filters
        self.favoriteKeyword = favoriteKeyword
        self.scopedFavorite = scopedFavorite
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
            if scopedFavorite { return buildFavoritesURL(slot: slot, parameter: "", site: site) }
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
        case .favorites(let slot): return "fav:\(slot):\(favoriteKeyword ?? ""):\(page):\(scopedFavorite)"
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
        if scopedFavorite, var components = URLComponents(string: baseURL) {
            var items = slot < 0 ? [] : [URLQueryItem(name: "favcat", value: String(slot))]
            if let equals = parameter.firstIndex(of: "=") {
                items.append(URLQueryItem(name: String(parameter[..<equals]),
                                          value: String(parameter[parameter.index(after: equals)...])))
            }
            if let favoriteKeyword, !favoriteKeyword.isEmpty {
                items.append(URLQueryItem(name: "f_search", value: favoriteKeyword))
                items += ["sn", "st", "sf"].map { URLQueryItem(name: $0, value: "on") }
            }
            components.queryItems = items
            // Favorite endpoints decode '+' as a space even when it is literal.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            return components.url?.absoluteString ?? baseURL
        }
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

// MARK: - In-app tag workspaces

/// A frozen source for a new workspace. Browsing state is private to the new
/// shell, while actual downloads, favorites and history continue to share data.
nonisolated struct TagWorkspaceOrigin: Hashable {
    nonisolated enum Scope: Hashable {
        case browse
        case watched
        case cloudFavorites(Int)
        case localFavorites
        case allFavorites
        case history
        case downloads
        case loadedPopular
        case loadedToplist

        var title: String {
            switch self {
            case .browse: "浏览"
            case .watched: "订阅"
            case .cloudFavorites(let slot): slot < 0 ? "云端收藏" : "收藏夹 \(slot + 1)"
            case .localFavorites: "本地收藏"
            case .allFavorites: "全部收藏"
            case .history: "阅读历史"
            case .downloads: "下载"
            case .loadedPopular: "已加载的热门"
            case .loadedToplist: "已加载的排行"
            }
        }
    }

    nonisolated struct DownloadControls: Hashable {
        let label: String?
        let status: String
        let category: DownloadListCategory
        let order: String
        let ascending: Bool
    }

    let scope: Scope
    var query = ""
    var filters = GalleryListRequest.Filters()
    var candidates: [GalleryInfo] = []
    var downloadControls: DownloadControls? = nil
    var toplistPeriod: Int? = nil

    static let browse = Self(scope: .browse)

    func withGallery(_ gallery: GalleryInfo, tagGroups: [GalleryTagGroup]) -> Self {
        guard !tagGroups.isEmpty, let index = candidates.firstIndex(where: { $0.gid == gallery.gid })
        else { return self }
        var updated = self
        updated.candidates[index].simpleTags = tagGroups.flatMap { group in
            group.tags.map { "\(group.groupName):\($0)" }
        }
        return updated
    }

    func selecting(_ tag: String) -> TagWorkspaceRoute {
        .init(origin: self, tags: [tag])
    }

    var cloudSlot: Int? {
        switch scope {
        case .cloudFavorites(let slot): slot
        case .allFavorites: -1
        default: nil
        }
    }

    var isLocal: Bool {
        switch scope {
        case .browse, .watched, .cloudFavorites, .allFavorites: false
        default: true
        }
    }
}

nonisolated struct TagWorkspaceRoute: Hashable {
    let origin: TagWorkspaceOrigin
    let tags: [String]

    var title: String { origin.scope.title }

    /// Additional terms are editable within this layer. Its inherited terms,
    /// scope and clicked tags cannot be removed by clearing the editor.
    func query(adding extra: String = "") -> String {
        var result = ListUrlBuilder.sanitizeKeyword(origin.query + " " + extra)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for tag in tags {
            let exact = GallerySearchQuery.exactTag(tag)
            if !GallerySearchQuery.containsTerm(exact, in: result) {
                result = result.isEmpty ? exact : result + " " + exact
            }
        }
        return result
    }

    func descending(into tag: String, extra: String, filters: GalleryListRequest.Filters) -> Self {
        var source = origin
        source.query = query(adding: extra)
        if origin.isLocal || origin.scope == .allFavorites {
            source.candidates = localList(extra: extra, filters: filters).galleries
        }
        source.filters = filters
        return .init(origin: source, tags: tags.contains(tag) ? tags : tags + [tag])
    }

    func retargeted(to scope: TagWorkspaceOrigin.Scope, candidates: [GalleryInfo] = []) -> Self {
        .init(origin: .init(scope: scope, query: origin.query, filters: origin.filters, candidates: candidates,
                            downloadControls: origin.downloadControls, toplistPeriod: origin.toplistPeriod),
              tags: tags)
    }

    func request(extra: String, filters: GalleryListRequest.Filters) -> GalleryListRequest {
        let keyword = query(adding: extra)
        var filters = filters
        if let slot = origin.cloudSlot {
            return .init(source: .favorites(slot: slot), favoriteKeyword: keyword, scopedFavorite: true)
        }
        if origin.scope == .watched {
            filters.mode = .subscription
            filters.cacheMode = 1
        }
        if origin.scope == .browse, tags.count == 1, origin.query.isEmpty, extra.isEmpty,
           filters == .init(), let tag = tags.first {
            // Preserve the established canonical endpoint for an unconstrained
            // first drill-down; any inherited/additional option uses f_search.
            return .init(source: .tag(keyword: tag))
        }
        return .init(source: .search(keyword: keyword), filters: filters)
    }

    /// A server cursor is pagination data, not permission to drop the source
    /// or query. Reattach only navigation parameters to the pinned request.
    func preservingScope(of url: String, extra: String, filters: GalleryListRequest.Filters, site: EhSite) -> String {
        let descriptor = request(extra: extra, filters: filters)
        let pinned = descriptor.pageURL(0, site: site)
        guard var target = URLComponents(string: pinned),
              let supplied = URLComponents(string: url) else { return pinned }
        if case .tag = descriptor.source,
           supplied.path.hasPrefix(target.path + "/"),
           let page = Int(supplied.path.dropFirst(target.path.count + 1)), page > 0 {
            target.path += "/\(page)"
        }
        let names = Set(["page", "next", "prev", "seek", "jump"])
        let nav = supplied.queryItems?.filter { names.contains($0.name) } ?? []
        var items = (target.queryItems ?? []).filter { existing in
            !nav.contains { $0.name == existing.name }
                && !(existing.name == "page" && nav.contains { $0.name != "page" })
        }
        items += nav
        if !items.isEmpty { target.queryItems = items }
        target.percentEncodedQuery = target.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return target.url?.absoluteString ?? pinned
    }

    func localList(extra: String, filters: GalleryListRequest.Filters) -> GalleryListResult {
        let extraTerms = Self.terms(in: origin.query + " " + extra)
        let results = origin.candidates.filter { gallery in
            let rawTags = gallery.simpleTags ?? []
            let canonicalTags = Set(rawTags.map(Self.canonicalTag))
            guard tags.allSatisfy({ canonicalTags.contains(Self.canonicalTag($0)) }) else { return false }
            if filters.category > 0, filters.category & gallery.category.rawValue == 0 { return false }
            if filters.minRating >= 2, gallery.rating < Float(filters.minRating) { return false }
            if filters.pageFrom > 0, gallery.pages < filters.pageFrom { return false }
            if filters.pageTo > 0, gallery.pages > filters.pageTo { return false }
            let names = [gallery.title, gallery.titleJpn, gallery.uploader].compactMap { $0 }
            return extraTerms.allSatisfy { word in
                let unquoted = word.replacingOccurrences(of: "\"", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "$"))
                if unquoted.contains(":") { return canonicalTags.contains(Self.canonicalTag(unquoted)) }
                return (names + rawTags).contains { $0.localizedCaseInsensitiveContains(unquoted) }
            }
        }
        return GalleryListResult(galleries: results)
    }

    private static func terms(in query: String) -> [String] {
        var terms: [String] = []
        var tail = query[...].drop(while: \.isWhitespace)
        while !tail.isEmpty {
            let (end, _) = GallerySearchQuery.firstTerm(in: tail)
            terms.append(String(tail[..<end]))
            tail = tail[end...].drop(while: \.isWhitespace)
        }
        return terms
    }

    private static func canonicalTag(_ tag: String) -> String {
        let lower = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let split = lower.firstIndex(of: ":") else { return lower }
        let prefix = String(lower[...split])
        let value = lower[lower.index(after: split)...]
        return "\(EhTagDatabase.prefixToNamespace[prefix] ?? String(prefix.dropLast())):\(value)"
    }
}
