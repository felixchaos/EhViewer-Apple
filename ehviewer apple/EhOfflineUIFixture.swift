// Never present in a normal build. An explicit simulator build is required.
#if EH_OFFLINE_UI_FIXTURE && targetEnvironment(simulator)
import Foundation
import SwiftUI
import UIKit
import EhDownload
import EhDatabase
import EhModels
import EhSettings
import EhSpider
import SQLite3

@MainActor
enum EhOfflineUIFixture {
    static let enabled = ProcessInfo.processInfo.environment["EH_OFFLINE_UI_FIXTURE"] == "1"
    static let volumePagingFixture = enabled && ProcessInfo.processInfo.environment["EH_FIXTURE_VOLUME_PAGING"] == "1"
    static let tallVolumeFixture = volumePagingFixture && ProcessInfo.processInfo.environment["EH_FIXTURE_TALL_VOLUME"] == "1"
    static let readerGestureFixture = enabled && ProcessInfo.processInfo.environment["EH_FIXTURE_READER_GESTURES"] == "1"
    static let verticalGestureFixture = readerGestureFixture && ProcessInfo.processInfo.environment["EH_FIXTURE_VERTICAL_GESTURES"] == "1"
    static let readerEnabled = ProcessInfo.processInfo.environment["EH_FIXTURE_LOCAL_READER"] == "1"
    static let encodedExportFixture = ProcessInfo.processInfo.environment["EH_FIXTURE_ENCODED_EXPORT"] == "1"
    static let readerLoadingMode: String? = {
        guard enabled, let mode = ProcessInfo.processInfo.environment["EH_FIXTURE_READER_LOADING"],
              ["spread", "spread-reverse", "spread-error", "vertical", "horizontal"].contains(mode) else { return nil }
        return mode
    }()
    static let synthetic = GalleryInfo(
        gid: verticalGestureFixture ? 900010000036 : (readerGestureFixture ? 900010000035 : (tallVolumeFixture ? 900010000034
            : (readerLoadingMode != nil ? 900010000033 : (encodedExportFixture ? 900010000031 : 900010000001)))),
        token: "fixture", title: "Synthetic Gallery", pages: readerEnabled ? 3 : 0
    )
    static let workspaceFixture = enabled && ProcessInfo.processInfo.environment["EH_FIXTURE_WORKSPACES"] == "1"
    static let workspaceA = "artist:fixture first"
    static let workspaceB = "group:fixture second"
    static let workspaceCloudGid: Int64 = 900010010120
    static let workspaceLocalGid: Int64 = 900010010121

    static let cloud = GalleryInfo(gid: 900010000002, token: "fixture", title: "Synthetic Cloud Gallery", favoriteSlot: 0)

    private static let coldReaderMode = ProcessInfo.processInfo.environment["EH_FIXTURE_DIRECT_COLD"]
    private static let coldGallery = GalleryInfo(
        gid: 900010000030, token: "fixture", title: "First visit fixture", pages: 3
    )
    private static let missingCountGallery = GalleryInfo(
        gid: 900010000032, token: "fixture", title: "Missing page count fixture"
    )
    private static let previousGallery = GalleryInfo(
        gid: 900010000031, token: "fixture", title: "Previous visit fixture", pages: 3
    )

    private static func seedColdReader() {
        guard let mode = coldReaderMode else { return }
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "reader_tutorial_shown")
        if mode == "reset" || mode == "missing-reset" || mode == "scrolled-reset" {
            let gallery = mode == "missing-reset" ? missingCountGallery : coldGallery
            try? EhDatabase.shared.deleteHistory(gid: gallery.gid)
            try? EhDatabase.shared.deleteLocalFavorite(gid: gallery.gid)
            defaults.removeObject(forKey: "reading_progress_\(gallery.gid)")
            try? EhDatabase.shared.insertHistory(.init(gid: previousGallery.gid, token: previousGallery.token,
                                                       title: previousGallery.title ?? "", pages: 3, date: Date()))
            defaults.set(previousGallery.gid, forKey: "eh_last_reading_gid")
            defaults.set(Date().timeIntervalSince1970, forKey: "eh_last_reading_time")
            defaults.set(0, forKey: "reading_progress_\(previousGallery.gid)")
        }
        // Feed numbered images without creating a download or detail record.
        let directory = FileManager.default.temporaryDirectory
        for index in 0..<3 {
            let path = directory.appendingPathComponent("cold-reader-page-\(index).png")
            let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 180)).image { context in
                UIColor.systemBlue.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 120, height: 180))
                String(index + 1).draw(at: CGPoint(x: 32, y: 50), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 42), .foregroundColor: UIColor.white
                ])
            }
            if let bytes = image.pngData(), (try? bytes.write(to: path, options: .atomic)) != nil {
                for gallery in [coldGallery, previousGallery, missingCountGallery] {
                    GalleryCache.shared.putImageURL(path.absoluteString, gid: gallery.gid, page: index)
                }
            }
        }
    }

    // Keep this UI test independent of other synthetic scenarios on a reused simulator.
    static var downloadSortIDs: Set<Int64>? {
        guard enabled, ProcessInfo.processInfo.environment["EH_FIXTURE_DOWNLOAD_SORT"] == "1" else { return nil }
        return [900010000025, 900010000026]
    }

    static var downloadSortArchiveTitle: String? {
        guard downloadSortIDs != nil,
              let id = ProcessInfo.processInfo.environment["EH_FIXTURE_IMAGE_ARCHIVE"],
              UUID(uuidString: id) != nil else { return nil }
        return "image-fixture-" + id
    }

    private static let favoriteConflictEnabled =
        ProcessInfo.processInfo.environment["EH_FIXTURE_FAVORITE_DOWNLOAD_CONFLICT"] == "1"
    private static let retainedFavorite = GalleryInfo(gid: 900010000110, token: "fixture",
                                                      title: "Retained favorite fixture", pages: 1, favoriteSlot: 0)
    private static let cleanFavorite = GalleryInfo(gid: 900010000111, token: "fixture",
                                                   title: "Clean favorite fixture", pages: 1, favoriteSlot: 0)

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
        if ProcessInfo.processInfo.environment["EH_FIXTURE_READ_CACHE_LIMIT"] == "1" {
            seedReadingCacheLimit()
        }
        seedColdReader()
        AppSettings.shared.recentFavCat = -1
        AppSettings.shared.defaultFavSlot = -1
        let fixturePage = ProcessInfo.processInfo.environment["EH_FIXTURE_LAUNCH_PAGE"].flatMap(Int.init) ?? 0
        AppSettings.shared.launchPage = (0...5).contains(fixturePage) ? fixturePage : 0
        try? EhDatabase.shared.deleteLocalFavorite(gid: synthetic.gid)
        try? EhDatabase.shared.deleteLocalFavorite(gid: cloud.gid)
        if ProcessInfo.processInfo.environment["EH_FIXTURE_STATIC_PREVIEWS"] == "1" {
            let previews = (0..<3).map { position in
                LargePreview(position: position, imageUrl: previewFixtureURL(position).absoluteString)
            }
            GalleryCache.shared.putDetail(.init(info: synthetic, previewPages: 1, previewSet: .large(previews)))
        } else if ProcessInfo.processInfo.environment["EH_FIXTURE_LONG_DETAIL_TAGS"] == "1" {
            let longTag = String(repeating: "fixture long tag ", count: 8) + "end"
            let tags = ["fixture before long tag", longTag, "fixture after long tag"]
                + (1...20).map { "fixture tag \($0)" }
            GalleryCache.shared.putDetail(.init(info: synthetic, tags: [.init(groupName: "artist", tags: tags)]))
        } else {
            GalleryCache.shared.putDetail(.init(info: synthetic))
        }
        GalleryCache.shared.putDetail(.init(info: cloud, isFavorited: true))
        if historyTagFixtureEnabled {
            try? EhDatabase.shared.insertHistory(.init(gid: historyGallery.gid, token: historyGallery.token,
                                                       title: historyGallery.title ?? "", date: Date()))
            GalleryCache.shared.putDetail(.init(info: historyGallery,
                                                 tags: [.init(groupName: "artist", tags: [historyTag])]))
            var matching = HistoryRecord(gid: historyTagResult.gid, token: historyTagResult.token,
                                         title: historyTagResult.bestTitle, date: Date().addingTimeInterval(-60))
            matching.simpleTags = ["a:\(historyTag)"]
            try? EhDatabase.shared.insertHistory(matching)
            GalleryCache.shared.putDetail(.init(info: historyTagResult))
        } else {
            try? EhDatabase.shared.deleteHistory(gid: historyTagResult.gid)
        }
        if ProcessInfo.processInfo.environment["EH_FIXTURE_RETAINED_DOWNLOAD"] == "1" {
            seedRetainedDownload()
        }
        for gallery in [retainedFavorite, cleanFavorite] {
            try? EhDatabase.shared.deleteLocalFavorite(gid: gallery.gid)
            if favoriteConflictEnabled {
                try? EhDatabase.shared.deleteDownload(gid: gallery.gid)
                try? EhDatabase.shared.insertLocalFavorite(
                    .init(gid: gallery.gid, token: gallery.token, title: gallery.bestTitle, pages: gallery.pages)
                )
            }
        }
        if favoriteConflictEnabled { seedRetainedDownloadFiles(for: retainedFavorite) }
        try? EhDatabase.shared.deleteLocalFavorite(gid: workspaceLocalGid)
        if workspaceFixture {
            var local = LocalFavoriteRecord(gid: workspaceLocalGid, token: "fixture", title: "Workspace local favorite")
            local.simpleTags = [workspaceA, workspaceB]
            try? EhDatabase.shared.insertLocalFavorite(local)
        }
        if let identifier = ProcessInfo.processInfo.environment["EH_FIXTURE_IMAGE_FOLDER"],
           UUID(uuidString: identifier) != nil {
            seedImageFolder(identifier: identifier)
        }
        if let identifier = ProcessInfo.processInfo.environment["EH_FIXTURE_IMAGE_ARCHIVE"],
           UUID(uuidString: identifier) != nil {
            seedImageArchive(identifier: identifier)
        }
        if let identifier = ProcessInfo.processInfo.environment["EH_FIXTURE_IMPORT"],
           UUID(uuidString: identifier) != nil {
            seedImportScenario(identifier: identifier)
        }
    }

    private static func seedReadingCacheLimit() {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("spider_image", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("fixture-live-cache-limit")
            try Data().write(to: file, options: .atomic)
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 41 * 1024 * 1024)
            AppSettings.shared.readCacheSize = 80
            SpiderDen.initialize()
        } catch {
            print("[OfflineFixture] Failed to seed cache limit: \(error)")
        }
    }

    private static func seedRetainedDownload() {
        let gallery = GalleryInfo(gid: 900010000109, token: "fixture", title: "Retained quality fixture", pages: 1)
        seedRetainedDownloadFiles(for: gallery)
        try? EhDatabase.shared.insertHistory(.init(gid: gallery.gid, token: gallery.token,
                                                   title: gallery.bestTitle, pages: gallery.pages, date: Date()))
        GalleryCache.shared.putDetail(.init(info: gallery))
    }

    private static func seedRetainedDownloadFiles(for gallery: GalleryInfo) {
        let directory = DownloadManager.shared.galleryDirectory(gid: gallery.gid, title: gallery.bestTitle)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 96)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 96))
        }
        try? EhDatabase.shared.deleteDownload(gid: gallery.gid)
        try? SpiderInfoFile.write(.init(gid: gallery.gid, token: gallery.token, pages: gallery.pages), to: directory)
        try? image.pngData()?.write(to: directory.appendingPathComponent("00000001.png"), options: .atomic)

    }

    static func previewFixtureURL(_ index: Int) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("static-preview-fixture-\(index).png")
    }

    static func interceptPreview(_ url: URL) -> Bool {
        enabled && ProcessInfo.processInfo.environment["EH_FIXTURE_STATIC_PREVIEWS"] == "1"
            && (0..<3).contains { previewFixtureURL($0) == url }
    }

    static func seedReaderFiles() async -> Bool {
        if encodedExportFixture || volumePagingFixture || readerGestureFixture { AppSettings.shared.volumePage = false }
        if volumePagingFixture {
            AppSettings.shared.reverseVolumePage = false
        }
        UserDefaults.standard.set(true, forKey: "reader_tutorial_shown")
        let progressKey = "reading_progress_\(synthetic.gid)"
        if tallVolumeFixture {
            UserDefaults.standard.set(2, forKey: progressKey)
        } else if readerLoadingMode?.hasPrefix("spread") == true || ProcessInfo.processInfo.environment["EH_FIXTURE_SAVED_READER_PAGE"] == "1" {
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
            let height: CGFloat = verticalGestureFixture ? 520 : (tallVolumeFixture && page == 2 ? 1_440 : 180)
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 120, height: height))
            let image = renderer.image { ctx in
                color.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 120, height: height))
                if height > 180 {
                    for band in 0..<Int(ceil(height / 180)) {
                        [UIColor.systemBlue, .systemGreen, .systemPurple][band % 3].setFill()
                        ctx.fill(CGRect(x: 0, y: CGFloat(band * 180), width: 120, height: 180))
                        String(band + 1).draw(at: CGPoint(x: 36, y: band * 180 + 66), withAttributes: [
                            .font: UIFont.systemFont(ofSize: 42), .foregroundColor: UIColor.white
                        ])
                    }
                }
                String(page + 1).draw(at: CGPoint(x: 30, y: 50), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 48), .foregroundColor: UIColor.white
                ])
            }
            let isEncodedExportPage = encodedExportFixture && page == 0
            let sample = isEncodedExportPage ? image.jpegData(compressionQuality: 0.71) : image.pngData()
            guard let bytes = sample else { return false }
            if isEncodedExportPage,
               let id = ProcessInfo.processInfo.environment["EH_FIXTURE_EXPORT_DESTINATION"],
               UUID(uuidString: id) != nil {
                do {
                    let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                                appropriateFor: nil, create: true)
                    try FileManager.default.createDirectory(
                        at: documents.appendingPathComponent("export-fixture-" + id, isDirectory: true),
                        withIntermediateDirectories: false
                    )
                    try bytes.write(to: FileManager.default.temporaryDirectory
                        .appendingPathComponent("export-reference-" + id + ".jpg"), options: .atomic)
                } catch { return false }
            }
            await manager.saveWhileReading(gallery: completed, pageIndex: page, data: bytes,
                                           extension: isEncodedExportPage ? ".jpg" : ".png")
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

    // Reused simulator fixtures can otherwise scroll the unique input out of
    // the Files provider's accessibility realization window on later runs.
    private static func removeOldImageFixtures(in documents: URL, prefix: String, extension suffix: String) {
        let manager = FileManager.default
        for item in (try? manager.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil)) ?? [] {
            let name = item.deletingPathExtension().lastPathComponent
            guard item.pathExtension == suffix, name.hasPrefix(prefix),
                  UUID(uuidString: String(name.dropFirst(prefix.count))) != nil else { continue }
            try? manager.removeItem(at: item)
        }
    }

    private static func seedImageFolder(identifier: String) {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        removeOldImageFixtures(in: documents, prefix: "folder-fixture-", extension: "")
        let folder = documents.appendingPathComponent("folder-fixture-" + identifier, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 1...2 {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 90, height: 140)).image { ctx in
                (index == 1 ? UIColor.systemBlue : .systemGreen).setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 90, height: 140))
                String(index).draw(at: CGPoint(x: 22, y: 35), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 43), .foregroundColor: UIColor.white
                ])
            }
            try? image.pngData()?.write(to: folder.appendingPathComponent("\(index).png"), options: .atomic)
        }
    }

    private static func seedImageArchive(identifier: String) {
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let archive = Data(base64Encoded: "UEsDBBQAAAAIAAAAIVgx0+jTUgAAAF8AAAAGAAAAMTAucG5n6wzwc+flkuJiYGDg9fRwCQLSEkCswsEEJGXW5lYCKTVPF8eQijnJDyZFO4geMci6sMJxMVuvlAkSw8OQg6Hh7WL5DKH0RUAdDJ6ufi7rnBKaAFBLAwQUAAAACAAAACFYdmUcWVMAAABfAAAABQAAADIucG5n6wzwc+flkuJiYGDg9fRwCQLSEkCswsEEJGXW5lYCKTVPF8eQijnJN9SXO4oeMci6sMJxMVuvlAkSw8OQg0F8Zu66Gc7RV4A6GDxd/VzWOSU0AQBQSwECFAMUAAAACAAAACFYMdPo01IAAABfAAAABgAAAAAAAAAAAAAAgAEAAAAAMTAucG5nUEsBAhQDFAAAAAgAAAAhWHZlHFlTAAAAXwAAAAUAAAAAAAAAAAAAAIABdgAAADIucG5nUEsFBgAAAAACAAIAZwAAAOwAAAAAAA==") else { return }
        removeOldImageFixtures(in: directory, prefix: "image-fixture-", extension: "cbz")
        // Two tiny synthetic PNGs stored as normal ZIP DEFLATE members.
        try? archive.write(to: directory.appendingPathComponent("image-fixture-" + identifier + ".cbz"),
                           options: .atomic)
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
        if workspaceFixture, let components = URLComponents(string: url) {
            let items = components.queryItems ?? []
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
            let first = "artist:\"fixture first$\""
            let second = "group:\"fixture second$\""
            if components.path == "/favorites.php" {
                guard value("favcat") == "0" else { return GalleryListResult() }
                if favoriteConflictEnabled {
                    return GalleryListResult(galleries: [retainedFavorite, cleanFavorite])
                }
                if let term = value("f_search") {
                    guard value("st") == "on", term.contains(first) else {
                        return GalleryListResult(galleries: [.init(title: "Incorrect favorites request")])
                    }
                    if term.contains(second) {
                        return GalleryListResult(galleries: [
                            .init(gid: workspaceCloudGid + 10, token: "fixture", title: "Workspace narrowed both tags")
                        ])
                    }
                    if value("next") == "fixture-scope" {
                        return GalleryListResult(galleries: [
                            .init(gid: workspaceCloudGid + 2, token: "fixture",
                                  title: "Workspace retained cursor", simpleTags: [workspaceB])
                        ])
                    }
                    // Intentionally omit slot and tag values from the supplied
                    // cursor. The workspace must reattach them before use.
                    return GalleryListResult(galleries: [
                        .init(gid: workspaceCloudGid + 1, token: "fixture",
                              title: "Workspace cloud first layer", simpleTags: [workspaceB])
                    ], pages: -1, nextHref: "https://e-hentai.org/favorites.php?next=fixture-scope")
                }
                return GalleryListResult(galleries: [
                    .init(gid: workspaceCloudGid, token: "fixture",
                          title: "Workspace cloud origin", simpleTags: [workspaceA, workspaceB], favoriteSlot: 0)
                ])
            }
            if value("f_search")?.contains(first) == true {
                return GalleryListResult(galleries: [.init(title: "Unexpected global workspace request")])
            }
        }
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
            let gallery = if coldReaderMode?.hasPrefix("missing-") == true {
                missingCountGallery
            } else {
                coldReaderMode == nil ? synthetic : coldGallery
            }
            if coldReaderMode == "scrolled-reset" {
                let fillers = (0..<12).map { index in
                    GalleryInfo(gid: 900010000150 + Int64(index), token: "fixture",
                                title: "Resume list filler \(index)", pages: 3)
                }
                return GalleryListResult(galleries: Array(fillers.prefix(8)) + [gallery] + Array(fillers.dropFirst(8)))
            }
            return GalleryListResult(galleries: [gallery])
        }
    }
}

/// Scoped to the opt-in simulator session. No request in it leaves the app.
final class EhOfflineReaderMetadataProtocol: URLProtocol, @unchecked Sendable {
    private final class AttemptCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func advance() -> Int {
            lock.withLock {
                count += 1
                return count
            }
        }
    }

    private static let attempts = AttemptCounter()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.pathComponents.filter({ $0 != "/" }) == ["g", "900010000032", "fixture"] else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let first = Self.attempts.advance() == 1
        guard let response = HTTPURLResponse(url: url, statusCode: first ? 503 : 200,
                                             httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Even an HTTP error page may contain a page-count-like string.
        client?.urlProtocol(self, didLoad: Data((first ? "Service busy, 99 pages" : "3 pages").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
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
