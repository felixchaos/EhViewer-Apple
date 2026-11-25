import Foundation
import Observation

private struct GitHubRelease: Decodable {
    let tagName: String
    let body: String?
    let htmlUrl: String
    let draft: Bool
    let prerelease: Bool
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body, draft, prerelease, assets
        case htmlUrl = "html_url"
    }
}

private struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadUrl: String
    let size: Int
    let state: String?

    enum CodingKeys: String, CodingKey {
        case name, size, state
        case browserDownloadUrl = "browser_download_url"
    }
}

private struct AltStoreSource: Decodable {
    struct App: Decodable {
        struct Version: Decodable {
            let downloadURL: String
            let minOSVersion: String?
        }
        let bundleIdentifier: String
        let versions: [Version]
    }
    let apps: [App]
}

struct AppUpdateInfo: Sendable {
    let version: String
    let releaseNotes: String
    let releaseURL: URL
    let downloadURL: URL
}

enum AppUpdatePlatform {
    case iOS, macOS

    static var current: Self {
        #if os(macOS)
        .macOS
        #else
        .iOS
        #endif
    }

    var installationHint: String {
        switch self {
        case .iOS: "可通过 AltStore 或 SideStore 更新，也可下载 IPA 后重新签名安装。"
        case .macOS: "可下载适用于 Mac 的安装包。"
        }
    }

    fileprivate func priority(for name: String) -> Int? {
        let name = name.lowercased()
        switch self {
        case .iOS:
            return name.hasSuffix(".ipa") ? 0 : nil
        case .macOS:
            if name.hasSuffix(".dmg") { return 0 }
            if name.hasSuffix(".zip") && (name.contains("macos") || name.contains("-mac.")) { return 1 }
            return nil
        }
    }
}

/// Platform selection is independent of API order and accepts only the repository's uploaded assets.
enum AppUpdateCatalog {
    enum Result {
        case update(AppUpdateInfo)
        case alreadyLatest
        case noCompatibleRelease
    }

    private static let repositoryPath = "/felixchaos/EhViewer-Apple/releases/"
    static let feedURL = URL(string: "https://raw.githubusercontent.com/felixchaos/EhViewer-Apple/main/source.json")!

    static func select(
        releasePages: [Data], feed: Data? = nil, platform: AppUpdatePlatform,
        currentVersion: String, systemVersion: String
    ) throws -> Result {
        let decoder = JSONDecoder()
        let releases = try releasePages.flatMap { try decoder.decode([GitHubRelease].self, from: $0) }
        let minVersions = feed.flatMap { try? decoder.decode(AltStoreSource.self, from: $0) }?
            .apps.first { $0.bundleIdentifier == "Stellatrix.ehviewer-apple" }?.versions ?? []
        let osVersion = versionParts(systemVersion)
        let installed = versionParts(currentVersion) ?? [1, 0, 0]
        var best: (parts: [Int], info: AppUpdateInfo)?

        for release in releases where !release.draft && !release.prerelease {
            let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
            guard let parts = versionParts(version),
                  let releaseURL = trustedURL(release.htmlUrl, pathPrefix: repositoryPath + "tag/"),
                  let asset = release.assets.compactMap({ asset -> (priority: Int, url: URL)? in
                      guard asset.state == nil || asset.state == "uploaded", asset.size > 0,
                            let priority = platform.priority(for: asset.name),
                            let url = trustedURL(asset.browserDownloadUrl, pathPrefix: repositoryPath + "download/"),
                            url.lastPathComponent == asset.name else { return nil }
                      if platform == .iOS,
                         let minimum = minVersions.first(where: { $0.downloadURL == asset.browserDownloadUrl })?.minOSVersion,
                         let required = versionParts(minimum), let osVersion, compare(osVersion, required) < 0 {
                          return nil
                      }
                      return (priority, url)
                  }).min(by: { a, b in
                      a.priority == b.priority ? a.url.absoluteString < b.url.absoluteString : a.priority < b.priority
                  }) else { continue }
            if let best, compare(parts, best.parts) <= 0 { continue }
            best = (parts, AppUpdateInfo(
                version: version, releaseNotes: release.body ?? "暂无更新说明",
                releaseURL: releaseURL, downloadURL: asset.url
            ))
        }
        guard let best else { return .noCompatibleRelease }
        return compare(best.parts, installed) > 0 ? .update(best.info) : .alreadyLatest
    }

    static func pageCount(_ data: Data) throws -> Int {
        try JSONDecoder().decode([GitHubRelease].self, from: data).count
    }

    private static func trustedURL(_ raw: String, pathPrefix: String) -> URL? {
        guard let url = URL(string: raw), url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil, url.path.hasPrefix(pathPrefix) else { return nil }
        return url
    }

    private static func versionParts(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        return parts.reduce(into: [Int]?.some([])) { result, part in
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Int(part) else { result = nil; return }
            result?.append(number)
        }
    }

    private static func compare(_ lhs: [Int], _ rhs: [Int]) -> Int {
        for index in 0..<max(lhs.count, rhs.count) {
            let l = index < lhs.count ? lhs[index] : 0
            let r = index < rhs.count ? rhs[index] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }
}

/// GitHub Releases and platform-specific update guidance; no download or installation runs automatically.
@MainActor
@Observable
final class AppUpdateChecker {
    static let shared = AppUpdateChecker()
    private static let checkIntervalSeconds: TimeInterval = 24 * 60 * 60
    private static let releasesURL = "https://api.github.com/repos/felixchaos/EhViewer-Apple/releases"

    var isChecking = false
    var updateAvailable: AppUpdateInfo?
    var showUpdateAlert = false
    var checkError: String?

    private init() {}

    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0" }
    var currentBuild: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1" }

    func checkOnLaunchIfNeeded() async {
        let lastCheck = UserDefaults.standard.double(forKey: "last_update_check_time")
        guard Date().timeIntervalSince1970 - lastCheck > Self.checkIntervalSeconds else { return }
        await checkForUpdate(manual: false)
    }

    func checkManually() {
        Task { await checkForUpdate(manual: true) }
    }

    func checkForUpdate(manual: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        checkError = nil
        defer { isChecking = false }

        do {
            var pages: [Data] = []
            let platform = AppUpdatePlatform.current
            for page in 1...10 {
                let url = URL(string: "\(Self.releasesURL)?per_page=100&page=\(page)")!
                let data = try await fetch(url, timeout: 15)
                pages.append(data)
                if try AppUpdateCatalog.pageCount(data) < 100 { break }
            }
            // The feed can supply explicit iOS asset minimums. If unavailable, do not invent them.
            let feed = platform == .iOS ? try? await fetch(AppUpdateCatalog.feedURL, timeout: 5) : nil
            let os = ProcessInfo.processInfo.operatingSystemVersion
            switch try AppUpdateCatalog.select(
                releasePages: pages, feed: feed, platform: platform, currentVersion: currentVersion,
                systemVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
            ) {
            case .update(let info):
                updateAvailable = info
                showUpdateAlert = true
            case .alreadyLatest:
                updateAvailable = nil
                showUpdateAlert = false
                if manual { checkError = "already_latest" }
            case .noCompatibleRelease:
                updateAvailable = nil
                showUpdateAlert = false
                if manual { checkError = "暂无适用于此设备的安装包" }
            }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "last_update_check_time")
        } catch {
            if manual { checkError = "检查更新失败: \(error.localizedDescription)" }
        }
    }

    private func fetch(_ url: URL, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("EhViewer-Apple/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
