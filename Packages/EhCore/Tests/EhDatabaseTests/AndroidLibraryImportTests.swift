import Foundation
import GRDB
import Testing
@testable import EhDatabase

@Suite struct AndroidLibraryImportTests {
    private let millisecond: Int64 = 1_700_000_000_123

    private func withFiles(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.appendingPathComponent("android.db"), root.appendingPathComponent("apple.sqlite"))
    }

    /// The schema shape is the Android exporter’s generated GreenDAO definitions,
    /// not a fixture based on the Apple schema.
    private func makeSource(_ url: URL, populate: Bool = true) throws {
        let sourceDB = try DatabaseQueue(path: url.path)
        try sourceDB.write { db in
            let columns = """
              GID INTEGER PRIMARY KEY NOT NULL, TOKEN TEXT, TITLE TEXT, TITLE_JPN TEXT, THUMB TEXT,
              CATEGORY INTEGER NOT NULL, POSTED TEXT, UPLOADER TEXT, RATING REAL NOT NULL,
              SIMPLE_LANGUAGE TEXT, TIME INTEGER NOT NULL
            """
            try db.execute(sql: "CREATE TABLE LOCAL_FAVORITES (\(columns))")
            try db.execute(sql: "CREATE TABLE HISTORY (\(columns), MODE INTEGER NOT NULL)")
            try db.execute(sql: "CREATE TABLE BOOKMARKS (GID INTEGER PRIMARY KEY, PAGE INTEGER, TIME INTEGER)")
            try db.execute(sql: "INSERT INTO BOOKMARKS VALUES (80, 3, 563)")
            guard populate else { return }
            for table in ["LOCAL_FAVORITES", "HISTORY"] {
                let modeCol = table == "HISTORY" ? ", MODE" : ""
                let modeVal = table == "HISTORY" ? ", 0" : ""
                try db.execute(sql: """
                    INSERT INTO \(table) (GID,TOKEN,TITLE,TITLE_JPN,THUMB,CATEGORY,POSTED,UPLOADER,RATING,SIMPLE_LANGUAGE,TIME\(modeCol))
                    VALUES (1,'existing','android copy',NULL,NULL,1,NULL,NULL,0,NULL,?\(modeVal)),
                           (2,'sampletoken','neutral fixture','見本','https://thumb.ehgt.org/ok.jpg',2,'2024-01-01','fixture',4.25,'EN',?\(modeVal)),
                           (3,'othertoken','newer sample',NULL,'https://ehgt.org@untrusted.example/x.jpg',4,NULL,NULL,0,NULL,?\(modeVal)),
                           (4,'missingtitle',NULL,NULL,NULL,4,NULL,NULL,0,NULL,?\(modeVal)),
                           (5,'/bad?token','bad token',NULL,NULL,4,NULL,NULL,0,NULL,?\(modeVal)),
                           (6,X'4142','binary token',NULL,NULL,4,NULL,NULL,0,NULL,?\(modeVal)),
                           (7,'badtime','bad timestamp',NULL,NULL,4,NULL,NULL,0,NULL,'bad'\(modeVal))
                    """, arguments: [millisecond, millisecond, millisecond + 5_432,
                                     millisecond, millisecond, millisecond])
            }
        }
    }

    @Test func previewUsesExactSnapshotAndMergePreservesExistingRecords() throws {
        try withFiles { sourcePath, targetPath in
            try makeSource(sourcePath)
            let original = try Data(contentsOf: sourcePath)
            let source = try AndroidLibraryImport(exportAt: sourcePath)
            let target = try EhDatabase(storageURL: targetPath)
            let appleDate = Date(timeIntervalSince1970: 1_600_000_000)
            try target.insertHistory(HistoryRecord(gid: 1, token: "destination", title: "historical Apple title", pages: 8, date: appleDate))
            try target.insertLocalFavorite(LocalFavoriteRecord(gid: 1, token: "destination", title: "saved Apple title", date: appleDate))

            let preview = try target.previewAndroidLibrary(source, historyLimit: 10)
            #expect(preview.favorites == AndroidLibraryImportCounts(new: 2, existing: 1, invalid: 4))
            #expect(preview.history == preview.favorites)
            #expect(try target.getAllHistory().map(\.gid) == [1])
            #expect(try target.getAllLocalFavorites().map(\.gid) == [1])
            #expect(try Data(contentsOf: sourcePath) == original)
            #expect(!FileManager.default.fileExists(atPath: sourcePath.path + "-wal"))
            #expect(!FileManager.default.fileExists(atPath: sourcePath.path + "-shm"))

            // The approved typed snapshot is independent from a later file at this URL.
            try FileManager.default.removeItem(at: sourcePath)
            try Data("changed after preview".utf8).write(to: sourcePath)
            let committed = try target.importAndroidLibrary(source, historyLimit: 10)
            #expect(committed == preview)
            let favorites = try target.getAllLocalFavorites()
            #expect(favorites.map(\.gid) == [3, 2, 1])
            #expect(favorites.first?.thumb == nil)
            #expect(favorites[1].thumb == "https://thumb.ehgt.org/ok.jpg")
            #expect(favorites[1].rating == 4.25)
            #expect(favorites[1].simpleLanguage == "EN")
            #expect(favorites[1].titleJpn == "見本")
            #expect(favorites.last?.title == "saved Apple title")
            #expect(favorites.last?.date == appleDate)
            let history = try target.getAllHistory()
            #expect(history.map(\.gid) == [3, 2, 1])
            #expect(history.last?.title == "historical Apple title")
            #expect(history.last?.pages == 8)
            #expect(abs(history[1].date.timeIntervalSince1970 - Double(millisecond) / 1000) < 0.001)
            #expect(try target.getAllBookmarks().isEmpty)

            let repeated = try target.importAndroidLibrary(source, historyLimit: 10)
            #expect(repeated.importableCount == 0)
            #expect(repeated.history.existing == 3)
            #expect(repeated.favorites.existing == 3)
        }
    }

    @Test func fullHistoryNeverEvictsOnImportAndReaderRetentionStaysNormal() throws {
        try withFiles { sourcePath, targetPath in
            try makeSource(sourcePath)
            let source = try AndroidLibraryImport(exportAt: sourcePath)
            let target = try EhDatabase(storageURL: targetPath)
            try target.insertHistory(HistoryRecord(gid: 1, token: "existing", title: "keep",
                                                   date: Date(timeIntervalSince1970: 1_600_000_000)))
            let full = try target.previewAndroidLibrary(source, historyLimit: 1)
            #expect(full.history == AndroidLibraryImportCounts(new: 0, existing: 1, invalid: 4, overHistoryLimit: 2))
            #expect(try target.importAndroidLibrary(source, historyLimit: 1) == full)
            #expect(try target.getAllHistory().map(\.gid) == [1])

            let withRoom = try target.importAndroidLibrary(source, historyLimit: 2)
            #expect(withRoom.history.new == 1)
            #expect(withRoom.history.overHistoryLimit == 1)
            #expect(try target.getAllHistory().map(\.gid) == [3, 1]) // newer import first

            // Same two calls made on a normal read by ImageReaderView.
            try target.insertHistory(HistoryRecord(gid: 9, token: "fresh", title: "normal read",
                                                   date: Date(timeIntervalSince1970: 1_900_000_000)))
            try target.trimHistory(maxCount: 2)
            #expect(try target.getAllHistory().map(\.gid) == [9, 3])
        }
    }

    @Test func commitRechecksPreviewAndRollsBackBothTablesOnFailure() throws {
        try withFiles { sourcePath, targetPath in
            try makeSource(sourcePath)
            let source = try AndroidLibraryImport(exportAt: sourcePath)
            let target = try EhDatabase(storageURL: targetPath)
            let initial = try target.previewAndroidLibrary(source, historyLimit: 3)
            #expect(initial.importableCount == 6)

            // A simultaneous genuine Apple write between preview and confirmation.
            try target.insertLocalFavorite(LocalFavoriteRecord(gid: 1, token: "fresh", title: "Apple wins"))
            let externalConnection = try DatabaseQueue(path: targetPath.path)
            try externalConnection.write { db in
                try db.execute(sql: """
                    CREATE TRIGGER synthetic_disk_failure BEFORE INSERT ON history
                    BEGIN SELECT RAISE(ABORT, 'simulated constraint failure'); END
                    """)
            }
            #expect(throws: DatabaseError.self) {
                try target.importAndroidLibrary(source, historyLimit: 3)
            }
            #expect(try target.getAllLocalFavorites().map(\.title) == ["Apple wins"])
            #expect(try target.getAllHistory().isEmpty)

            try externalConnection.write { db in try db.execute(sql: "DROP TRIGGER synthetic_disk_failure") }
            let final = try target.importAndroidLibrary(source, historyLimit: 3)
            #expect(final.favorites.existing == 1)
            #expect(final.importableCount == 5)
            #expect(try target.getAllLocalFavorites().filter { $0.gid == 1 }.first?.title == "Apple wins")
        }
    }

    @Test func unsupportedFilesViewsAndWALAreRejected() throws {
        try withFiles { sourcePath, secondPath in
            try Data("not SQLite".utf8).write(to: sourcePath)
            #expect(throws: AndroidLibraryImportError.unsupportedExport) {
                try AndroidLibraryImport(exportAt: sourcePath)
            }
            try makeSource(secondPath, populate: false)
            let connection = try DatabaseQueue(path: secondPath.path)
            try connection.write { db in
                try db.execute(sql: "DROP TABLE HISTORY")
                try db.execute(sql: "CREATE VIEW HISTORY AS SELECT *, 0 AS MODE FROM LOCAL_FAVORITES")
            }
            #expect(throws: AndroidLibraryImportError.unsupportedExport) {
                try AndroidLibraryImport(exportAt: secondPath)
            }
            try connection.inDatabase { db in
                _ = try String.fetchOne(db, sql: "PRAGMA journal_mode = WAL")
            }
            #expect(throws: AndroidLibraryImportError.unsupportedExport) {
                try AndroidLibraryImport(exportAt: secondPath)
            }
        }
    }

    @Test func emptyExportIsValidAndDegradedDatabaseRejectsImport() throws {
        try withFiles { sourcePath, targetPath in
            try makeSource(sourcePath, populate: false)
            let source = try AndroidLibraryImport(exportAt: sourcePath)
            let target = try EhDatabase(storageURL: targetPath)
            #expect(try target.previewAndroidLibrary(source, historyLimit: 100).importableCount == 0)
            let degraded = try EhDatabase(inMemory: true)
            #expect(throws: AndroidLibraryImportError.destinationUnavailable) {
                try degraded.importAndroidLibrary(source, historyLimit: 100)
            }
        }
    }
}
