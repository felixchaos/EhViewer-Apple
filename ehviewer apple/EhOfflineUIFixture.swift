// Never present in a normal build. An explicit simulator build is required.
#if EH_OFFLINE_UI_FIXTURE && targetEnvironment(simulator)
import Foundation
import EhDatabase
import EhModels
import EhSettings
import SQLite3

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
        if let identifier = ProcessInfo.processInfo.environment["EH_FIXTURE_IMPORT"],
           UUID(uuidString: identifier) != nil {
            seedImportScenario(identifier: identifier)
        }
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
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = documents.appendingPathComponent("offline-regression-\(identifier).db")
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
