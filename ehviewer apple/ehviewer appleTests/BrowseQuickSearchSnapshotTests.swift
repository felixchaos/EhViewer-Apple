import Foundation
import Testing
import EhDatabase
import EhModels
@testable import ehviewer_apple

struct BrowseQuickSearchSnapshotTests {
    @Test func watchedPresetReplaysAppliedFiltersAtFirstPage() throws {
        let original = GalleryBrowseSearch(query: "neutral fixture", applying: .init(
            mode: .subscription, cacheMode: 1, category: EhCategory.manga.rawValue,
            advanceSearch: 0x104, minRating: 4, pageFrom: 20, pageTo: 60
        ))
        let record = try #require(BrowseQuickSearchSnapshot.save(original))
        guard case .snapshot(let restored)? = BrowseQuickSearchSnapshot.replay(record) else {
            Issue.record("Expected a versioned Browse snapshot")
            return
        }
        #expect(restored == original)
        let request = GalleryListRequest(source: .search(keyword: restored.query), filters: restored.initialFilters)
        let url = try #require(URLComponents(string: request.pageURL(0, site: .eHentai)))
        let parameters = Dictionary(uniqueKeysWithValues: (url.queryItems ?? []).map { ($0.name, $0.value) })
        #expect(url.path == "/watched")
        #expect(parameters["f_search"] == "neutral fixture")
        #expect(parameters["f_cats"] == String((~EhCategory.manga.rawValue) & EhCategory.all.rawValue))
        #expect(parameters["f_sdesc"] == "on")
        #expect(parameters["f_sfl"] == "on")
        #expect(parameters["f_sr"] == "on")
        #expect(parameters["f_srdd"] == "4")
        #expect(parameters["f_sp"] == "on")
        #expect(parameters["f_spf"] == "20")
        #expect(parameters["f_spt"] == "60")
        #expect(parameters["page"] == nil)
        let next = try #require(URLComponents(string: request.pageURL(1, site: .eHentai)))
        #expect(next.path == url.path)
        #expect(next.queryItems?.contains(.init(name: "page", value: "1")) == true)
    }

    @Test func legacyGlobalPresetIgnoresDormantScopeAndPageBounds() throws {
        var record = QuickSearchRecord(mode: ListUrlBuilder.Mode.subscription.rawValue,
                                       category: EhCategory.manga.rawValue, keyword: "legacy fixture")
        record.minRating = 3
        record.advanceSearch = 0x104
        record.pageFrom = 25
        record.pageTo = 90
        guard case .legacy(let restored)? = BrowseQuickSearchSnapshot.replay(record) else {
            Issue.record("Expected legacy preset")
            return
        }
        #expect(restored.initialFilters.mode == .normal)
        #expect(restored.initialFilters.category == EhCategory.manga.rawValue)
        #expect(restored.initialFilters.minRating == 3)
        #expect(restored.initialFilters.pageFrom == -1)
        #expect(restored.initialFilters.pageTo == -1)
        #expect(restored.initialFilters.advanceSearch == 0)
        record.keyword = ""
        #expect(BrowseQuickSearchSnapshot.replay(record) == nil)
    }

    @Test func explicitKeywordlessSnapshotIsDistinctFromBlankLegacyOrFutureVersion() throws {
        let filtered = GalleryBrowseSearch(query: "", applying: .init(category: EhCategory.manga.rawValue))
        let record = try #require(BrowseQuickSearchSnapshot.save(filtered))
        guard case .snapshot(let restored)? = BrowseQuickSearchSnapshot.replay(record) else {
            Issue.record("Expected an explicit filter-only preset")
            return
        }
        #expect(restored == filtered)
        var other = record
        other.browseSnapshotVersion = 99
        #expect(BrowseQuickSearchSnapshot.replay(other) == nil)
        #expect(BrowseQuickSearchSnapshot.save(.init(query: "")) == nil)
        #expect(BrowseQuickSearchSnapshot.save(.init(query: "not a supported scope",
                                                     applying: .init(mode: .uploader))) == nil)
    }
}
