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

    // Keep this UI test independent of other synthetic scenarios on a reused simulator.
    static var downloadSortIDs: Set<Int64>? {
        guard enabled, ProcessInfo.processInfo.environment["EH_FIXTURE_DOWNLOAD_SORT"] == "1" else { return nil }
        return [900010000025, 900010000026]
    }

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
        let progressKey = "reading_progress_\(synthetic.gid)"
        if ProcessInfo.processInfo.environment["EH_FIXTURE_SAVED_READER_PAGE"] == "1" {
            UserDefaults.standard.set(1, forKey: progressKey)
        } else {
            UserDefaults.standard.removeObject(forKey: progressKey)
        }
        // A real download record and images enter through the usual persistence API.
        // Open the fixture UI only once all pages are available, so it cannot fall back to the network.
        let manager = DownloadManager.shared
        let clearFinished = ProcessInfo.processInfo.environment["EH_FIXTURE_CLEAR_FINISHED"] == "1"
        let sort = ProcessInfo.processInfo.environment["EH_FIXTURE_DOWNLOAD_SORT"] == "1"
        let completed = sort
            ? GalleryInfo(gid: 900010000025, token: "fixture", title: "Sort Fixture Zebra", category: .manga, rating: 2, pages: 3)
            : clearFinished
                ? GalleryInfo(gid: 900010000010, token: "fixture", title: "Synthetic cleared download", pages: 3)
                : synthetic
        let paused = sort
            ? GalleryInfo(gid: 900010000026, token: "fixture", title: "Sort Fixture Apple", category: .misc, rating: 4, pages: 2)
            : GalleryInfo(gid: 900010000011, token: "fixture", title: "Synthetic preserved download", pages: 2)
        for page in 0..<completed.pages {
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
            await manager.saveWhileReading(gallery: completed, pageIndex: page, data: bytes, extension: ".png")
            if (clearFinished || sort), page == 0 {
                await manager.saveWhileReading(gallery: paused, pageIndex: 0, data: bytes, extension: ".png")
            }
        }
        let saved = await manager.getDownloadedPageCount(gid: completed.gid)
        let directory = await manager.localGalleryDirectory(gid: completed.gid)
        return saved == completed.pages && directory != nil
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
        if ProcessInfo.processInfo.environment["EH_FIXTURE_ADVANCED_SEARCH"] == "1",
           let components = URLComponents(string: url) {
            let values = components.queryItems ?? []
            func value(_ name: String) -> String? { values.first { $0.name == name }?.value }
            if value("f_search") == "offline-filter-reset" {
                if value("advsearch") == "1" { return GalleryListResult() }
                return GalleryListResult(galleries: [.init(gid: 900010001085, token: "fixture",
                                                            title: "Synthetic same query after clearing filters")])
            }
            if value("f_search") == nil, value("advsearch") == "1", value("f_sr") == "on",
               let rating = value("f_srdd"), ["4", "5"].contains(rating) {
                let gid: Int64 = rating == "4" ? 900010001064 : 900010001065
                if rating == "4", value("next") == "fixture-rating-four" {
                    return GalleryListResult(galleries: [.init(gid: gid + 10, token: "fixture", title: "Synthetic rating 4 cursor page")])
                }
                if rating == "5", value("page") == "1" {
                    return GalleryListResult(galleries: [.init(gid: gid + 10, token: "fixture", title: "Synthetic rating 5 numbered page")])
                }
                let item = GalleryInfo(gid: gid, token: "fixture", title: "Synthetic rating \(rating)")
                if rating == "4" {
                    var cursor = components
                    cursor.queryItems = values + [URLQueryItem(name: "next", value: "fixture-rating-four")]
                    return GalleryListResult(galleries: [item], pages: -1, nextHref: cursor.url?.absoluteString)
                }
                return GalleryListResult(galleries: [item], pages: 2, nextPage: 1)
            }
        }
        if ProcessInfo.processInfo.environment["EH_FIXTURE_SUBSCRIPTION_FLOW"] == "1",
           let request = URLComponents(string: url) {
            let watched = request.path == "/watched"
            let values = request.queryItems ?? []
            func value(_ name: String) -> String? { values.first { $0.name == name }?.value }
            if value("f_search") == "fixtureflow" {
                if !watched {
                    return GalleryListResult(galleries: [
                        .init(gid: 900010011001, token: "fixture", title: "Unexpected global flow result")
                    ])
                }
                if value("advsearch") == "1", value("f_sr") == "on", value("f_srdd") == "4" {
                    return GalleryListResult()
                }
                if value("next") == "watched-fixture-cursor" {
                    return GalleryListResult(galleries: [
                        .init(gid: 900010011002, token: "fixture", title: "Watched flow cursor result")
                    ])
                }
                var cursor = request
                cursor.queryItems = values + [URLQueryItem(name: "next", value: "watched-fixture-cursor")]
                return GalleryListResult(galleries: [
                    .init(gid: 900010011003, token: "fixture", title: "Watched flow first result")
                ], pages: -1, nextHref: cursor.url?.absoluteString)
            }
            if watched, value("f_search") == nil {
                return GalleryListResult(galleries: (1...30).map { row in
                    .init(gid: 900010011100 + Int64(row), token: "fixture", title: "Watched origin row \(row)")
                })
            }
        }
        if ProcessInfo.processInfo.environment["EH_FIXTURE_SEARCH_SCOPE"] == "1",
           let request = URLComponents(string: url) {
            let watched = request.path == "/watched"
            let term = request.queryItems?.first { $0.name == "f_search" }?.value
            if term == "offlineparity" {
                return GalleryListResult(galleries: [.init(gid: watched ? 900010009101 : 900010009102,
                    token: "fixture", title: watched ? "Scoped fixture result" : "Global fixture result")])
            }
            if watched {
                return GalleryListResult(galleries: [.init(gid: 900010009103,
                    token: "fixture", title: "Synthetic subscription origin")])
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
