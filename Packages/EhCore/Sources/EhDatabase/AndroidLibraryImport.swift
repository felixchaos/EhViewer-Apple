import Foundation
import GRDB

/// Reads the standalone export produced by EhViewer_CN_SXJ 2.0.2.7's
/// EhDB.exportDB / GreenDAO. Not an importer for an app's live SQLite store.
public enum AndroidLibraryImportError: LocalizedError, Sendable {
    case cannotRead, unsupportedExport, tooLarge, destinationUnavailable

    public var errorDescription: String? {
        switch self {
        case .cannotRead: "无法读取文件。请重新选择安卓端导出的 .db 文件。"
        case .unsupportedExport: "不是受支持的安卓 .db 导出文件，或文件已损坏。请在安卓端重新导出。"
        case .tooLarge: "此导出文件过大，无法安全导入。"
        case .destinationUnavailable: "本地资料库暂时不可写，未导入任何记录。请重新启动应用后再试。"
        }
    }
}

public struct AndroidLibraryImportCounts: Equatable, Sendable {
    public internal(set) var new = 0
    public internal(set) var existing = 0
    public internal(set) var invalid = 0
    public internal(set) var overHistoryLimit = 0
}

public struct AndroidLibraryImportSummary: Equatable, Sendable {
    public let favorites: AndroidLibraryImportCounts
    public let history: AndroidLibraryImportCounts

    public var importableCount: Int { favorites.new + history.new }
}

/// An immutable typed snapshot; confirmation imports this exact data, not a
/// potentially changed file at the same URL. Source access ends after preview.
public struct AndroidLibraryImport: Sendable {
    let favorites: [LocalFavoriteRecord]
    let history: [HistoryRecord]
    let invalidFavorites: Int
    let invalidHistory: Int

    /// The caller must hold any required security scope while this method runs.
    public init(exportAt url: URL) throws {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let copy = staging.appendingPathComponent("export.db")
        defer { try? fileManager.removeItem(at: staging) }
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
            var coordinationError: NSError?
            var result: Result<Void, Error>?
            NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges,
                                           error: &coordinationError) { coordinatedURL in
                result = Result {
                    let values = try coordinatedURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    guard values.isRegularFile == true, let bytes = values.fileSize else {
                        throw AndroidLibraryImportError.cannotRead
                    }
                    guard bytes <= 64 * 1024 * 1024 else { throw AndroidLibraryImportError.tooLarge }
                    try fileManager.copyItem(at: coordinatedURL, to: copy)
                }
            }
            guard coordinationError == nil, let result else { throw AndroidLibraryImportError.cannotRead }
            try result.get()
        } catch let error as AndroidLibraryImportError {
            throw error
        } catch {
            throw AndroidLibraryImportError.cannotRead
        }

        do {
            let bytes = try copy.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard bytes <= 64 * 1024 * 1024 else { throw AndroidLibraryImportError.tooLarge }
            let handle = try FileHandle(forReadingFrom: copy)
            defer { try? handle.close() }
            guard let header = try handle.read(upToCount: 100), header.count == 100,
                  header.prefix(16) == Data("SQLite format 3\0".utf8),
                  header[18] == 1, header[19] == 1 else {
                // WAL and raw app backups are not standalone exports.
                throw AndroidLibraryImportError.unsupportedExport
            }
            var config = Configuration()
            config.readonly = true
            config.prepareDatabase { db in
                try db.execute(sql: "PRAGMA trusted_schema = OFF")
            }
            let reader = try DatabaseQueue(path: copy.path, configuration: config)
            (favorites, invalidFavorites, history, invalidHistory) = try reader.read { db in
                let (favorites, invalidFavorites) = try Self.readRows(db, source: .favorites) { row in
                    var record = LocalFavoriteRecord(gid: row.gid, token: row.token,
                        title: row.title, category: row.category, date: row.date)
                    record.titleJpn = row.titleJpn
                    record.thumb = row.thumb
                    record.posted = row.posted
                    record.uploader = row.uploader
                    record.rating = row.rating
                    record.simpleLanguage = row.language
                    return record
                }
                let (history, invalidHistory) = try Self.readRows(db, source: .history) { row in
                    return HistoryRecord(gid: row.gid, token: row.token, title: row.title,
                        titleJpn: row.titleJpn, thumb: row.thumb, category: row.category,
                        posted: row.posted, uploader: row.uploader, rating: row.rating,
                        simpleLanguage: row.language, mode: row.mode, date: row.date)
                }
                return (favorites, invalidFavorites, history, invalidHistory)
            }
        } catch let error as AndroidLibraryImportError {
            throw error
        } catch {
            // Don't surface arbitrary SQLite diagnostics or private bind values.
            throw AndroidLibraryImportError.unsupportedExport
        }
    }

    private enum Source: String {
        case favorites = "LOCAL_FAVORITES"
        case history = "HISTORY"
    }

    private static func readRows<T>(_ db: Database, source: Source, transform: (SourceRow) -> T)
        throws -> ([T], Int)
    {
        let table = source.rawValue
        // Reject views and virtual / shadow tables rather than executing schema supplied by a file.
        let kind = try String.fetchOne(db, sql:
            "SELECT type FROM pragma_table_list WHERE schema = 'main' AND name = ? COLLATE NOCASE",
            arguments: [table])
        guard kind == "table" else { throw AndroidLibraryImportError.unsupportedExport }

        let expected = ["GID", "TOKEN", "TITLE", "TITLE_JPN", "THUMB", "CATEGORY", "POSTED",
                        "UPLOADER", "RATING", "SIMPLE_LANGUAGE", "TIME"] + (source == .history ? ["MODE"] : [])
        let schema = try Row.fetchAll(db, sql: "SELECT name, type, pk FROM pragma_table_info(?)", arguments: [table])
        let columns = schema.map { ($0["name"] as String).uppercased() }
        let primaryKeys = schema.filter { ($0["pk"] as Int) > 0 }
        guard Set(expected).isSubset(of: Set(columns)), primaryKeys.count == 1,
              (primaryKeys[0]["name"] as String).uppercased() == "GID",
              (primaryKeys[0]["type"] as String).uppercased() == "INTEGER" else {
            throw AndroidLibraryImportError.unsupportedExport
        }

        // Size-check metadata in SQL before materializing text; typed reads reject malformed rows.
        let textColumns: Set<String> = ["TOKEN", "TITLE", "TITLE_JPN", "THUMB", "POSTED", "UPLOADER", "SIMPLE_LANGUAGE"]
        let projection = expected.map { key -> String in
            let identifier = "\"\(key)\""
            if textColumns.contains(key) {
                return "CASE WHEN typeof(\(identifier)) = 'text' AND length(CAST(\(identifier) AS BLOB)) <= 4096 THEN \(identifier) END AS \(identifier)"
            }
            return "CASE WHEN typeof(\(identifier)) IN ('integer', 'real') THEN \(identifier) END AS \(identifier)"
        }.joined(separator: ", ")
        let cursor = try Row.fetchCursor(db, sql: "SELECT \(projection) FROM main.\"\(table)\"")
        var records: [T] = []
        var invalid = 0
        while let row = try cursor.next() {
            guard records.count + invalid < 25_000 else { throw AndroidLibraryImportError.tooLarge }
            if let valid = SourceRow(row, usesMode: source == .history) {
                records.append(transform(valid))
            } else {
                invalid += 1
            }
        }
        return (records, invalid)
    }

    private struct SourceRow {
        let gid: Int64
        let token: String
        let title: String
        let titleJpn: String?
        let thumb: String?
        let category: Int
        let posted: String?
        let uploader: String?
        let rating: Float
        let language: String?
        let mode: Int
        let date: Date

        init?(_ row: Row, usesMode: Bool) {
            // Decode via DatabaseValue so unexpected SQLite storage types do not trap.
            func integer(_ key: String) -> Int64? {
                let value: DatabaseValue = row[key]
                if case let .int64(value) = value.storage { return value }
                return nil
            }
            guard let gid = integer("GID"), gid > 0,
                  let token = row["TOKEN"] as String?, (1...64).contains(token.utf8.count),
                  token.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }),
                  let title = row["TITLE"] as String?,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let milliseconds = integer("TIME"),
                  (0...253_402_300_799_999).contains(milliseconds),
                  let category = integer("CATEGORY"), Int32(exactly: category) != nil,
                  let rating = row["RATING"] as Double?, rating.isFinite, (0...5).contains(rating)
            else { return nil }
            let mode = usesMode ? integer("MODE") : 0
            guard let mode, Int32(exactly: mode) != nil else { return nil }
            self.gid = gid
            self.token = token
            self.title = title
            titleJpn = row["TITLE_JPN"]
            thumb = Self.trustedThumbnail(row["THUMB"])
            self.category = Int(category)
            posted = row["POSTED"]
            uploader = row["UPLOADER"]
            self.rating = Float(rating)
            language = row["SIMPLE_LANGUAGE"]
            self.mode = Int(mode)
            date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        }

        private static func trustedThumbnail(_ string: String?) -> String? {
            guard let string, let url = URLComponents(string: string), url.scheme?.lowercased() == "https",
                  url.user == nil, url.password == nil, url.port == nil,
                  let host = url.host?.lowercased() else { return nil }
            let trusted = ["ehgt.org", "e-hentai.org", "exhentai.org"]
            return trusted.contains { host == $0 || host.hasSuffix("." + $0) } ? string : nil
        }
    }
}
