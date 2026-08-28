//
//  EhTagDatabase.swift
//  EhCore
//
//  对应 Android EhTagDatabase.java
//  标签翻译数据库 - 将英文标签翻译成中文
//

import Foundation

/// 标签翻译数据库
/// 支持从 eh-tag-translation 项目下载的数据库文件
public final class EhTagDatabase: @unchecked Sendable {
    public static let shared = EhTagDatabase()

    // MARK: - Namespace 映射 (对应 Android NAMESPACE_TO_PREFIX/PREFIX_TO_NAMESPACE)

    public static let namespaceToPrefix: [String: String] = [
        "rows": "n:",
        "artist": "a:",
        "cosplayer": "cos:",
        "character": "c:",
        "female": "f:",
        "group": "g:",
        "language": "l:",
        "male": "m:",
        "misc": "",
        "mixed": "x:",
        "other": "o:",
        "parody": "p:",
        "reclass": "r:"
    ]

    public static let prefixToNamespace: [String: String] = [
        "n:": "rows",
        "a:": "artist",
        "cos:": "cosplayer",
        "c:": "character",
        "f:": "female",
        "g:": "group",
        "l:": "language",
        "m:": "male",
        "": "misc",
        "x:": "mixed",
        "o:": "other",
        "p:": "parody",
        "r:": "reclass"
    ]

    // MARK: - 线程安全存储 (V-01 fix)

    /// 并发读 + barrier 写保护队列 — 所有对 _translations 的访问必须通过此队列
    private let queue = DispatchQueue(label: "com.ehviewer.tags", attributes: .concurrent)

    /// 标签翻译字典 — 仅在 barrier 块中写入
    private var _translations: [String: String] = [:]

    /// 预排序键数组 — 用于二分查找前缀匹配 (已 lowercased)
    private var _sortedKeys: [String] = []
    /// 对应 _sortedKeys 同索引的翻译值 (原始大小写)
    private var _sortedValues: [String] = []
    /// 对应 _sortedKeys 同索引的翻译值 (已 lowercased，用于中文子串匹配)
    private var _sortedLcValues: [String] = []

    /// 数据库是否已加载 — 通过 queue.sync 读取
    private var _isLoaded = false

    /// 数据库版本 — 通过 queue.sync 读取
    private var _version: String?

    /// 线程安全读取 isLoaded
    public var isLoaded: Bool { queue.sync { _isLoaded } }

    /// 线程安全读取 version
    public var version: String? { queue.sync { _version } }

    /// 数据库文件路径
    private var databasePath: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("eh_tag_translation.json")
    }

    private init() {
        // 在后台 barrier 块中加载 — 不阻塞主线程
        queue.async(flags: .barrier) { [self] in
            _loadDatabaseSync()
            if !_isLoaded {
                print("[EhTagDatabase] Database not found, attempting download...")
                Task { try? await self.updateDatabase(forceUpdate: false) }
            }
        }
    }

    // MARK: - 公开接口 (线程安全读)

    /// 获取标签翻译 — 线程安全
    /// - Parameter tag: 英文标签 (格式: "namespace:tag" 或 "tag")
    /// - Returns: 中文翻译，如果没有则返回 nil
    public func getTranslation(_ tag: String) -> String? {
        queue.sync {
            guard _isLoaded else { return nil }
            return _translations[tag.lowercased()]
        }
    }

    /// 翻译标签数组 — 线程安全，单次锁定
    /// - Parameter tags: 英文标签数组
    /// - Returns: 翻译结果数组 (保留原始标签如果没有翻译)
    public func translateTags(_ tags: [String]) -> [String] {
        queue.sync {
            guard _isLoaded else { return tags }
            return tags.map { _translations[$0.lowercased()] ?? $0 }
        }
    }

    /// 获取带翻译的标签 (英文 + 中文) — 线程安全
    /// - Parameter tag: 英文标签
    /// - Returns: (英文, 中文?) 元组
    public func getTagWithTranslation(_ tag: String) -> (english: String, chinese: String?) {
        queue.sync {
            guard _isLoaded else { return (tag, nil) }
            return (tag, _translations[tag.lowercased()])
        }
    }

    /// namespace 转前缀
    /// 这个键是不是缩写形式（`a:xxx` / `f:xxx`）。
    /// 缩写只保留在翻译查询表里，不进建议索引。
    static func isAbbreviatedKey(_ key: String) -> Bool {
        guard let colon = key.firstIndex(of: ":") else { return false }
        let prefix = String(key[key.startIndex...colon])   // 含冒号
        return prefixToNamespace[prefix] != nil
    }

    /// 把用户打的缩写前缀换成全称，让 `f:machine` 也能命中 `female:machine`。
    /// 建议索引里只有全称，不做这层转换的话按缩写搜索会一条都搜不到。
    static func normalizeQueryPrefix(_ query: String) -> String {
        guard let colon = query.firstIndex(of: ":") else { return query }
        let prefix = String(query[query.startIndex...colon])
        guard let namespace = prefixToNamespace[prefix] else { return query }
        return namespace + ":" + query[query.index(after: colon)...]
    }

    public static func namespaceToPrefix(_ namespace: String) -> String? {
        if let prefix = namespaceToPrefix[namespace] {
            return prefix
        }
        // 检查是否已经是前缀格式
        let prefixKey = namespace + ":"
        if prefixToNamespace[prefixKey] != nil {
            return namespace
        }
        return nil
    }

    /// 前缀转 namespace
    public static func prefixToNamespace(_ prefix: String) -> String? {
        prefixToNamespace[prefix]
    }

    /// 搜索标签建议 — 优化版 (V-03 fix, 对齐 Android EhTagDatabase.suggest)
    /// Phase 1: 二分查找前缀匹配 → O(log N + K)
    /// Phase 2: 线性扫描子串 + 中文匹配 (预 lowercased 数据，无运行时转换)
    /// - Parameters:
    ///   - keyword: 搜索关键词 (可以是 "namespace:tag" 格式或纯标签)
    ///   - limit: 返回结果数量上限，默认 40
    /// - Returns: 匹配的标签列表 [(chinese, english)]
    public func suggest(_ keyword: String, limit: Int = 40) -> [(chinese: String, english: String)] {
        queue.sync {
            guard _isLoaded, !keyword.isEmpty else { return [] }

            let lowered = Self.normalizeQueryPrefix(keyword.lowercased())
            var results: [(chinese: String, english: String)] = []
            var seen = Set<String>()

            // Phase 1: 二分查找前缀匹配 (最常见: 用户输入 "a:big" 匹配 "a:big breasts")
            let startIdx = _lowerBound(for: lowered)
            for i in startIdx..<_sortedKeys.count {
                guard results.count < limit else { break }
                let key = _sortedKeys[i]
                guard key.hasPrefix(lowered) else { break } // 前缀区间结束
                seen.insert(key)
                results.append((chinese: _sortedValues[i], english: key))
            }

            // Phase 2: 子串匹配 + 中文匹配 (补充不足的结果)
            if results.count < limit {
                for i in 0..<_sortedKeys.count {
                    guard results.count < limit else { break }
                    let key = _sortedKeys[i]
                    guard !seen.contains(key) else { continue }
                    if key.contains(lowered) || _sortedLcValues[i].contains(lowered) {
                        seen.insert(key)
                        results.append((chinese: _sortedValues[i], english: key))
                    }
                }
            }

            return results
        }
    }

    /// 列出某个命名空间下的标签 (供标签选择器按分组浏览)
    ///
    /// 内部索引的 key 本来就是 `namespace:tag`，按前缀取区间即可。
    /// - Parameters:
    ///   - namespace: 如 "female" / "artist"
    ///   - filter: 可选的关键词过滤，中英文都会匹配
    public func tags(inNamespace namespace: String, filter: String = "", limit: Int = 300)
        -> [(chinese: String, english: String)] {
        queue.sync {
            guard _isLoaded else { return [] }
            let prefix = namespace.lowercased() + ":"
            let lowered = filter.lowercased()

            var results: [(chinese: String, english: String)] = []
            let startIdx = _lowerBound(for: prefix)
            for i in startIdx..<_sortedKeys.count {
                guard results.count < limit else { break }
                let key = _sortedKeys[i]
                guard key.hasPrefix(prefix) else { break }
                if !lowered.isEmpty {
                    guard key.contains(lowered) || _sortedLcValues[i].contains(lowered) else { continue }
                }
                results.append((chinese: _sortedValues[i], english: key))
            }
            return results
        }
    }

    /// 索引里实际存在标签的命名空间 (按 namespaceToPrefix 的顺序)
    public func availableNamespaces() -> [String] {
        let ordered = ["female", "male", "mixed", "artist", "group", "parody",
                       "character", "cosplayer", "language", "other", "reclass", "misc"]
        return ordered.filter { !tags(inNamespace: $0, limit: 1).isEmpty }
    }

    /// 将 "namespace:tag" 格式的标签转为搜索关键词格式
    /// (对齐 Android SearchBar.TagSuggestion.rebuildKeyword + wrapTagKeyword)
    /// 例: "artist:some name" → "a:\"some name$\""
    ///     "female:big breasts" → "f:\"big breasts$\""
    ///     "misc:tag" → "tag$"
    public static func rebuildKeyword(_ tag: String) -> String {
        let parts = tag.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else {
            // 没有 namespace，直接返回 tag$
            let cleaned = tag.trimmingCharacters(in: .whitespaces)
            if cleaned.contains(" ") {
                return "\"\(cleaned)$\""
            }
            return "\(cleaned)$"
        }

        let namespace = String(parts[0]).trimmingCharacters(in: .whitespaces)
        let tagName = String(parts[1]).trimmingCharacters(in: .whitespaces)

        // 获取短前缀
        let prefix = namespaceToPrefix[namespace] ?? "\(namespace):"

        if tagName.contains(" ") {
            return "\(prefix)\"\(tagName)$\""
        } else {
            return "\(prefix)\(tagName)$"
        }
    }

    /// 从搜索文本中提取最后一个未完成的关键词用于搜索建议
    /// (对齐 Android SearchBar.updateSuggestions 的逻辑)
    public static func extractLastKeyword(from text: String) -> (keyword: String, prefix: String)? {
        guard !text.isEmpty else { return nil }

        // 从后往前扫描，找到最后一个未完成的搜索词
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // 如果以 $ 或 " 结尾，说明最后一个 tag 已完成
        if trimmed.hasSuffix("$") || trimmed.hasSuffix("\"") {
            return nil
        }

        // 找最后一个空格后的内容
        if let lastSpaceIndex = trimmed.lastIndex(of: " ") {
            let keyword = String(trimmed[trimmed.index(after: lastSpaceIndex)...])
            let prefixText = String(trimmed[...lastSpaceIndex])
            return keyword.isEmpty ? nil : (keyword, prefixText)
        }

        // 没有空格，整个文本就是关键词
        return (trimmed, "")
    }

    /// 将搜索建议应用到搜索文本中
    /// (对齐 Android SearchBar.TagSuggestion.onClick + replaceCommonSubstring)
    public static func applySuggestion(to text: String, suggestion: String) -> String {
        let rebuilt = rebuildKeyword(suggestion)

        if let extracted = extractLastKeyword(from: text) {
            // 替换掉最后一个未完成的关键词
            let prefix = extracted.prefix.trimmingCharacters(in: .whitespaces)
            if prefix.isEmpty {
                return "\(rebuilt) "
            }
            return "\(prefix) \(rebuilt) "
        }

        // fallback: 直接追加
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return "\(rebuilt) "
        }
        return "\(trimmed) \(rebuilt) "
    }

    // MARK: - 数据库管理

    /// 检查是否需要更新数据库
    public func needsUpdate() async -> Bool {
        guard FileManager.default.fileExists(atPath: databasePath.path) else {
            return true
        }

        // 检查文件修改时间 (超过7天则需要更新)
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: databasePath.path)
            if let modDate = attributes[.modificationDate] as? Date {
                let daysSinceUpdate = Date().timeIntervalSince(modDate) / 86400
                return daysSinceUpdate > 7
            }
        } catch {
            return true
        }

        return false
    }

    /// 下载并更新数据库
    /// - Parameter forceUpdate: 强制更新
    public func updateDatabase(forceUpdate: Bool = false) async throws {
        let needUpdate = await needsUpdate()
        guard forceUpdate || needUpdate else { return }

        // eh-tag-translation 项目的 JSON 数据库 URL
        let databaseUrls = [
            "https://raw.githubusercontent.com/EhTagTranslation/DatabaseReleases/master/db.text.json",
            "https://cdn.jsdelivr.net/gh/EhTagTranslation/DatabaseReleases/db.text.json"
        ]

        var lastError: Error?
        for urlString in databaseUrls {
            guard let url = URL(string: urlString) else { continue }

            do {
                let (data, response) = try await URLSession.shared.data(from: url)

                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    continue
                }

                // 保存到本地
                try data.write(to: databasePath)

                // 重新加载
                await loadDatabase()
                return

            } catch {
                lastError = error
                continue
            }
        }

        if let error = lastError {
            throw error
        }
    }

    // MARK: - 私有方法

    /// 异步加载 — 在 barrier 块中执行 JSON 解析 (更新数据库后调用)
    private func loadDatabase() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async(flags: .barrier) { [self] in
                _loadDatabaseSync()
                cont.resume()
            }
        }
    }

    /// 同步加载 — 必须在 barrier 块中调用
    private func _loadDatabaseSync() {
        guard FileManager.default.fileExists(atPath: databasePath.path) else {
            _isLoaded = false
            return
        }

        do {
            let data = try Data(contentsOf: databasePath)
            try _parseDatabaseSync(data)
            _isLoaded = true
        } catch {
            print("[EhTagDatabase] Failed to load database: \(error)")
            _isLoaded = false
        }
    }

    /// 解析数据库 JSON 并构建排序索引 — 必须在 barrier 块中调用 (V-02 fix)
    /// 格式: { "head": {...}, "data": [ { "namespace": "...", "data": { "tag": { "name": "中文名" } } } ] }
    private func _parseDatabaseSync(_ data: Data) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TagDatabaseError.invalidFormat
        }

        // 解析版本
        if let head = json["head"] as? [String: Any],
           let version = head["committer"] as? [String: Any],
           let when = version["when"] as? String {
            _version = when
        }

        // 解析标签数据
        guard let dataArray = json["data"] as? [[String: Any]] else {
            throw TagDatabaseError.invalidFormat
        }

        var newTranslations: [String: String] = [:]

        for namespaceData in dataArray {
            guard let namespace = namespaceData["namespace"] as? String,
                  let tags = namespaceData["data"] as? [String: Any] else {
                continue
            }

            let prefix = Self.namespaceToPrefix[namespace] ?? ""

            for (tagName, tagInfo) in tags {
                guard let info = tagInfo as? [String: Any],
                      let chineseName = info["name"] as? String else {
                    continue
                }

                let fullTag: String
                if prefix.isEmpty {
                    fullTag = tagName.lowercased()
                } else {
                    fullTag = "\(namespace):\(tagName)".lowercased()
                }

                newTranslations[fullTag] = chineseName

                if !prefix.isEmpty {
                    let shortTag = "\(prefix)\(tagName)".lowercased()
                    newTranslations[shortTag] = chineseName
                }
            }
        }

        _translations = newTranslations

        // 构建预排序索引 (用于二分查找前缀匹配, V-03)
        //
        // 只收全称形式（artist: / female: …），不收缩写（a: / f: …）。
        // 两种形式在 _translations 里都要留着——按任一形式查翻译都得能命中——
        // 但建议列表里两份是同一个标签，同时出现就是「a:machine head」和
        // 「artist:machine head」并排，用户看到的是重复项。
        // Android 在解析阶段就把缩写规范成全称（EhTagDatabase.parseTag 里的
        // PREFIX_TO_NAMESPACE 查表），标签表中只有一种形式。
        let sorted = newTranslations
            .filter { !Self.isAbbreviatedKey($0.key) }
            .sorted { $0.key < $1.key }
        _sortedKeys = sorted.map { $0.key }
        _sortedValues = sorted.map { $0.value }
        _sortedLcValues = sorted.map { $0.value.lowercased() }

        print("[EhTagDatabase] Loaded \(newTranslations.count) translations, sorted index built")
    }

    /// 二分查找 — 定位第一个 >= prefix 的索引 (queue 内部调用)
    private func _lowerBound(for prefix: String) -> Int {
        var lo = 0, hi = _sortedKeys.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if _sortedKeys[mid] < prefix {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }
}

// MARK: - 错误

public enum TagDatabaseError: LocalizedError {
    case invalidFormat
    case downloadFailed

    public var errorDescription: String? {
        switch self {
        case .invalidFormat: return "Invalid database format"
        case .downloadFailed: return "Failed to download database"
        }
    }
}

// MARK: - Tag 结构 (用于搜索建议)

public struct TagTranslation: Identifiable, Sendable {
    public let id = UUID()
    public let english: String
    public let chinese: String
    public let namespace: String?

    public init(english: String, chinese: String, namespace: String? = nil) {
        self.english = english
        self.chinese = chinese
        self.namespace = namespace
    }

    /// 显示文本 (中文 + 英文)
    public var displayText: String {
        "\(chinese) (\(english))"
    }
}
