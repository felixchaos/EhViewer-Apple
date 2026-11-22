import EhModels
import Foundation
import Testing
@testable import EhParser

@Suite("Offline service parser regression")
struct ServiceParserRegressionTests {
    @Test func userTagsAllowMissingEmptyAndHeaderOnlyContainers() throws {
        let bodies = [
            "<main>Nothing to show</main>",
            "<div id=\"usertags_outer\"></div>",
            "<div id=\"usertags_outer\"><h2>Your tags</h2></div>",
        ]
        for body in bodies {
            #expect(try MyTagListParser.parse(body).userTags.isEmpty)
        }
    }

    @Test func userTagsKeepRecordIDAndFiltersButNotHeader() throws {
        let body = """
            <div id="usertags_outer">
              <h2>Your tags</h2>
              <section id="usertag_1">
                <div id="tagpreview1" title="language:english"></div>
                <input id="tagwatch1" checked="checked">
                <input id="taghide1">
                <input id="tagcolor1" placeholder="#736f9f">
                <input id="tagweight1" value="12">
              </section>
              <section id="usertag_2">
                <div id="tagpreview2" title="artist:fixture"></div>
                <input id="taghide2" checked="checked">
                <input id="tagcolor2" placeholder="">
                <input id="tagweight2" value="not a number">
              </section>
            </div>
            """
        let parsed = try MyTagListParser.parse(body)
        #expect(parsed.userTags.map(\.id) == ["usertag_1", "usertag_2"])
        #expect(parsed.userTags.map(\.tagName) == ["language:english", "artist:fixture"])
        #expect(parsed.userTags.map(\.watched) == [true, false])
        #expect(parsed.userTags.map(\.hidden) == [false, true])
        #expect(parsed.userTags.map(\.color) == ["#736f9f", nil])
        #expect(parsed.userTags.map(\.tagWeight) == [12, 0])
    }

    @Test func signInSeparatesAcceptedRejectedAndUnknownResponses() throws {
        #expect(try SignInParser.parse("<p>You are now logged in as: Fixture Reader</p>") == "Fixture Reader")
        for rejected in [
            "<h4>The error returned was:</h4><p>Fixture denial</p>",
            "<span class=\"postcolor\">Fixture denial</span>",
        ] {
            #expect {
                try SignInParser.parse(rejected)
            } throws: { error in
                guard case .signInError("Fixture denial")? = error as? EhParseError else { return false }
                return true
            }
        }
        #expect {
            try SignInParser.parse("<h1>Unrecognized page</h1>")
        } throws: { error in
            guard case .parseFailure? = error as? EhParseError else { return false }
            return true
        }
    }

    @Test func galleryMetadataUpdatesOnlyMatchingIDsWithoutReordering() throws {
        var galleries = [GalleryInfo(gid: 51, title: "Keep"), GalleryInfo(gid: 52, title: "Update")]
        let response = Data("""
            {"gmetadata":[{"gid":52,"title":"Field Notes","tags":["language:english"],"rating":"4.25","filecount":"12"},
            {"gid":999,"title":"Not Requested"}]}
            """.utf8)
        try GalleryApiParser.parse(response, galleries: &galleries)
        #expect(galleries.map(\.gid) == [51, 52])
        #expect(galleries.map(\.title) == ["Keep", "Field Notes"])
        #expect(galleries.last?.simpleLanguage == "EN")
        #expect(galleries.last?.rating == 4.25)
        #expect(galleries.last?.pages == 12)
    }

    @Test func readerPageLinkConvertsOneBasedRemoteIndex() throws {
        let strict = try #require(GalleryPageUrlParser.parse("https://e-hentai.org/s/a1b2c3d4e5/51-1"))
        #expect(strict.gid == 51)
        #expect(strict.pToken == "a1b2c3d4e5")
        #expect(strict.page == 0)
        #expect(GalleryPageUrlParser.parse("/s/a1b2c3d4e5/51-4") == nil)
        #expect(GalleryPageUrlParser.parseLoose("/s/a1b2c3d4e5/51-4")?.page == 3)
    }

    @Test func archiveAndTorrentPreserveOfferAndRowIdentityWithoutNetwork() throws {
        let archive = try ArchiveParser.parse("""
            <form id="hathdl_form" action="/archive?or=fixture-offer" method="post">
              <a href="#" onclick="return do_hathdl('org')">Original</a>
              <a href="#" onclick="return do_hathdl('1280')">Resampled</a>
            </form>
            """)
        #expect(archive.paramOr == "fixture-offer")
        #expect(archive.archives.map { $0.0 } == ["org", "1280"])
        #expect(archive.archives.map { $0.1 } == ["Original", "Resampled"])
        #expect(ArchiveParser.parseArchiverDownloadUrl("<p>Not ready</p>") == nil)

        let torrents = TorrentParser.parse("""
            <form><span>Posted:</span><span>May 1</span>
              <td colspan="5">&nbsp; <a
                href="https://fixture.invalid/lantern.torrent?p=dummy">Paper
                Lanterns</a></td></form>
            <form><span>Posted:</span><span>Not a download row</span></form>
            <form><td colspan="5">&nbsp; <a href="https://fixture.invalid/moss.torrent">Moss</a></td></form>
            """)
        #expect(torrents.map(\.url) == ["https://fixture.invalid/lantern.torrent", "https://fixture.invalid/moss.torrent"])
        #expect(torrents.map(\.name) == ["Paper Lanterns", "Moss"])
        #expect(torrents.map(\.posted) == ["May 1", ""])
    }
}
