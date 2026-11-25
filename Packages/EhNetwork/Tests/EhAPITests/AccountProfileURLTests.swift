import Foundation
import Testing
@testable import EhAPI

struct AccountProfileURLTests {
    private let forums = URL(string: "https://forums.e-hentai.org/")!

    @Test func acceptsRelativeSelfProfileOnTheOfficialHost() throws {
        let result = try EhAPI.forumProfileURL("/index.php?showuser=52", relativeTo: forums, expectedMemberID: "52")
        #expect(result.absoluteString == "https://forums.e-hentai.org/index.php?showuser=52")
    }

    @Test func neverReadsAPreviouslyCachedAccountPage() {
        let request = EhAPI.accountProfileRequest(forums)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
    }

    @Test(arguments: [
        "/index.php?showuser=53",
        "/index.php?showuser=52&showuser=53",
        "/index.php",
        "https://other.invalid/index.php?showuser=52",
        "http://forums.e-hentai.org/index.php?showuser=52"
    ])
    func rejectsAnUnboundOrUntrustedProfile(_ location: String) {
        #expect(throws: EhError.self) {
            try EhAPI.forumProfileURL(location, relativeTo: forums, expectedMemberID: "52")
        }
    }
}
