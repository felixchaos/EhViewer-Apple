import Foundation
import GRDB
import EhModels

// MARK: - 数据库管理器 (对应 Android EhDB.java + GreenDAO)
// 使用 GRDB.swift 替代 Android GreenDAO

public final class EhDatabase: Sendable {
    public static let shared: EhDatabase = {
        do {
            return try EhDatabase()
        } catch {
            // 数据库初始化失败时备份旧数据库后重建
            print("[EhDatabase] 初始化失败: \(error)，尝试备份并重建...")
            let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let dbPath = docsDir.appendingPathComponent("eh.sqlite").path

            // 备份损坏的数据库（保留最近一次，用户可自行恢复）
            let backupPath = docsDir.appendingPathComponent("eh.sqlite.corrupted_backup").path
            try? FileManager.default.removeItem(atPath: backupPath) // 清理旧备份
            try? FileManager.default.copyItem(atPath: dbPath, toPath: backupPath)
            // 同时备份 WAL 和 SHM 文件
            try? FileManager.default.copyItem(atPath: dbPath + "-wal", toPath: backupPath + "-wal")
            try? FileManager.default.copyItem(atPath: dbPath + "-shm", toPath: backupPath + "-shm")
            print("[EhDatabase] 已备份损坏数据库至 eh.sqlite.corrupted_backup")

            // 删除原数据库及附属文件
            try? FileManager.default.removeItem(atPath: dbPath)
            try? FileManager.default.removeItem(atPath: dbPath + "-wal")
            try? FileManager.default.removeItem(atPath: dbPath + "-shm")

            do {
                return try EhDatabase()
            } catch {
                // 二次失败也不 fatalError（可能磁盘满），返回内存数据库作为降级模式
                print("[EhDatabase] ⚠️ 重建仍失败: \(error)，使用内存数据库降级运行")
                do {
                    return try EhDatabase(inMemory: true)
                } catch {
                    // 内存数据库也失败的唯一可能是 migrate 代码本身有 bug
                    fatalError("[EhDatabase] 内存数据库初始化失败，这是代码 bug: \(error)")
                }
            }
        }
    }()

    /// 标记是否处于降级模式（内存数据库，重启后数据丢失）
    public let isDegraded: Bool

    private let dbQueue: DatabaseQueue

    private init(inMemory: Bool = false) throws {
        self.isDegraded = inMemory

        var config = Configuration()

        // 启用 WAL 模式: 更好的写入性能 + 崩溃恢复能力
        if !inMemory {
            config.prepareDatabase { db in
                try db.execute(sql: "PRAGMA journal_mode=WAL")
            }
        }

        #if DEBUG
        config.prepareDatabase { db in
            db.trace { print("SQL: \($0)") }
        }
        #endif

        if inMemory {
            dbQueue = try DatabaseQueue(configuration: config)
        } else {
            let dbPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
                .first!.appendingPathComponent("eh.sqlite").path
            dbQueue = try DatabaseQueue(path: dbPath, configuration: config)
        }
        try migrator.migrate(dbQueue)
    }

    // MARK: - Schema 迁移

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            // 下载记录表 (对应 Android DownloadsDao)
            try db.create(table: "download") { t in
                t.primaryKey("gid", .integer)
                t.column("token", .text).notNull()
                t.column("title", .text).notNull()
                t.column("titleJpn", .text)
                t.column("thumb", .text)
                t.column("category", .integer).notNull().defaults(to: 0)
                t.column("posted", .text)
                t.column("uploader", .text)
                t.column("rating", .real).defaults(to: 0)
                t.column("simpleLanguage", .text)
                t.column("pages", .integer).defaults(to: 0)
                t.column("state", .integer).notNull().defaults(to: 0)
                t.column("legacy", .integer).notNull().defaults(to: 0)
                t.column("date", .integer).notNull()
                t.column("label", .text)
            }

            // 下载标签表 (对应 Android DownloadLabelDao)
            try db.create(table: "downloadLabel") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("label", .text).notNull().unique()
                t.column("date", .integer).notNull()
            }

            // 浏览历史表 (对应 Android HistoryDao)
            try db.create(table: "history") { t in
                t.primaryKey("gid", .integer)
                t.column("token", .text).notNull()
                t.column("title", .text).notNull()
                t.column("titleJpn", .text)
                t.column("thumb", .text)
                t.column("category", .integer).notNull().defaults(to: 0)
                t.column("posted", .text)
                t.column("uploader", .text)
                t.column("rating", .real).defaults(to: 0)
                t.column("simpleLanguage", .text)
                t.column("pages", .integer).defaults(to: 0)
                t.column("mode", .integer).notNull().defaults(to: 0)
                t.column("date", .integer).notNull()
            }

            // 本地收藏表 (对应 Android LocalFavoritesDao)
            try db.create(table: "localFavorite") { t in
                t.primaryKey("gid", .integer)
                t.column("token", .text).notNull()
                t.column("title", .text).notNull()
                t.column("titleJpn", .text)
                t.column("thumb", .text)
                t.column("category", .integer).notNull().defaults(to: 0)
                t.column("posted", .text)
                t.column("uploader", .text)
                t.column("rating", .real).defaults(to: 0)
                t.column("simpleLanguage", .text)
                t.column("pages", .integer).defaults(to: 0)
                t.column("date", .integer).notNull()
            }

            // 快速搜索表 (对应 Android QuickSearchDao)
            try db.create(table: "quickSearch") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text)
                t.column("mode", .integer).notNull()
                t.column("category", .integer).notNull()
                t.column("keyword", .text)
                t.column("advanceSearch", .integer).notNull().defaults(to: 0)
                t.column("minRating", .integer).notNull().defaults(to: 0)
                t.column("pageFrom", .integer).notNull().defaults(to: 0)
                t.column("pageTo", .integer).notNull().defaults(to: 0)
                t.column("date", .integer).notNull()
            }

            // 过滤器表 (对应 Android FilterDao)
            try db.create(table: "filter") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("mode", .integer).notNull()
                t.column("text", .text)
                t.column("enable", .boolean).notNull().defaults(to: true)
                t.column("date", .integer).notNull()
            }
        }

        migrator.registerMigration("v2") { db in
            // 黑名单表 (对应 Android BlackListDao)
            try db.create(table: "blackList") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("badgayname", .text).notNull().indexed()
                t.column("reason", .text)
                t.column("angrywith", .text)
                t.column("addTime", .text)
                t.column("mode", .integer)
            }

            // 阅读书签表 (对应 Android BookmarksBao)
            try db.create(table: "bookmark") { t in
                t.primaryKey("gid", .integer)
                t.column("token", .text).notNull()
                t.column("title", .text).notNull()
                t.column("titleJpn", .text)
                t.column("thumb", .text)
                t.column("category", .integer).notNull().defaults(to: 0)
                t.column("posted", .text)
                t.column("uploader", .text)
                t.column("rating", .real).defaults(to: 0)
                t.column("simpleLanguage", .text)
                t.column("pages", .integer).defaults(to: 0)
                t.column("page", .integer).notNull().defaults(to: 0)
                t.column("date", .integer).notNull()
            }

            // 下载目录名映射表 (对应 Android DownloadDirnameDao)
            try db.create(table: "downloadDirname") { t in
                t.primaryKey("gid", .integer)
                t.column("dirname", .text).notNull()
            }

            // 画廊标签缓存表 (对应 Android GalleryTagsDao)
            try db.create(table: "galleryTags") { t in
                t.primaryKey("gid", .integer)
                t.column("rows", .text)
                t.column("artist", .text)
                t.column("cosplayer", .text)
                t.column("character", .text)
                t.column("female", .text)
                t.column("group", .text)
                t.column("language", .text)
                t.column("male", .text)
                t.column("misc", .text)
                t.column("mixed", .text)
                t.column("other", .text)
                t.column("parody", .text)
                t.column("reclass", .text)
                t.column("createTime", .datetime)
                t.column("updateTime", .datetime)
            }
        }

        return migrator
    }

    // MARK: - 下载操作

    public func insertDownload(_ info: DownloadRecord) throws {
        try dbQueue.write { db in
            try info.insert(db)
        }
    }

    public func getAllDownloads() throws -> [DownloadRecord] {
        try dbQueue.read { db in
            try DownloadRecord.order(Column("date").desc).fetchAll(db)
        }
    }

    public func getDownload(gid: Int64) throws -> DownloadRecord? {
        try dbQueue.read { db in
            try DownloadRecord.fetchOne(db, key: gid)
        }
    }

    public func updateDownloadState(gid: Int64, state: Int) throws {
        try dbQueue.write { db in
            if var record = try DownloadRecord.fetchOne(db, key: gid) {
                record.state = state
                try record.update(db)
            }
        }
    }

    public func deleteDownload(gid: Int64) throws {
        try dbQueue.write { db in
            _ = try DownloadRecord.deleteOne(db, key: gid)
        }
    }

    // MARK: - 历史记录操作

    public func insertHistory(_ record: HistoryRecord) throws {
        try dbQueue.write { db in
            try record.save(db)  // INSERT OR REPLACE
        }
    }

    public func getAllHistory(limit: Int = 100) throws -> [HistoryRecord] {
        try dbQueue.read { db in
            try HistoryRecord.order(Column("date").desc).limit(limit).fetchAll(db)
        }
    }

    public func deleteHistory(gid: Int64) throws {
        try dbQueue.write { db in
            _ = try HistoryRecord.deleteOne(db, key: gid)
        }
    }

    public func clearHistory() throws {
        try dbQueue.write { db in
            _ = try HistoryRecord.deleteAll(db)
        }
    }

    /// 限制历史记录数量 (对齐 Android Settings.getHistoryInfoSize() / EhDB.trimHistory)
    public func trimHistory(maxCount: Int) throws {
        try dbQueue.write { db in
            let total = try HistoryRecord.fetchCount(db)
            if total > maxCount {
                // 删除最旧的多余记录
                let excess = total - maxCount
                let oldest = try HistoryRecord
                    .order(Column("date").asc)
                    .limit(excess)
                    .fetchAll(db)
                for record in oldest {
                    _ = try HistoryRecord.deleteOne(db, key: record.gid)
                }
            }
        }
    }

    // MARK: - 本地收藏操作

    public func insertLocalFavorite(_ record: LocalFavoriteRecord) throws {
        try dbQueue.write { db in
            try record.save(db)
        }
    }

    public func getAllLocalFavorites() throws -> [LocalFavoriteRecord] {
        try dbQueue.read { db in
            try LocalFavoriteRecord.order(Column("date").desc).fetchAll(db)
        }
    }

    public func deleteLocalFavorite(gid: Int64) throws {
        try dbQueue.write { db in
            _ = try LocalFavoriteRecord.deleteOne(db, key: gid)
        }
    }

    // MARK: - 快速搜索操作

    public func getAllQuickSearches() throws -> [QuickSearchRecord] {
        try dbQueue.read { db in
            try QuickSearchRecord.order(Column("date").asc).fetchAll(db)
        }
    }

    public func insertQuickSearch(_ record: QuickSearchRecord) throws {
        try dbQueue.write { db in
            try record.insert(db)
        }
    }

    public func deleteQuickSearch(id: Int64) throws {
        try dbQueue.write { db in
            _ = try QuickSearchRecord.deleteOne(db, key: id)
        }
    }

    // MARK: - 下载标签操作

    public func getAllDownloadLabels() throws -> [DownloadLabelRecord] {
        try dbQueue.read { db in
            try DownloadLabelRecord.order(Column("date").asc).fetchAll(db)
        }
    }

    public func insertDownloadLabel(_ label: String) throws {
        try dbQueue.write { db in
            var record = DownloadLabelRecord(label: label, date: Date())
            try record.insert(db)
        }
    }

    // MARK: - 过滤器操作

    public func getAllFilters() throws -> [FilterRecord] {
        try dbQueue.read { db in
            try FilterRecord.fetchAll(db)
        }
    }

    public func insertFilter(_ record: FilterRecord) throws {
        try dbQueue.write { db in
            try record.insert(db)
        }
    }

    public func deleteFilter(id: Int64) throws {
        try dbQueue.write { db in
            _ = try FilterRecord.deleteOne(db, key: id)
        }
    }

    public func triggerFilter(id: Int64) throws {
        try dbQueue.write { db in
            if var record = try FilterRecord.fetchOne(db, key: id) {
                record.enable.toggle()
                try record.update(db)
            }
        }
    }

    // MARK: - 下载标签操作 (补全)

    public func updateDownloadLabel(_ record: DownloadLabelRecord) throws {
        try dbQueue.write { db in
            try record.update(db)
        }
    }

    public func deleteDownloadLabel(id: Int64) throws {
        try dbQueue.write { db in
            _ = try DownloadLabelRecord.deleteOne(db, key: id)
        }
    }

    // MARK: - 快速搜索操作 (补全)

    public func updateQuickSearch(_ record: QuickSearchRecord) throws {
        try dbQueue.write { db in
            try record.update(db)
        }
    }

    public func insertQuickSearchList(_ records: [QuickSearchRecord]) throws {
        try dbQueue.write { db in
            for var record in records {
                try record.insert(db)
            }
        }
    }

    // MARK: - 下载操作 (补全)

    public func deleteAllDownloads() throws {
        try dbQueue.write { db in
            _ = try DownloadRecord.deleteAll(db)
        }
    }

    public func updateDownload(_ record: DownloadRecord) throws {
        try dbQueue.write { db in
            try record.update(db)
        }
    }

    // MARK: - 本地收藏操作 (补全)

    public func containsLocalFavorite(gid: Int64) throws -> Bool {
        try dbQueue.read { db in
            try LocalFavoriteRecord.fetchOne(db, key: gid) != nil
        }
    }

    public func searchLocalFavorites(query: String) throws -> [LocalFavoriteRecord] {
        try dbQueue.read { db in
            try LocalFavoriteRecord
                .filter(Column("title").like("%\(query)%") || Column("titleJpn").like("%\(query)%"))
                .order(Column("date").desc)
                .fetchAll(db)
        }
    }

    public func getLocalFavorite(gid: Int64) throws -> LocalFavoriteRecord? {
        try dbQueue.read { db in
            try LocalFavoriteRecord.fetchOne(db, key: gid)
        }
    }

    // MARK: - 历史记录操作 (补全)

    public func countHistory() throws -> Int {
        try dbQueue.read { db in
            try HistoryRecord.fetchCount(db)
        }
    }

    public func searchHistory(query: String) throws -> [HistoryRecord] {
        try dbQueue.read { db in
            try HistoryRecord
                .filter(Column("title").like("%\(query)%") || Column("titleJpn").like("%\(query)%"))
                .order(Column("date").desc)
                .fetchAll(db)
        }
    }

    // MARK: - 黑名单操作

    public func getAllBlackList() throws -> [BlackListRecord] {
        try dbQueue.read { db in
            try BlackListRecord.fetchAll(db)
        }
    }

    public func inBlackList(name: String) throws -> Bool {
        try dbQueue.read { db in
            try BlackListRecord.filter(Column("badgayname") == name).fetchCount(db) > 0
        }
    }

    public func insertBlackList(_ record: BlackListRecord) throws {
        try dbQueue.write { db in
            try record.insert(db)
        }
    }

    public func deleteBlackList(id: Int64) throws {
        try dbQueue.write { db in
            _ = try BlackListRecord.deleteOne(db, key: id)
        }
    }

    // MARK: - 阅读书签操作

    public func getAllBookmarks() throws -> [BookmarkRecord] {
        try dbQueue.read { db in
            try BookmarkRecord.order(Column("date").desc).fetchAll(db)
        }
    }

    public func getBookmark(gid: Int64) throws -> BookmarkRecord? {
        try dbQueue.read { db in
            try BookmarkRecord.fetchOne(db, key: gid)
        }
    }

    public func insertBookmark(_ record: BookmarkRecord) throws {
        try dbQueue.write { db in
            try record.save(db)
        }
    }

    public func deleteBookmark(gid: Int64) throws {
        try dbQueue.write { db in
            _ = try BookmarkRecord.deleteOne(db, key: gid)
        }
    }

    // MARK: - 下载目录名映射操作

    public func getDownloadDirname(gid: Int64) throws -> String? {
        try dbQueue.read { db in
            try DownloadDirnameRecord.fetchOne(db, key: gid)?.dirname
        }
    }

    public func putDownloadDirname(gid: Int64, dirname: String) throws {
        try dbQueue.write { db in
            let record = DownloadDirnameRecord(gid: gid, dirname: dirname)
            try record.save(db)
        }
    }

    public func removeDownloadDirname(gid: Int64) throws {
        try dbQueue.write { db in
            _ = try DownloadDirnameRecord.deleteOne(db, key: gid)
        }
    }

    public func clearDownloadDirnames() throws {
        try dbQueue.write { db in
            _ = try DownloadDirnameRecord.deleteAll(db)
        }
    }

    // MARK: - 画廊标签缓存操作

    public func getGalleryTags(gid: Int64) throws -> GalleryTagsRecord? {
        try dbQueue.read { db in
            try GalleryTagsRecord.fetchOne(db, key: gid)
        }
    }

    public func insertGalleryTags(_ record: GalleryTagsRecord) throws {
        try dbQueue.write { db in
            try record.save(db)
        }
    }

    public func deleteGalleryTags(gid: Int64) throws {
        try dbQueue.write { db in
            _ = try GalleryTagsRecord.deleteOne(db, key: gid)
        }
    }

    // MARK: - 数据导入/导出

    public func exportDatabase(to url: URL) throws -> Bool {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try dbQueue.backup(to: DatabaseQueue(path: url.path))
        return true
    }

    public func importDatabase(from url: URL) throws {
        let srcQueue = try DatabaseQueue(path: url.path)
        let batchSize = 500

        // 分批导入各表, 避免一次性加载全部记录导致 OOM (V-06 修复)
        try batchSave(DownloadRecord.self, from: srcQueue, batchSize: batchSize)
        try batchSave(HistoryRecord.self, from: srcQueue, batchSize: batchSize)
        try batchSave(LocalFavoriteRecord.self, from: srcQueue, batchSize: batchSize)
        // QuickSearch/Filter 使用 insert (生成新 autoincrement ID)
        try batchInsert(QuickSearchRecord.self, from: srcQueue, batchSize: batchSize)
        try batchInsert(FilterRecord.self, from: srcQueue, batchSize: batchSize)
    }

    /// 分批导入 (save = INSERT OR REPLACE)
    private func batchSave<T: FetchableRecord & PersistableRecord>(
        _ type: T.Type, from source: DatabaseQueue, batchSize: Int
    ) throws {
        var offset = 0
        while true {
            let batch: [T] = try source.read { db in
                try T.limit(batchSize, offset: offset).fetchAll(db)
            }
            guard !batch.isEmpty else { break }
            try dbQueue.write { db in
                for record in batch {
                    try record.save(db)
                }
            }
            if batch.count < batchSize { break }
            offset += batchSize
        }
    }

    /// 分批导入 (insert = 新建记录, 用于 autoincrement 表)
    private func batchInsert<T: FetchableRecord & PersistableRecord>(
        _ type: T.Type, from source: DatabaseQueue, batchSize: Int
    ) throws {
        var offset = 0
        while true {
            let batch: [T] = try source.read { db in
                try T.limit(batchSize, offset: offset).fetchAll(db)
            }
            guard !batch.isEmpty else { break }
            try dbQueue.write { db in
                for var record in batch {
                    try record.insert(db)
                }
            }
            if batch.count < batchSize { break }
            offset += batchSize
        }
    }

    // MARK: - 数据库维护 (V-05 修复: 定期 VACUUM)

    /// 执行数据库维护 (integrity_check + VACUUM + WAL checkpoint)
    /// 调用时机: 每 7 天一次, 由 App 启动时检查
    public func performMaintenanceIfNeeded() {
        guard !isDegraded else { return } // 内存数据库无需维护

        let key = "eh_lastDatabaseMaintenance"
        let lastDate = UserDefaults.standard.object(forKey: key) as? Date ?? .distantPast
        let interval: TimeInterval = 7 * 24 * 3600 // 7 天
        guard Date().timeIntervalSince(lastDate) > interval else { return }

        do {
            // 先执行完整性检查，防止在损坏的数据库上 VACUUM 扩大损坏
            let integrityOk: Bool = try dbQueue.read { db in
                // quick_check 比 integrity_check 快，足以检测大多数损坏
                let result = try String.fetchOne(db, sql: "PRAGMA quick_check")
                return result == "ok"
            }

            guard integrityOk else {
                print("[EhDatabase] ⚠️ quick_check 失败，数据库可能损坏，跳过 VACUUM")
                return
            }

            // VACUUM 必须在事务外执行
            try dbQueue.writeWithoutTransaction { db in
                // 先 checkpoint WAL 文件, 减少 VACUUM 耗时
                try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
                // VACUUM: 重建数据库文件, 回收碎片空间
                try db.execute(sql: "VACUUM")
            }
            UserDefaults.standard.set(Date(), forKey: key)
            print("[EhDatabase] ✅ Maintenance completed: VACUUM + WAL checkpoint")
        } catch {
            print("[EhDatabase] ⚠️ Maintenance failed: \(error)")
        }
    }
}

// MARK: - GRDB 记录类型

public struct DownloadRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "download"

    public var gid: Int64
    public var token: String
    public var title: String
    public var titleJpn: String?
    public var thumb: String?
    public var category: Int
    public var posted: String?
    public var uploader: String?
    public var rating: Float
    public var simpleLanguage: String?
    public var pages: Int
    public var state: Int
    public var legacy: Int
    public var date: Date
    public var label: String?

    public init(gid: Int64, token: String, title: String, titleJpn: String? = nil,
                thumb: String? = nil, category: Int = 0, posted: String? = nil,
                uploader: String? = nil, rating: Float = 0, simpleLanguage: String? = nil,
                pages: Int = 0, state: Int = 0, label: String? = nil, date: Date = .init()) {
        self.gid = gid; self.token = token; self.title = title
        self.titleJpn = titleJpn; self.thumb = thumb
        self.category = category; self.posted = posted
        self.uploader = uploader; self.rating = rating
        self.simpleLanguage = simpleLanguage; self.pages = pages
        self.state = state; self.legacy = 0; self.date = date
        self.label = label
    }
}

public struct HistoryRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "history"

    public var gid: Int64
    public var token: String
    public var title: String
    public var titleJpn: String?
    public var thumb: String?
    public var category: Int
    public var posted: String?
    public var uploader: String?
    public var rating: Float
    public var simpleLanguage: String?
    public var pages: Int
    public var mode: Int
    public var date: Date

    public init(gid: Int64, token: String, title: String, titleJpn: String? = nil,
                thumb: String? = nil, category: Int = 0, posted: String? = nil,
                uploader: String? = nil, rating: Float = 0, simpleLanguage: String? = nil,
                pages: Int = 0, mode: Int = 0, date: Date = .init()) {
        self.gid = gid; self.token = token; self.title = title
        self.titleJpn = titleJpn; self.thumb = thumb
        self.category = category; self.posted = posted
        self.uploader = uploader; self.rating = rating
        self.simpleLanguage = simpleLanguage; self.pages = pages
        self.mode = mode; self.date = date
    }
}

public struct LocalFavoriteRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "localFavorite"

    public var gid: Int64
    public var token: String
    public var title: String
    public var titleJpn: String?
    public var thumb: String?
    public var category: Int
    public var posted: String?
    public var uploader: String?
    public var rating: Float
    public var simpleLanguage: String?
    public var pages: Int
    public var date: Date

    public init(gid: Int64, token: String, title: String, category: Int = 0,
                pages: Int = 0, date: Date = .init()) {
        self.gid = gid; self.token = token; self.title = title
        self.category = category; self.pages = pages; self.date = date; self.rating = 0
    }
}

public struct QuickSearchRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable {
    public static let databaseTableName = "quickSearch"

    public var id: Int64?
    public var name: String?
    public var mode: Int
    public var category: Int
    public var keyword: String?
    public var advanceSearch: Int
    public var minRating: Int
    public var pageFrom: Int
    public var pageTo: Int
    public var date: Date

    public init(name: String? = nil, mode: Int = 0, category: Int = 0, keyword: String? = nil,
                date: Date = .init()) {
        self.name = name; self.mode = mode; self.category = category; self.keyword = keyword
        self.advanceSearch = 0; self.minRating = 0; self.pageFrom = 0; self.pageTo = 0; self.date = date
    }
}

public struct DownloadLabelRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "downloadLabel"

    public var id: Int64?
    public var label: String
    public var date: Date

    public init(label: String, date: Date = .init()) {
        self.label = label; self.date = date
    }
}

public struct FilterRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "filter"

    public var id: Int64?
    public var mode: Int
    public var text: String?
    public var enable: Bool
    public var date: Date

    public init(mode: Int, text: String? = nil, enable: Bool = true, date: Date = .init()) {
        self.mode = mode; self.text = text; self.enable = enable; self.date = date
    }
}

// MARK: - 黑名单记录

public struct BlackListRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "blackList"

    public var id: Int64?
    public var badgayname: String
    public var reason: String?
    public var angrywith: String?
    public var addTime: String?
    public var mode: Int?

    public init(badgayname: String, reason: String? = nil, angrywith: String? = nil,
                addTime: String? = nil, mode: Int? = nil) {
        self.badgayname = badgayname; self.reason = reason
        self.angrywith = angrywith; self.addTime = addTime; self.mode = mode
    }
}

// MARK: - 阅读书签记录

public struct BookmarkRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "bookmark"

    public var gid: Int64
    public var token: String
    public var title: String
    public var titleJpn: String?
    public var thumb: String?
    public var category: Int
    public var posted: String?
    public var uploader: String?
    public var rating: Float
    public var simpleLanguage: String?
    public var pages: Int
    public var page: Int
    public var date: Date

    public init(gid: Int64, token: String, title: String, page: Int = 0,
                category: Int = 0, pages: Int = 0, date: Date = .init()) {
        self.gid = gid; self.token = token; self.title = title
        self.category = category; self.pages = pages; self.page = page
        self.date = date; self.rating = 0
    }
}

// MARK: - 下载目录名记录

public struct DownloadDirnameRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "downloadDirname"

    public var gid: Int64
    public var dirname: String

    public init(gid: Int64, dirname: String) {
        self.gid = gid; self.dirname = dirname
    }
}

// MARK: - 画廊标签缓存记录

public struct GalleryTagsRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "galleryTags"

    public var gid: Int64
    public var rows: String?
    public var artist: String?
    public var cosplayer: String?
    public var character: String?
    public var female: String?
    public var group: String?
    public var language: String?
    public var male: String?
    public var misc: String?
    public var mixed: String?
    public var other: String?
    public var parody: String?
    public var reclass: String?
    public var createTime: Date?
    public var updateTime: Date?

    public init(gid: Int64) {
        self.gid = gid
    }
}
