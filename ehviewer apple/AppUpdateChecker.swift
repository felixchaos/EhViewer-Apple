//
//  AppUpdateChecker.swift
//  ehviewer apple
//
//  App 更新检查器 — 对齐 Android AppUpdater 逻辑
//  使用 GitHub Releases API 检测新版本，提示用户更新
//  参考: https://github.com/felixchaos/EhViewer-Apple/releases
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

/// GitHub Release API 响应模型
private struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlUrl: String
    let prerelease: Bool
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlUrl = "html_url"
        case prerelease
        case assets
    }
}

private struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadUrl: String
    let size: Int

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
        case size
    }
}

/// 更新检查结果
struct AppUpdateInfo: Sendable {
    let version: String
    let releaseNotes: String
    let releaseURL: URL
    let downloadURL: URL?
    let isPrerelease: Bool
}

/// App 更新检查器 (对齐 Android AppUpdater)
///
/// 功能:
/// - 启动时自动检查 (24 小时间隔)
/// - 设置中手动检查
/// - 比较语义化版本号 (major.minor.patch)
/// - 展示更新日志并引导用户下载
@Observable
final class AppUpdateChecker: @unchecked Sendable {
    static let shared = AppUpdateChecker()

    /// GitHub 仓库 Releases API
    private static let releasesURL = "https://api.github.com/repos/felixchaos/EhViewer-Apple/releases/latest"

    /// 检查间隔: 24 小时
    private static let checkIntervalSeconds: TimeInterval = 24 * 60 * 60

    // MARK: - Observable State

    var isChecking = false
    var updateAvailable: AppUpdateInfo?
    var showUpdateAlert = false
    var checkError: String?

    // MARK: - Private

    private init() {}

    /// 当前 App 版本号 (从 Info.plist 读取)
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    /// 当前 Build 号
    var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    // MARK: - 自动检查 (启动时)

    /// 启动时自动检查 — 仅在距上次检查超过 24 小时时触发
    func checkOnLaunchIfNeeded() {
        let lastCheck = UserDefaults.standard.double(forKey: "last_update_check_time")
        let now = Date().timeIntervalSince1970
        guard now - lastCheck > Self.checkIntervalSeconds else { return }

        Task {
            await checkForUpdate(manual: false)
        }
    }

    // MARK: - 手动检查

    /// 手动检查更新 (设置页触发，无论间隔都检查)
    func checkManually() {
        Task {
            await checkForUpdate(manual: true)
        }
    }

    // MARK: - Core Logic

    @MainActor
    func checkForUpdate(manual: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        checkError = nil
        defer { isChecking = false }

        do {
            guard let url = URL(string: Self.releasesURL) else {
                if manual { checkError = "无效的更新地址" }
                return
            }

            var request = URLRequest(url: url)
            request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
            request.setValue("EhViewer-Apple/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 15

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                if manual { checkError = "无效的服务器响应" }
                return
            }

            guard httpResponse.statusCode == 200 else {
                if manual {
                    if httpResponse.statusCode == 404 {
                        checkError = "暂无发布版本"
                    } else {
                        checkError = "服务器错误 (\(httpResponse.statusCode))"
                    }
                }
                return
            }

            let decoder = JSONDecoder()
            let release = try decoder.decode(GitHubRelease.self, from: data)

            // 解析版本号 (去除 "v" 前缀)
            let remoteVersion = release.tagName.hasPrefix("v")
                ? String(release.tagName.dropFirst())
                : release.tagName

            // 比较版本号 (对齐 Android AppHelper.compareVersion)
            let comparison = Self.compareVersions(currentVersion, remoteVersion)

            if comparison < 0 {
                // 有新版本
                let releaseURL = URL(string: release.htmlUrl) ?? URL(string: "https://github.com/felixchaos/EhViewer-Apple/releases")!

                // 查找 IPA 或 ZIP 资产
                let downloadAsset = release.assets.first { asset in
                    let name = asset.name.lowercased()
                    return name.hasSuffix(".ipa") || name.hasSuffix(".zip") || name.hasSuffix(".dmg")
                }
                let downloadURL = downloadAsset.flatMap { URL(string: $0.browserDownloadUrl) }

                let info = AppUpdateInfo(
                    version: remoteVersion,
                    releaseNotes: release.body ?? "暂无更新说明",
                    releaseURL: releaseURL,
                    downloadURL: downloadURL,
                    isPrerelease: release.prerelease
                )

                self.updateAvailable = info
                self.showUpdateAlert = true
            } else {
                if manual {
                    checkError = "already_latest" // 特殊标记: 已是最新版本
                }
            }

            // 记录检查时间
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "last_update_check_time")

        } catch {
            if manual {
                checkError = "检查更新失败: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Version Comparison

    /// 语义化版本比较 (对齐 Android AppHelper.compareVersion)
    /// 返回: -1 (v1 < v2), 0 (v1 == v2), 1 (v1 > v2)
    static func compareVersions(_ v1: String, _ v2: String) -> Int {
        let parts1 = v1.split(separator: ".").compactMap { Int($0) }
        let parts2 = v2.split(separator: ".").compactMap { Int($0) }
        let maxLen = max(parts1.count, parts2.count)

        for i in 0..<maxLen {
            let p1 = i < parts1.count ? parts1[i] : 0
            let p2 = i < parts2.count ? parts2[i] : 0
            if p1 < p2 { return -1 }
            if p1 > p2 { return 1 }
        }
        return 0
    }
}
