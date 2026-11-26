import Foundation
import GRDB
import Testing
@testable import EhDatabase

@Suite struct EhDatabaseMigrationTests {
    private let originalDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func withDiskDatabase(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir.appendingPathComponent("fixture.sqlite"))
    }

    /// Freeze the v1/v2 table shapes independently of the current migrations.
    /// These synthetic disk fixtures do not use the new schema builder to create old rows.
    private func seedLegacyDisk(_ url: URL, version: Int, incompatibleV3Column: Bool = false) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            let common = """
                gid INTEGER PRIMARY KEY, token TEXT NOT NULL, title TEXT NOT NULL,
                titleJpn TEXT, thumb TEXT, category INTEGER NOT NULL DEFAULT 0,
                posted TEXT, uploader TEXT, rating DOUBLE DEFAULT 0, simpleLanguage TEXT,
                pages INTEGER DEFAULT 0
                """
            try db.execute(sql: """
                CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
                INSERT INTO grdb_migrations VALUES ('v1');
                CREATE TABLE download (
                    \(common), state INTEGER NOT NULL DEFAULT 0, legacy INTEGER NOT NULL DEFAULT 0,
                    date INTEGER NOT NULL, label TEXT
                );
                CREATE TABLE history (\(common), mode INTEGER NOT NULL DEFAULT 0, date INTEGER NOT NULL);
                CREATE TABLE localFavorite (\(common), date INTEGER NOT NULL);
                CREATE TABLE downloadLabel (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, label TEXT NOT NULL UNIQUE, date INTEGER NOT NULL
                );
                CREATE TABLE quickSearch (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, mode INTEGER NOT NULL, category INTEGER NOT NULL,
                    keyword TEXT, advanceSearch INTEGER NOT NULL DEFAULT 0, minRating INTEGER NOT NULL DEFAULT 0,
                    pageFrom INTEGER NOT NULL DEFAULT 0, pageTo INTEGER NOT NULL DEFAULT 0, date INTEGER NOT NULL
                );
                CREATE TABLE filter (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, mode INTEGER NOT NULL, text TEXT,
                    enable BOOLEAN NOT NULL DEFAULT 1, date INTEGER NOT NULL
                )
                """)
            try db.execute(sql: """
                INSERT INTO download (gid,token,title,state,legacy,date,label)
                VALUES (10,'fixture','legacy download',2,7,?,'kept label')
                """, arguments: [originalDate])
            try db.execute(sql: """
                INSERT INTO history (gid,token,title,date,mode,pages)
                VALUES (20,'fixture','legacy history',?,1,42)
                """, arguments: [originalDate])
            try db.execute(sql: """
                INSERT INTO localFavorite (gid,token,title,date) VALUES (30,'fixture','legacy favorite',?)
                """, arguments: [originalDate])
            try db.execute(sql: "INSERT INTO downloadLabel (label, date) VALUES ('kept label', ?)",
                           arguments: [originalDate])
            try db.execute(sql: "INSERT INTO quickSearch (name, mode, category, keyword, date) VALUES ('fixture search', 0, 0, 'neutral', ?)",
                           arguments: [originalDate])
            try db.execute(sql: "INSERT INTO filter (mode, text, date) VALUES (0, 'fixture filter', ?)",
                           arguments: [originalDate])
            if version == 2 {
                try db.execute(sql: """
                    INSERT INTO grdb_migrations VALUES ('v2');
                    CREATE TABLE bookmark (\(common), page INTEGER NOT NULL DEFAULT 0, date INTEGER NOT NULL);
                    CREATE TABLE downloadDirname (gid INTEGER PRIMARY KEY, dirname TEXT NOT NULL);
                    CREATE TABLE blackList (
                        id INTEGER PRIMARY KEY AUTOINCREMENT, badgayname TEXT NOT NULL,
                        reason TEXT, angrywith TEXT, addTime TEXT, mode INTEGER
                    );
                    CREATE INDEX blackList_on_badgayname ON blackList(badgayname);
                    CREATE TABLE galleryTags (
                        gid INTEGER PRIMARY KEY, rows TEXT, artist TEXT, cosplayer TEXT, character TEXT,
                        female TEXT, "group" TEXT, language TEXT, male TEXT, misc TEXT, mixed TEXT,
                        other TEXT, parody TEXT, reclass TEXT, createTime DATETIME, updateTime DATETIME
                    )
                    """)
                try db.execute(sql: """
                    INSERT INTO bookmark (gid,token,title,page,date) VALUES (40,'fixture','legacy bookmark',12,?)
                    """, arguments: [originalDate])
                try db.execute(sql: """
                    INSERT INTO downloadDirname VALUES (10,'neutral-original-folder')
                    """)
            }
            if incompatibleV3Column {
                try db.execute(sql: "ALTER TABLE history ADD COLUMN simpleTags TEXT")
            }
        }
    }

    @Test(arguments: [1, 2])
    func upgradeAndReopenExistingDisk(version: Int) throws {
        try withDiskDatabase { url in
            try seedLegacyDisk(url, version: version)
            do {
                let db = try EhDatabase(storageURL: url)
                #expect(!db.isDegraded)
                let download = try #require(try db.getDownload(gid: 10))
                let history = try #require(try db.getHistory(gid: 20))
                let favorite = try #require(try db.getLocalFavorite(gid: 30))
                #expect(download.title == "legacy download")
                #expect(download.state == 2)
                #expect(download.legacy == 7)
                #expect(download.label == "kept label")
                #expect(history.title == "legacy history")
                #expect(history.date == originalDate)
                #expect(history.mode == 1)
                #expect(history.pages == 42)
                #expect(favorite.title == "legacy favorite")
                #expect(favorite.date == originalDate)
                #expect(download.simpleTags == nil)
                #expect(history.simpleTags == nil)
                #expect(favorite.simpleTags == nil)
                if version == 2 {
                    let bookmark = try #require(try db.getBookmark(gid: 40))
                    #expect(bookmark.title == "legacy bookmark")
                    #expect(bookmark.page == 12)
                    #expect(bookmark.date == originalDate)
                } else {
                    #expect(try db.getAllBookmarks().isEmpty)
                }
                var updatedDownload = download
                updatedDownload.simpleTags = ["language:english"]
                try db.updateDownload(updatedDownload)
                var updatedHistory = history
                updatedHistory.simpleTags = ["category:fixture"]
                try db.insertHistory(updatedHistory)
                var updatedFavorite = favorite
                updatedFavorite.simpleTags = ["artist:fixture"]
                try db.insertLocalFavorite(updatedFavorite)
            }
            do {
                let reopened = try EhDatabase(storageURL: url)
                #expect(try reopened.getDownload(gid: 10)?.simpleTags == ["language:english"])
                #expect(try reopened.getHistory(gid: 20)?.simpleTags == ["category:fixture"])
                #expect(try reopened.getLocalFavorite(gid: 30)?.simpleTags == ["artist:fixture"])
                #expect(try reopened.getBookmark(gid: 40)?.page == (version == 2 ? 12 : nil))
                #expect(try reopened.getAllDownloadLabels().map(\.label) == ["kept label"])
                #expect(try reopened.getAllQuickSearches().map(\.name) == ["fixture search"])
                #expect(try reopened.getAllFilters().map(\.text) == ["fixture filter"])
            }
            let inspection = try DatabaseQueue(path: url.path)
            try inspection.read { db throws -> Void in
                #expect(try String.fetchSet(db, sql: "SELECT identifier FROM grdb_migrations") == ["v1", "v2", "v3", "v4", "v5"])
                #expect(try db.columns(in: "quickSearch").contains { $0.name == "browseSnapshotVersion" && !$0.isNotNull })
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM quickSearch WHERE browseSnapshotVersion IS NOT NULL") == 0)
                #expect(try String.fetchOne(db, sql: "PRAGMA quick_check") == "ok")
                if version == 2 {
                    #expect(try String.fetchOne(db, sql: "SELECT dirname FROM downloadDirname WHERE gid = 10")
                            == "neutral-original-folder")
                }
            }
        }
    }

    @Test func failedMigrationRollsBackSchemaAndPreservesOldRows() throws {
        try withDiskDatabase { url in
            try seedLegacyDisk(url, version: 2, incompatibleV3Column: true)
            #expect(throws: DatabaseError.self) { try EhDatabase(storageURL: url) }
            let inspection = try DatabaseQueue(path: url.path)
            try inspection.read { db throws -> Void in
                #expect(try String.fetchSet(db, sql: "SELECT identifier FROM grdb_migrations") == ["v1", "v2"])
                // v3 adds download.simpleTags before hitting history's incompatible
                // already-present column. The first ALTER must be rolled back.
                #expect(try !db.columns(in: "download").contains { $0.name == "simpleTags" })
                #expect(try !db.columns(in: "localFavorite").contains { $0.name == "simpleTags" })
                #expect(try String.fetchOne(db, sql: "SELECT title FROM download WHERE gid = 10") == "legacy download")
                #expect(try String.fetchOne(db, sql: "SELECT title FROM history WHERE gid = 20") == "legacy history")
                #expect(try String.fetchOne(db, sql: "SELECT title FROM localFavorite WHERE gid = 30") == "legacy favorite")
            }
        }
    }
}
