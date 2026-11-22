// Never present in a normal build. An explicit simulator build is required.
#if EH_OFFLINE_UI_FIXTURE && targetEnvironment(simulator)
import Foundation
import SwiftUI
import UIKit
import EhDownload
import EhDatabase
import EhModels
import EhSettings
import SQLite3

@MainActor
enum EhOfflineUIFixture {
    static let enabled = ProcessInfo.processInfo.environment["EH_OFFLINE_UI_FIXTURE"] == "1"
    static let readerEnabled = ProcessInfo.processInfo.environment["EH_FIXTURE_LOCAL_READER"] == "1"
    static let synthetic = GalleryInfo(
        gid: 900010000001, token: "fixture", title: "Synthetic Gallery", pages: readerEnabled ? 3 : 0
    )
    static let cloud = GalleryInfo(gid: 900010000002, token: "fixture", title: "Synthetic Cloud Gallery", favoriteSlot: 0)

    private static let historyTagFixtureEnabled =
        ProcessInfo.processInfo.environment["EH_FIXTURE_HISTORY_TAG"] == "1"
    private static let historyTag = "route fixture"
    private static let historyGallery = GalleryInfo(
        gid: 900010000008, token: "fixture", title: "Synthetic tag history item"
    )
    private static let historyTagResult = GalleryInfo(
        gid: 900010000009, token: "fixture", title: "Synthetic history tag result"
    )

    static func seed() {
        AppSettings.shared.recentFavCat = -1
        AppSettings.shared.defaultFavSlot = -1
        let fixturePage = ProcessInfo.processInfo.environment["EH_FIXTURE_LAUNCH_PAGE"].flatMap(Int.init) ?? 0
        AppSettings.shared.launchPage = (0...5).contains(fixturePage) ? fixturePage : 0
        try? EhDatabase.shared.deleteLocalFavorite(gid: synthetic.gid)
        try? EhDatabase.shared.deleteLocalFavorite(gid: cloud.gid)
        GalleryCache.shared.putDetail(.init(info: synthetic))
        GalleryCache.shared.putDetail(.init(info: cloud, isFavorited: true))
        if historyTagFixtureEnabled {
            try? EhDatabase.shared.insertHistory(.init(gid: historyGallery.gid, token: historyGallery.token,
                                                       title: historyGallery.title ?? "", date: Date()))
            GalleryCache.shared.putDetail(.init(info: historyGallery,
                                                 tags: [.init(groupName: "artist", tags: [historyTag])]))
            GalleryCache.shared.putDetail(.init(info: historyTagResult))
        }
        if let identifier = ProcessInfo.processInfo.environment["EH_FIXTURE_IMPORT"],
           UUID(uuidString: identifier) != nil {
            seedImportScenario(identifier: identifier)
        }
    }

    static func seedReaderFiles() async -> Bool {
        UserDefaults.standard.set(true, forKey: "reader_tutorial_shown")
        UserDefaults.standard.removeObject(forKey: "reading_progress_\(synthetic.gid)")
        // A real download record and images enter through the usual persistence API.
        // Open the fixture UI only once all pages are available, so it cannot fall back to the network.
        let manager = DownloadManager.shared
        for page in 0..<synthetic.pages {
            let color: UIColor = [.systemRed, .systemBlue, .systemGreen][page]
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 180))
            let image = renderer.image { ctx in
                color.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 180))
                String(page + 1).draw(at: CGPoint(x: 30, y: 50), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 48), .foregroundColor: UIColor.white
                ])
            }
            guard let bytes = image.pngData() else { return false }
            await manager.saveWhileReading(gallery: synthetic, pageIndex: page, data: bytes, extension: ".png")
        }
        let saved = await manager.getDownloadedPageCount(gid: synthetic.gid)
        let directory = await manager.localGalleryDirectory(gid: synthetic.gid)
        return saved == synthetic.pages && directory != nil
    }

    static var injectedImportURL: URL? {
        let environment = ProcessInfo.processInfo.environment
        guard enabled, environment["EH_FIXTURE_NATIVE_FILE_PICKER"] != "1",
              let identifier = environment["EH_FIXTURE_IMPORT"],
              UUID(uuidString: identifier) != nil else { return nil }
        return importURL(identifier: identifier)
    }

    private static func importURL(identifier: String) -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("offline-regression-\(identifier).db")
    }

    private static func seedImportScenario(identifier: String) {
        let prior: Int64 = 900010000003
        AppSettings.shared.historyInfoSize = 100
        UserDefaults.standard.set(prior, forKey: "eh_last_reading_gid")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "eh_last_reading_time")
        UserDefaults.standard.set(4, forKey: "reading_progress_\(prior)")
        try? EhDatabase.shared.insertHistory(.init(gid: prior, token: "fixture", title: "Apple resume fixture",
                                                    pages: 20, date: Date(timeIntervalSince1970: 1)))
        for index in 0..<55 {
            try? EhDatabase.shared.deleteHistory(gid: Int64(900010000100 + index))
        }
        try? EhDatabase.shared.deleteLocalFavorite(gid: 900010000099)
        guard let url = importURL(identifier: identifier) else { return }
        try? FileManager.default.removeItem(at: url)
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { return }
        defer { sqlite3_close(db) }
        let fields = "GID INTEGER PRIMARY KEY NOT NULL, TOKEN TEXT, TITLE TEXT, TITLE_JPN TEXT, THUMB TEXT, CATEGORY INTEGER NOT NULL, POSTED TEXT, UPLOADER TEXT, RATING REAL NOT NULL, SIMPLE_LANGUAGE TEXT, TIME INTEGER NOT NULL"
        sqlite3_exec(db, "CREATE TABLE LOCAL_FAVORITES (\(fields)); CREATE TABLE HISTORY (\(fields), MODE INTEGER NOT NULL);", nil, nil, nil)
        sqlite3_exec(db, "INSERT INTO LOCAL_FAVORITES (GID,TOKEN,TITLE,CATEGORY,RATING,TIME) VALUES (900010000099,'sample','Imported favorite fixture',1,0,1700000000000);", nil, nil, nil)
        for index in 0..<55 {
            sqlite3_exec(db, "INSERT INTO HISTORY (GID,TOKEN,TITLE,CATEGORY,RATING,TIME,MODE) VALUES (\(900010000100 + index),'sample','Imported reading \(index)',1,0,\(1_700_000_000_000 + index),0);", nil, nil, nil)
        }
    }

    private static var homeReselectRequests = 0

    static func listResponse(_ url: String = "") throws -> GalleryListResult {
        if url.contains("favorites.php") {
            switch ProcessInfo.processInfo.environment["EH_FIXTURE_CLOUD"] {
            case "one": return GalleryListResult(galleries: [cloud])
            case "failure": throw URLError(.notConnectedToInternet)
            default: return GalleryListResult()
            }
        }
        // Assert the actual submitted request, not merely a selected tab label.
        if let term = URLComponents(string: url)?.queryItems?.first(where: { $0.name == "f_search" })?.value {
            if term == "offlineretap", ProcessInfo.processInfo.environment["EH_FIXTURE_HOME_RESELECT"] == "1" {
                homeReselectRequests += 1
                return GalleryListResult(galleries: (1...36).map { row in
                    GalleryInfo(gid: 900010000300 + Int64(row), token: "fixture",
                                title: "Reselect result \(row), request \(homeReselectRequests)")
                })
            }
            let results: (Int64, String)? = switch term {
            case "offlinehome": (900010000006, "Synthetic home search result")
            case "offlinepopular": (900010000007, "Synthetic popular search result")
            default: nil
            }
            if let (id, title) = results {
                return GalleryListResult(galleries: [GalleryInfo(gid: id, token: "fixture", title: title)])
            }
        }
        // Deliberately distinct responses prove the UI chose the expected request.
        // Keep the original home fixture and other paths stable.
        switch URLComponents(string: url)?.path {
        case "/tag/artist:\(historyTag)" where historyTagFixtureEnabled:
            return GalleryListResult(galleries: [historyTagResult])
        case "/popular":
            return GalleryListResult(galleries: [
                GalleryInfo(gid: 900010000004, token: "fixture", title: "Synthetic popular launch")
            ])
        case "/toplist.php":
            return GalleryListResult(galleries: [
                GalleryInfo(gid: 900010000005, token: "fixture", title: "Synthetic ranking launch")
            ])
        default:
            return GalleryListResult(galleries: [synthetic])
        }
    }
}

/// Only the synthetic reader launch needs asynchronous local data setup.
struct EhOfflineReaderFixtureHost: View {
    @State private var ready: Bool?
    var body: some View {
        Group {
            switch ready {
            case .some(true): MainTabView().environment(AppState())
            case .some(false): Text("Unable to seed offline reader fixture")
            case nil: ProgressView()
            }
        }
        .task { ready = await EhOfflineUIFixture.seedReaderFiles() }
    }
}
#endif
