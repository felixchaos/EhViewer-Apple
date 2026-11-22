import Foundation
import Testing
@testable import EhParser

@Suite("Offline parser regression")
struct ParserRegressionTests {
    private func fixture(_ name: String, _ ext: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func html(_ name: String) throws -> String {
        try #require(String(data: fixture(name, "html"), encoding: .utf8))
    }

    @Test func compactListKeepsMetadataAndCompletePagingLinks() throws {
        let list = try GalleryListParser.parse(html("gallery-list"))

        #expect(list.pages == 3)
        #expect(list.nextPage == 3)
        #expect(list.prevHref == "/?f_search=night+garden&page=1")
        #expect(list.nextHref == "/?f_search=night+garden&page=3&next=17000000")
        #expect(list.galleries.map(\.gid) == [101, 102])
        #expect(list.galleries.map(\.pages) == [12, 1])

        let row = try #require(list.galleries.first)
        #expect(row.token == "a1b2")
        #expect(row.title == "Night Garden & Lanterns")
        #expect(row.thumb == "https://fixture.invalid/cover.webp")
        #expect(row.thumbHeight == 120)
        #expect(row.thumbWidth == 80)
        #expect(row.rating == 3.5)
        #expect(row.rated)
        #expect(row.uploader == "Test Uploader")
        #expect(row.favoriteSlot == 2)
        #expect(row.simpleTags == ["language:english"])
    }

    @Test func favoritesKeepCloudCategoryAndCursorWhileParsingThumbnails() throws {
        let favorites = try FavoritesParser.parse(html("favorites"))

        #expect(favorites.currentCat == 1)
        #expect(Array(favorites.catArray.prefix(2)) == ["Botany & Field Notes", "City Walks"])
        #expect(Array(favorites.countArray.prefix(2)) == [2, 3])
        #expect(favorites.catArray.count == 10)
        #expect(favorites.galleryListResult.prevHref == nil)
        #expect(favorites.galleryListResult.nextHref == "/favorites.php?favcat=1&next=42")
        #expect(favorites.galleryListResult.resultCount == "3")

        let row = try #require(favorites.galleryListResult.galleries.first)
        #expect(row.gid == 201)
        #expect(row.title == "City Lights")
        #expect(row.thumb == "https://fixture.invalid/city.webp")
    }

    @Test func expectedEmptyListHasNoPaging() throws {
        let empty = try GalleryListParser.parse("<p>No hits found</p>")
        #expect(empty.galleries.isEmpty)
        #expect(empty.nextHref == nil)
        #expect(empty.prevHref == nil)
    }

    @Test func topListSeparatesTimePeriodsAndRejectsMissingPageMarkup() throws {
        let report = try GalleryListParser.parseTopList("""
            <div class="ido"><h2>Gallery</h2><section>
              <h3>Rankings</h3>
              <div><table><tr><td class="tun"><a href="/g/401/da12/">Lantern Sketchbook</a></td></tr></table></div>
              <div><span class="tun"><a href="/g/402/ea12/">Moss Journal</a></span></div>
              <div></div>
              <div><span class="tun"><a href="/g/403/fa12/">Trail Maps</a></span></div>
            </section></div>
            """)
        let gallery = try #require(report.lists.first)
        #expect(gallery.name == "Gallery")
        #expect(gallery.allTime.map(\.text) == ["Lantern Sketchbook"])
        #expect(gallery.allTime.first?.href == "/g/401/da12/")
        #expect(gallery.pastYear.map(\.text) == ["Moss Journal"])
        #expect(gallery.pastMonth.isEmpty)
        #expect(gallery.yesterday.map(\.text) == ["Trail Maps"])

        let malformed = "<html><title>Unexpected response</title></html>"
        #expect {
            try GalleryListParser.parseTopList(malformed)
        } throws: { error in
            let parserError = error as NSError
            return parserError.domain == "GalleryListParser" && parserError.code == -1
        }
    }

    @Test func detailRetainsCanonicalIdentityAndFavoriteDisplayState() throws {
        let source = try html("detail")
        let detail = try GalleryDetailParser.parse(source)
        #expect(detail.info.gid == 301)
        #expect(detail.info.token == "cafe12")
        #expect(detail.info.title == "Botany Notebook & Sketches")
        #expect(detail.info.titleJpn == "植物の記録")
        #expect(detail.info.pages == 12)
        #expect(detail.spiderInfoPages == 12)
        #expect(detail.info.rating == 4.25)
        #expect(detail.ratingCount == 9)
        #expect(detail.isFavorited)
        #expect(detail.info.favoriteName == "Botany & Field Notes")
        #expect(detail.favoriteCount == 4)
        #expect(detail.tags.map(\.groupName) == ["language"])
        #expect(detail.tags.first?.tags == ["english"])

        let unfavorited = try GalleryDetailParser.parse(
            source.replacingOccurrences(of: "Botany &amp; Field Notes", with: "Add to Favorites")
        )
        #expect(!unfavorited.isFavorited)
        #expect(unfavorited.info.favoriteName == nil)
        #expect(unfavorited.info.favoriteSlot == -1)
    }

    @Test func detailRecognizesUnavailableAndServerErrorSeparately() {
        #expect {
            try GalleryDetailParser.parse("<p>This gallery is unavailable</p>")
        } throws: { error in
            guard case .galleryUnavailable? = error as? GalleryDetailParser.DetailParseError else { return false }
            return true
        }
        #expect {
            try GalleryDetailParser.parse("<div class=\"d\">\n<p>Fixture retry later</p></div>")
        } throws: { error in
            guard case .serverMessage("Fixture retry later")? = error as? GalleryDetailParser.DetailParseError else { return false }
            return true
        }
    }

    @Test func readerDecodesEmbeddedLinksAndDistinguishesInvalidInputs() throws {
        let page = try GalleryPageApiParser.parse(fixture("showpage", "json"))
        #expect(page.imageUrl == "https://fixture.invalid/page.webp?size=1200&mode=fit")
        #expect(page.originImageUrl == "https://fixture.invalid/original.webp?item=1&kind=original")
        #expect(page.skipHathKey == "fixture-retry")
        #expect(page.showKey == "fixture-show")

        let htmlPage = try GalleryPageParser.parse("""
            <img id="img" src="https://fixture.invalid/page.webp?size=1200&amp;mode=fit">
            <script>var showkey = "fixture-show";</script>
            <a onclick="return nl('fixture-retry')">Retry</a>
            <a href="https://fixture.invalid/original.webp?item=1&amp;kind=original">Download original</a>
            """)
        #expect(htmlPage.imageUrl == page.imageUrl)
        #expect(htmlPage.originImageUrl == page.originImageUrl)
        #expect(htmlPage.skipHathKey == page.skipHathKey)
        #expect(htmlPage.showKey == page.showKey)

        #expect(throws: GalleryPageApiParser.ParseError.invalidJSON) {
            try GalleryPageApiParser.parse(Data("[]".utf8))
        }
        #expect(throws: GalleryPageParser.Error.imageUrlNotFound) {
            try GalleryPageParser.parse("<html><p>Retry later</p></html>")
        }
    }

    @Test func searchLinkKeepsSpacesAndQualifiedTerms() throws {
        let search = try #require(GalleryListUrlParser.parse(
            "https://fixture.invalid/?f_search=night%20garden%20language%3Aenglish&f_cats=32"
        ))
        #expect(search.mode == 0)
        #expect(search.category == 32)
        #expect(search.keyword == "night garden language:english")
        #expect(GalleryListUrlParser.parse("https://fixture.invalid/favorites.php") == nil)
    }
}
