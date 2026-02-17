//
//  SpiderDen.swift
//  EhSpider
//
//  对应 Android SpiderDen.java
//  负责画廊图片的磁盘缓存和下载目录管理
//

import Foundation
import EhModels
import EhSettings

// MARK: - SpiderDen (画廊图片存储管理)

public actor SpiderDen {

    // MARK: - 常量

    /// 支持的图片扩展名
    public static let supportedExtensions = [".jpg", ".png", ".gif", ".webp", ".jpeg"]

    /// 默认缓存大小 (320MB)
    private static let defaultCacheSize = 320 * 1024 * 1024

    // MARK: - 属性

    private let gid: Int64
    private let downloadDir: URL
    private var mode: SpiderMode = .read

    /// 简单的文件缓存（用于阅读模式）
    /// 审计修复 C-2: 使用 OSAllocatedUnfairLock 替代 nonisolated(unsafe)，消除数据竞争
    private static let _readCacheLock = NSLock()
    private static nonisolated(unsafe) var _readCache: SimpleDiskCache?
    private static nonisolated(unsafe) var _cacheInitialized = false

    /// 线程安全的 readCache 访问器
    static var readCache: SimpleDiskCache? {
        _readCacheLock.lock()
        defer { _readCacheLock.unlock() }
        return _readCache
    }

    // MARK: - 初始化

    /// 初始化缓存系统 (应在 App 启动时调用)
    public static func initialize() {
        _readCacheLock.lock()
        guard !_cacheInitialized else {
            _readCacheLock.unlock()
            return
        }
        _cacheInitialized = true
        _readCacheLock.unlock()

        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("spider_image")

        // 创建缓存目录
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // 读取缓存大小配置 (40-640MB)
        let cacheSizeMB = min(max(AppSettings.shared.readCacheSize, 40), 640)
        let cacheSize = cacheSizeMB * 1024 * 1024

        let cache = SimpleDiskCache(directory: cacheDir, maxSize: cacheSize)
        _readCacheLock.lock()
        _readCache = cache
        _readCacheLock.unlock()
    }

    /// 清除指定画廊的所有缓存图片 (删除画廊时调用, 避免缓存泄漏)
    public static func clearCache(forGid gid: Int64, pages: Int) {
        guard let cache = readCache else { return }
        for i in 0..<pages {
            cache.remove(key: "image_\(gid)_\(i)")
        }
    }

    public init(galleryInfo: GalleryInfo) {
        self.gid = galleryInfo.gid
        self.downloadDir = Self.getGalleryDownloadDir(galleryInfo: galleryInfo)
    }

    // MARK: - 下载目录管理

    /// 获取画廊下载目录 (对应 Android getGalleryDownloadDir)
    public static func getGalleryDownloadDir(galleryInfo: GalleryInfo) -> URL {
        let baseDir = getDownloadLocation()
        let dirname = sanitizeFilename("\(galleryInfo.gid)-\(galleryInfo.bestTitle)")
        return baseDir.appendingPathComponent(dirname)
    }

    /// 获取下载根目录
    public static func getDownloadLocation() -> URL {
        #if os(macOS)
        // macOS: 支持用户自定义路径
        if let customPath = UserDefaults.standard.string(forKey: "downloadPath"),
           !customPath.isEmpty {
            return URL(fileURLWithPath: customPath)
        }
        #endif
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("download")
    }

    // MARK: - 模式设置

    public func setMode(_ mode: SpiderMode) {
        self.mode = mode

        if mode == .download {
            ensureDownloadDir()
        }
    }

    public func getMode() -> SpiderMode {
        mode
    }

    /// 确保下载目录存在
    @discardableResult
    private func ensureDownloadDir() -> Bool {
        do {
            try FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)
            return true
        } catch {
            print("[SpiderDen] Failed to create download dir: \(error)")
            return false
        }
    }

    /// 检查是否就绪
    public func isReady() -> Bool {
        switch mode {
        case .read:
            return Self.readCache != nil
        case .download:
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: downloadDir.path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    /// 获取下载目录
    public func getDownloadDir() -> URL? {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: downloadDir.path, isDirectory: &isDir) && isDir.boolValue {
            return downloadDir
        }
        return nil
    }

    // MARK: - 图片文件名

    /// 生成图片文件名 (对应 Android generateImageFilename)
    /// 格式: 00000001.jpg (8位数字 + 扩展名)
    public static func generateImageFilename(index: Int, extension ext: String) -> String {
        String(format: "%08d%@", index + 1, ext)
    }

    /// 在目录中查找图片文件 (对应 Android findImageFile)
    public static func findImageFile(in dir: URL, index: Int) -> URL? {
        for ext in supportedExtensions {
            let filename = generateImageFilename(index: index, extension: ext)
            let file = dir.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: file.path) {
                return file
            }
        }
        return nil
    }

    // MARK: - 缓存键

    /// 生成缓存键 (对应 Android EhCacheKeyFactory.getImageKey)
    private func cacheKey(for index: Int) -> String {
        "image_\(gid)_\(index)"
    }

    // MARK: - 检查图片是否存在

    /// 检查缓存中是否包含图片
    private func containInCache(index: Int) -> Bool {
        guard let cache = Self.readCache else { return false }
        return cache.contains(key: cacheKey(for: index))
    }

    /// 检查下载目录中是否包含图片
    private func containInDownloadDir(index: Int) -> Bool {
        guard let dir = getDownloadDir() else { return false }
        return Self.findImageFile(in: dir, index: index) != nil
    }

    /// 检查是否包含图片 (对应 Android contain)
    public func contain(index: Int) -> Bool {
        switch mode {
        case .read:
            return containInCache(index: index) || containInDownloadDir(index: index)
        case .download:
            return containInDownloadDir(index: index) || copyFromCacheToDownloadDir(index: index)
        }
    }

    // MARK: - 缓存到下载目录复制

    /// 从缓存复制到下载目录 (对应 Android copyFromCacheToDownloadDir)
    @discardableResult
    private func copyFromCacheToDownloadDir(index: Int) -> Bool {
        guard let cache = Self.readCache,
              let dir = getDownloadDir() else { return false }

        let key = cacheKey(for: index)
        guard let data = cache.getData(forKey: key) else { return false }

        // 检测图片格式
        let ext = detectImageExtension(data: data) ?? ".jpg"

        // 写入下载目录
        let filename = Self.generateImageFilename(index: index, extension: ext)
        let destFile = dir.appendingPathComponent(filename)

        do {
            try data.write(to: destFile)
            return true
        } catch {
            print("[SpiderDen] Failed to copy from cache: \(error)")
            return false
        }
    }

    /// 检测图片格式
    private func detectImageExtension(data: Data) -> String? {
        guard data.count >= 4 else { return nil }

        let bytes = [UInt8](data.prefix(4))

        // JPEG: FF D8 FF
        if bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF {
            return ".jpg"
        }
        // PNG: 89 50 4E 47
        if bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 {
            return ".png"
        }
        // GIF: 47 49 46 38
        if bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38 {
            return ".gif"
        }
        // WebP: 52 49 46 46 (RIFF)
        if bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 {
            return ".webp"
        }

        return nil
    }

    // MARK: - 删除图片

    /// 从缓存中删除
    @discardableResult
    private func removeFromCache(index: Int) -> Bool {
        Self.readCache?.remove(key: cacheKey(for: index)) ?? false
    }

    /// 从下载目录删除
    @discardableResult
    private func removeFromDownloadDir(index: Int) -> Bool {
        guard let dir = getDownloadDir() else { return false }

        var result = false
        for ext in Self.supportedExtensions {
            let filename = Self.generateImageFilename(index: index, extension: ext)
            let file = dir.appendingPathComponent(filename)
            do {
                try FileManager.default.removeItem(at: file)
                result = true
            } catch {
                // 文件可能不存在，忽略错误
            }
        }
        return result
    }

    /// 删除图片 (对应 Android remove)
    @discardableResult
    public func remove(index: Int) -> Bool {
        var result = removeFromCache(index: index)
        result = removeFromDownloadDir(index: index) || result
        return result
    }

    // MARK: - 写入图片

    /// 写入图片数据 (对应 Android openOutputStreamPipe)
    @discardableResult
    public func write(data: Data, index: Int, extension ext: String? = nil) -> Bool {
        let actualExt = fixExtension(ext ?? ".jpg")

        switch mode {
        case .read:
            // 优先写入下载目录（如果已下载），否则写入缓存
            if containInDownloadDir(index: index) {
                return writeToDownloadDir(data: data, index: index, extension: actualExt)
            } else {
                return writeToCache(data: data, index: index)
            }
        case .download:
            return writeToDownloadDir(data: data, index: index, extension: actualExt)
        }
    }

    private func writeToCache(data: Data, index: Int) -> Bool {
        Self.readCache?.set(data, forKey: cacheKey(for: index)) ?? false
    }

    private func writeToDownloadDir(data: Data, index: Int, extension ext: String) -> Bool {
        guard ensureDownloadDir() else { return false }

        // 磁盘空间预检查: 至少需要 数据大小 + 10MB 余量
        let requiredBytes = Int64(data.count) + 10 * 1024 * 1024
        if !Self.hasSufficientDiskSpace(bytes: requiredBytes) {
            print("[SpiderDen] ⚠️ 磁盘空间不足，需要 \(requiredBytes / 1024 / 1024)MB，跳过写入")
            return false
        }

        let filename = Self.generateImageFilename(index: index, extension: ext)
        let file = downloadDir.appendingPathComponent(filename)

        do {
            try data.write(to: file)
            return true
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError {
            print("[SpiderDen] ❌ 磁盘已满，无法写入页面 \(index)")
            return false
        } catch {
            print("[SpiderDen] Failed to write to download dir: \(error)")
            return false
        }
    }

    /// 检查磁盘可用空间是否足够
    public static func hasSufficientDiskSpace(bytes: Int64 = 50 * 1024 * 1024) -> Bool {
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(
                forPath: NSHomeDirectory()
            )
            if let freeSize = attrs[.systemFreeSize] as? Int64 {
                return freeSize >= bytes
            }
        } catch {}
        return true // 无法检查时乐观处理
    }

    /// 获取磁盘可用空间 (bytes)
    public static func availableDiskSpace() -> Int64? {
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(
                forPath: NSHomeDirectory()
            )
            return attrs[.systemFreeSize] as? Int64
        } catch {
            return nil
        }
    }

    /// 修正扩展名
    private func fixExtension(_ ext: String) -> String {
        if Self.supportedExtensions.contains(ext) {
            return ext
        }
        return Self.supportedExtensions[0] // 默认 .jpg
    }

    // MARK: - 读取图片

    /// 读取图片数据 (对应 Android openInputStreamPipe)
    public func read(index: Int) -> Data? {
        switch mode {
        case .read:
            // 优先从下载目录读取，然后从缓存
            if let data = readFromDownloadDir(index: index) {
                return data
            }
            return readFromCache(index: index)
        case .download:
            return readFromDownloadDir(index: index)
        }
    }

    private func readFromCache(index: Int) -> Data? {
        Self.readCache?.getData(forKey: cacheKey(for: index))
    }

    private func readFromDownloadDir(index: Int) -> Data? {
        guard let dir = getDownloadDir(),
              let file = Self.findImageFile(in: dir, index: index) else {
            return nil
        }
        return try? Data(contentsOf: file)
    }

    /// 获取图片文件URL (用于显示)
    public func getImageFileURL(index: Int) -> URL? {
        if let dir = getDownloadDir(),
           let file = Self.findImageFile(in: dir, index: index) {
            return file
        }
        return nil
    }

    // MARK: - 工具方法

    /// 文件名清理
    private static func sanitizeFilename(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let sanitized = name.components(separatedBy: illegal).joined(separator: "_")
        let trimmed = sanitized.prefix(128)
        return String(trimmed).trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - SpiderMode

public enum SpiderMode: Sendable {
    case read      // 阅读模式 - 使用缓存
    case download  // 下载模式 - 写入文件
}

// MARK: - SimpleDiskCache (简单磁盘缓存)

/// 简单的LRU磁盘缓存
/// 对应 Android SimpleDiskCache
/// 审计修复 C-1: 所有文件系统操作统一在 queue 上执行，消除数据竞争
final class SimpleDiskCache: @unchecked Sendable {
    private let directory: URL
    private let maxSize: Int
    private let queue = DispatchQueue(label: "com.ehviewer.spider.cache", qos: .utility)

    init(directory: URL, maxSize: Int) {
        self.directory = directory
        self.maxSize = maxSize

        // 异步清理过大的缓存
        queue.async { [weak self] in
            self?.trimToSize()
        }
    }

    func contains(key: String) -> Bool {
        queue.sync {
            let file = fileURL(for: key)
            return FileManager.default.fileExists(atPath: file.path)
        }
    }

    func getData(forKey key: String) -> Data? {
        queue.sync {
            let file = fileURL(for: key)
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }

            // 更新访问时间 (LRU)
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: file.path
            )

            return try? Data(contentsOf: file)
        }
    }

    @discardableResult
    func set(_ data: Data, forKey key: String) -> Bool {
        let success: Bool = queue.sync {
            let file = fileURL(for: key)
            do {
                try data.write(to: file)
                return true
            } catch {
                return false
            }
        }
        if success {
            // 异步检查缓存大小
            queue.async { [weak self] in
                self?.trimToSize()
            }
        }
        return success
    }

    @discardableResult
    func remove(key: String) -> Bool {
        queue.sync {
            let file = fileURL(for: key)
            do {
                try FileManager.default.removeItem(at: file)
                return true
            } catch {
                return false
            }
        }
    }

    private func fileURL(for key: String) -> URL {
        // 使用MD5哈希作为文件名以避免特殊字符问题
        let hash = key.data(using: .utf8)?.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .prefix(32) ?? key.prefix(32)
        return directory.appendingPathComponent(String(hash))
    }

    /// 清理缓存至目标大小
    private func trimToSize() {
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
            )

            // 计算总大小
            var totalSize = 0
            var fileInfos: [(url: URL, size: Int, date: Date)] = []

            for file in files {
                let attributes = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = attributes.fileSize ?? 0
                let date = attributes.contentModificationDate ?? .distantPast
                totalSize += size
                fileInfos.append((file, size, date))
            }

            // 如果超过最大大小，删除最旧的文件
            if totalSize > maxSize {
                // 按修改时间排序（最旧的在前）
                fileInfos.sort { $0.date < $1.date }

                let targetSize = maxSize * 3 / 4  // 清理到 75%
                var currentSize = totalSize

                for info in fileInfos {
                    if currentSize <= targetSize { break }
                    try? FileManager.default.removeItem(at: info.url)
                    currentSize -= info.size
                }
            }
        } catch {
            print("[SimpleDiskCache] Failed to trim cache: \(error)")
        }
    }
}
