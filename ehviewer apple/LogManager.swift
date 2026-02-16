//
//  LogManager.swift
//  ehviewer apple
//
//  本地日志管理器 — 替代 print(), 将关键日志写入沙盒 .log 文件
//  支持: OSLog 统一日志 + 文件持久化 + 导出分享
//

import Foundation
import os.log
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 日志级别

public enum LogLevel: String, Sendable {
    case debug   = "DEBUG"
    case info    = "INFO"
    case warning = "WARN"
    case error   = "ERROR"
    case fault   = "FAULT"

    var osLogType: OSLogType {
        switch self {
        case .debug:   return .debug
        case .info:    return .info
        case .warning: return .default
        case .error:   return .error
        case .fault:   return .fault
        }
    }
}

// MARK: - LogManager

/// 线程安全的日志管理器
/// 同时输出到 OSLog (系统统一日志) 和沙盒文件 (用户可导出)
public final class LogManager: Sendable {
    public static let shared = LogManager()

    /// 日志文件目录
    private let logDirectory: URL
    /// 当前日志文件路径
    private let currentLogFile: URL
    /// 最大单文件大小 (2MB)
    private let maxFileSize: Int = 2 * 1024 * 1024
    /// 最多保留日志文件数
    private let maxFileCount: Int = 5

    /// OSLog 分类
    private let osLogger = Logger(subsystem: "Stellatrix.ehviewer-apple", category: "App")

    /// 串行队列, 保证文件写入线程安全
    private let queue = DispatchQueue(label: "com.ehviewer.log", qos: .utility)

    private init() {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        logDirectory = cacheDir.appendingPathComponent("logs")
        currentLogFile = logDirectory.appendingPathComponent("ehviewer.log")

        // 确保目录存在
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
    }

    // MARK: - 公共 API

    /// 记录调试日志 (仅 DEBUG 构建写入文件)
    public func debug(_ message: String, category: String = "General", file: String = #fileID, line: Int = #line) {
        osLogger.debug("[\(category)] \(message)")
        #if DEBUG
        writeToFile(level: .debug, category: category, message: message, file: file, line: line)
        #endif
    }

    /// 记录信息日志
    public func info(_ message: String, category: String = "General", file: String = #fileID, line: Int = #line) {
        osLogger.info("[\(category)] \(message)")
        writeToFile(level: .info, category: category, message: message, file: file, line: line)
    }

    /// 记录警告日志
    public func warning(_ message: String, category: String = "General", file: String = #fileID, line: Int = #line) {
        osLogger.warning("[\(category)] \(message)")
        writeToFile(level: .warning, category: category, message: message, file: file, line: line)
    }

    /// 记录错误日志
    public func error(_ message: String, category: String = "General", file: String = #fileID, line: Int = #line) {
        osLogger.error("[\(category)] \(message)")
        writeToFile(level: .error, category: category, message: message, file: file, line: line)
    }

    /// 记录严重错误 (SadPanda, 数据库崩溃等)
    public func fault(_ message: String, category: String = "General", file: String = #fileID, line: Int = #line) {
        osLogger.fault("[\(category)] \(message)")
        writeToFile(level: .fault, category: category, message: message, file: file, line: line)
    }

    // MARK: - 文件管理

    /// 获取所有日志文件 URL (用于导出)
    public func allLogFiles() -> [URL] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "log" }
            .sorted { (a, b) in
                let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return dateA > dateB
            }
    }

    /// 将所有日志合并为一个临时文件 (用于 ShareSheet 导出)
    public func exportCombinedLog() -> URL? {
        let files = allLogFiles()
        guard !files.isEmpty else { return nil }

        let exportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ehviewer_logs_\(dateStamp()).log")

        var combined = """
        ═══════════════════════════════════════
        EhViewer Apple — 诊断日志
        导出时间: \(ISO8601DateFormatter().string(from: Date()))
        系统: \(systemInfo())
        App 版本: \(appVersion())
        ═══════════════════════════════════════\n\n
        """

        for file in files.reversed() {
            if let content = try? String(contentsOf: file, encoding: .utf8) {
                combined += "── \(file.lastPathComponent) ──\n"
                combined += content
                combined += "\n\n"
            }
        }

        try? combined.write(to: exportURL, atomically: true, encoding: .utf8)
        return exportURL
    }

    /// 清除所有日志
    public func clearLogs() {
        queue.async { [logDirectory] in
            let fm = FileManager.default
            if let files = try? fm.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: nil) {
                for file in files where file.pathExtension == "log" {
                    try? fm.removeItem(at: file)
                }
            }
        }
    }

    /// 日志文件总大小 (字节)
    public func totalLogSize() -> Int64 {
        let files = allLogFiles()
        return files.reduce(0) { sum, file in
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
            return sum + size
        }
    }

    // MARK: - 内部实现

    private func writeToFile(level: LogLevel, category: String, message: String, file: String, line: Int) {
        queue.async { [self] in
            rotateIfNeeded()

            let timestamp = ISO8601DateFormatter().string(from: Date())
            let sourceFile = URL(fileURLWithPath: file).lastPathComponent
            let entry = "[\(timestamp)] [\(level.rawValue)] [\(category)] \(message) ← \(sourceFile):\(line)\n"

            if let data = entry.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: currentLogFile.path) {
                    if let handle = try? FileHandle(forWritingTo: currentLogFile) {
                        handle.seekToEndOfFile()
                        handle.write(data)
                        handle.closeFile()
                    }
                } else {
                    try? data.write(to: currentLogFile)
                }
            }
        }
    }

    /// 日志轮转: 当前文件超过 maxFileSize 时归档
    private func rotateIfNeeded() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: currentLogFile.path),
              let attrs = try? fm.attributesOfItem(atPath: currentLogFile.path),
              let size = attrs[.size] as? Int64,
              size > maxFileSize else { return }

        // 归档: ehviewer.log → ehviewer_20260216_120000.log
        let archiveName = "ehviewer_\(dateStamp()).log"
        let archiveURL = logDirectory.appendingPathComponent(archiveName)
        try? fm.moveItem(at: currentLogFile, to: archiveURL)

        // 清理旧文件
        pruneOldFiles()
    }

    /// 删除超出 maxFileCount 的最旧日志
    private func pruneOldFiles() {
        let files = allLogFiles().filter { $0.lastPathComponent != "ehviewer.log" }
        if files.count > maxFileCount {
            let toDelete = files.suffix(from: maxFileCount)
            for file in toDelete {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private func dateStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }

    private func systemInfo() -> String {
        #if os(iOS)
        return "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        #else
        return "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        #endif
    }

    private func appVersion() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

// MARK: - 全局便捷函数

/// 全局日志函数 — 替代 print() 使用
public func Log(_ message: String, level: LogLevel = .info, category: String = "General",
                file: String = #fileID, line: Int = #line) {
    LogManager.shared.info(message, category: category, file: file, line: line)
}

public func LogError(_ message: String, category: String = "General",
                     file: String = #fileID, line: Int = #line) {
    LogManager.shared.error(message, category: category, file: file, line: line)
}

public func LogWarning(_ message: String, category: String = "General",
                       file: String = #fileID, line: Int = #line) {
    LogManager.shared.warning(message, category: category, file: file, line: line)
}
