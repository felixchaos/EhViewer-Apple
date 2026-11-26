import Foundation
import Testing
@testable import ehviewer_apple

struct AppUpdateCatalogTests {
    private let origin = "https://github.com/felixchaos/EhViewer-Apple/releases"

    private func release(_ tag: String, _ names: [String], draft: Bool = false, prerelease: Bool = false) -> [String: Any] {
        [
            "tag_name": tag, "body": "notes", "html_url": "\(origin)/tag/\(tag)",
            "draft": draft, "prerelease": prerelease,
            "assets": names.map { ["name": $0, "size": 100, "state": "uploaded", "browser_download_url": "\(origin)/download/\(tag)/\($0)"] }
        ]
    }

    @Test(arguments: [false, true])
    func macSkipsLatestIOSOnlyAndSelectsDMGRegardlessOfAssetOrder(reversed: Bool) throws {
        let mixed = ["EhViewer.ipa", "EhViewer-macOS.zip", "EhViewer.dmg"]
        let newerIOS = release("v1.3.4", ["EhViewer-1.3.4.ipa"])
        let oldMac = release("v1.3.1", reversed ? Array(mixed.reversed()) : mixed)
        let firstPage = try JSONSerialization.data(withJSONObject: [newerIOS])
        let secondPage = try JSONSerialization.data(withJSONObject: [oldMac])
        let info = try #require(update(AppUpdateCatalog.select(
            releasePages: [firstPage, secondPage], platform: .macOS, currentVersion: "1.2.0", systemVersion: "26.2"
        )))
        #expect(info.version == "1.3.1")
        #expect(info.downloadURL.lastPathComponent == "EhViewer.dmg")
    }

    @Test func macAlreadyOnLatestCompatibleIgnoresNewerIPAAndRejectsGenericZIP() throws {
        let page = try JSONSerialization.data(withJSONObject: [
            release("v1.3.4", ["EhViewer.ipa", "Source.zip"]),
            release("v1.3.1", ["EhViewer-macOS.zip"]),
        ])
        let result = try AppUpdateCatalog.select(
            releasePages: [page], platform: .macOS, currentVersion: "1.3.1", systemVersion: "26.2"
        )
        if case .alreadyLatest = result {} else { Issue.record("Expected latest compatible") }
        let none = try JSONSerialization.data(withJSONObject: [release("v2.0.0", ["EhViewer.ipa", "Source.zip"])])
        let missing = try AppUpdateCatalog.select(
            releasePages: [none], platform: .macOS, currentVersion: "1.3.1", systemVersion: "26.2"
        )
        if case .noCompatibleRelease = missing {} else { Issue.record("No usable macOS asset") }
    }

    @Test func iosLatestCompatibleIgnoresDraftPrereleaseMalformedAndExplicitUnsupportedMinimum() throws {
        let page = try JSONSerialization.data(withJSONObject: [
            release("v1.3.9", ["EhViewer.ipa"], draft: true),
            release("v1.3.10", ["EhViewer.dmg", "EhViewer.ipa"]),
            release("v1.3.bad", ["EhViewer.ipa"]),
            release("v1.3.20", ["EhViewer.ipa"], prerelease: true),
            release("v1.3.8", ["EhViewer.ipa"]),
        ])
        let feed = try JSONSerialization.data(withJSONObject: [
            "apps": [["bundleIdentifier": "Stellatrix.ehviewer-apple", "versions": [[
                "downloadURL": "\(origin)/download/v1.3.10/EhViewer.ipa", "minOSVersion": "27.0"
            ]]]]
        ])
        let lower = try #require(update(AppUpdateCatalog.select(
            releasePages: [page], feed: feed, platform: .iOS, currentVersion: "1.3.4", systemVersion: "26.6.2"
        )))
        let higher = try #require(update(AppUpdateCatalog.select(
            releasePages: [page], feed: feed, platform: .iOS, currentVersion: "1.3.4", systemVersion: "27.0.1"
        )))
        #expect(lower.version == "1.3.8")
        #expect(!lower.minimumSystemVersionVerified)
        #expect(higher.version == "1.3.10")
        #expect(higher.minimumSystemVersionVerified)
        #expect(higher.downloadURL.pathExtension == "ipa")
        #expect(AppUpdatePlatform.iOS.installationHint.contains("IPA"))
        #expect(AppUpdatePlatform.iOS.installationHint.contains("重新签名"))
        #expect(!AppUpdatePlatform.macOS.installationHint.contains("SideStore"))
    }

    @Test(arguments: ["missing", "stale", "malformed"])
    func ipaWithoutExactValidMinimumIsNotMarkedVerified(feedCase: String) throws {
        let page = try JSONSerialization.data(withJSONObject: [release("v2.0.0", ["EhViewer.ipa"])])
        let assetTag = feedCase == "stale" ? "v1.3.7" : "v2.0.0"
        let feed: Data? = feedCase == "missing" ? nil : try JSONSerialization.data(withJSONObject: [
            "apps": [["bundleIdentifier": "Stellatrix.ehviewer-apple", "versions": [[
                "downloadURL": "\(origin)/download/\(assetTag)/EhViewer.ipa",
                "minOSVersion": feedCase == "malformed" ? "unknown" : "18.0",
            ]]]]
        ])
        let info = try #require(update(AppUpdateCatalog.select(
            releasePages: [page], feed: feed, platform: .iOS, currentVersion: "1.3.7", systemVersion: "18.0"
        )))
        #expect(info.version == "2.0.0")
        #expect(!info.minimumSystemVersionVerified)
    }

    @Test func invalidOrForeignDownloadCannotBecomeUpdate() throws {
        var bogus = release("v2.1.0", ["EhViewer.ipa"])
        bogus["assets"] = [
            ["name": "EhViewer.ipa", "size": 100, "state": "uploaded", "browser_download_url": "https://example.com/EhViewer.ipa"],
            ["name": "EhViewer.ipa", "size": 0, "state": "open", "browser_download_url": "\(origin)/download/v2.1.0/EhViewer.ipa"]
        ]
        let page = try JSONSerialization.data(withJSONObject: [bogus])
        let result = try AppUpdateCatalog.select(
            releasePages: [page], platform: .iOS, currentVersion: "1.3.4", systemVersion: "27.0.1"
        )
        if case .noCompatibleRelease = result {} else { Issue.record("Unexpected package") }
    }

    @Test func highlightsUseOnlyExactPublishedVersionEvenWithoutAPlatformAsset() throws {
        var invalidLink = release("v1.3.7", ["EhViewer.ipa"])
        invalidLink["html_url"] = "\(origin)/tag/v1.3.8"
        let page = try JSONSerialization.data(withJSONObject: [
            release("v1.3.8", ["EhViewer.ipa"]),
            release("v1.3.7", ["EhViewer.ipa"], draft: true),
            release("v1.3.7", ["EhViewer.ipa"], prerelease: true),
            invalidLink,
            release("v1.3.7", []),
        ])
        let match = try AppUpdateCatalog.highlights(releasePages: [page], currentVersion: "1.3.7")
        let notes = try #require(match)
        #expect(notes.version == "1.3.7")
        #expect(notes.text == "notes")
        #expect(notes.url.lastPathComponent == "v1.3.7")
        #expect(try AppUpdateCatalog.highlights(releasePages: [page], currentVersion: "1.3.6") == nil)
    }

    @Test func neverOffersSameMarketingVersionOrAnAssetUnderTheWrongTag() throws {
        var otherTagAsset = release("v1.3.8", ["EhViewer.ipa"])
        otherTagAsset["assets"] = release("v1.3.6", ["EhViewer.ipa"])["assets"]
        let page = try JSONSerialization.data(withJSONObject: [
            otherTagAsset, release("v1.3.7", ["EhViewer.ipa"])
        ])
        let result = try AppUpdateCatalog.select(
            releasePages: [page], platform: .iOS, currentVersion: "1.3.7", systemVersion: "27.0.1"
        )
        if case .alreadyLatest = result {} else { Issue.record("Unknown newer builds must not be inferred") }
    }

    private func update(_ result: AppUpdateCatalog.Result) -> AppUpdateInfo? {
        if case .update(let info) = result { return info }
        return nil
    }
}
