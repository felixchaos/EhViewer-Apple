// Never present in a normal build. An explicit simulator build is required.
#if EH_OFFLINE_UI_FIXTURE && targetEnvironment(simulator)
import Foundation
import EhDatabase
import EhModels
import EhSettings

@MainActor
enum EhOfflineUIFixture {
    static let enabled = ProcessInfo.processInfo.environment["EH_OFFLINE_UI_FIXTURE"] == "1"
    static let synthetic = GalleryInfo(gid: 900010000001, token: "fixture", title: "Synthetic Gallery")
    static let cloud = GalleryInfo(gid: 900010000002, token: "fixture", title: "Synthetic Cloud Gallery", favoriteSlot: 0)

    static func seed() {
        AppSettings.shared.recentFavCat = -1
        AppSettings.shared.defaultFavSlot = -1
        AppSettings.shared.launchPage = 0
        try? EhDatabase.shared.deleteLocalFavorite(gid: synthetic.gid)
        try? EhDatabase.shared.deleteLocalFavorite(gid: cloud.gid)
        GalleryCache.shared.putDetail(.init(info: synthetic))
        GalleryCache.shared.putDetail(.init(info: cloud, isFavorited: true))
    }

    static func listResponse(_ url: String = "") throws -> GalleryListResult {
        if url.contains("favorites.php") {
            switch ProcessInfo.processInfo.environment["EH_FIXTURE_CLOUD"] {
            case "one": return GalleryListResult(galleries: [cloud])
            case "failure": throw URLError(.notConnectedToInternet)
            default: return GalleryListResult()
            }
        }
        return GalleryListResult(galleries: [synthetic])
    }
}
#endif
