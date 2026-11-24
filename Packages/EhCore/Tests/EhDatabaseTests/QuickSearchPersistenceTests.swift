import Foundation
import GRDB
import Testing
@testable import EhDatabase

struct QuickSearchPersistenceTests {
    @Test func savedRatingSurvivesReopeningExistingSQLiteTable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("quick-search.sqlite")
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        do {
            let initial = try EhDatabase(storageURL: url)
            let legacy = QuickSearchRecord(name: "legacy", keyword: "Neutral title", date: date)
            try initial.insertQuickSearch(legacy)
        }
        do {
            let existing = try EhDatabase(storageURL: url)
            for rating in 2...5 {
                var selection = QuickSearchRecord(name: "rated \(rating)", category: 2,
                                                  keyword: "Neutral title", date: date)
                selection.minRating = rating
                try existing.insertQuickSearch(selection)
            }
        }

        let reopened = try EhDatabase(storageURL: url)
        let records = try reopened.getAllQuickSearches()
        #expect(records.count == 5)
        #expect(records.first { $0.name == "legacy" }?.minRating == 0)
        for rating in 2...5 {
            let record = try #require(records.first { $0.name == "rated \(rating)" })
            #expect(record.minRating == rating)
            #expect(record.category == 2)
            #expect(record.keyword == "Neutral title")
            #expect(record.advanceSearch == 0)
            #expect(record.pageFrom == 0)
            #expect(record.pageTo == 0)
        }
    }
    @Test func migrationPreservesLegacyRowsAndStoresFullSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("v3.sqlite")
        do {
            let legacy = try DatabaseQueue(path: url.path)
            try EhDatabaseSchema.makeMigrator().migrate(legacy, upTo: "v3")
            try legacy.write { db in
                try db.execute(sql: """
                    INSERT INTO quickSearch (name, mode, category, keyword, minRating, pageFrom, pageTo, date)
                    VALUES ('legacy', 5, 4, '', 3, 20, 60, 1700000000)
                    """)
            }
            #expect(try legacy.read { db in
                try QuickSearchRecord.fetchOne(db)?.browseSnapshotVersion == nil
            })
        }

        let database = try EhDatabase(storageURL: url)
        let legacy = try #require(database.getAllQuickSearches().first)
        #expect(legacy.keyword == "")
        #expect(legacy.browseSnapshotVersion == nil)
        #expect(legacy.mode == 5)

        var snapshot = QuickSearchRecord(name: "snapshot", mode: 5, category: 4, keyword: "neutral",
            date: Date(timeIntervalSince1970: 1_700_001_000))
        snapshot.browseSnapshotVersion = 1
        snapshot.advanceSearch = 0x104
        snapshot.minRating = 4
        snapshot.pageFrom = 20
        snapshot.pageTo = 60
        try database.insertQuickSearch(snapshot)

        let reopened = try EhDatabase(storageURL: url)
        let records = try reopened.getAllQuickSearches()
        var restored = try #require(records.first { $0.name == "snapshot" })
        restored.id = nil
        #expect(restored == snapshot)
    }
}
