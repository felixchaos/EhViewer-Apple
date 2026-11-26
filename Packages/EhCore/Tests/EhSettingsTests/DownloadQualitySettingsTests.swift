import Foundation
import Testing
@testable import EhSettings

struct DownloadQualitySettingsTests {
    @Test func readsLegacyPreferencesUntilUserChoosesAnIndependentDefault() throws {
        let suite = "EhViewer.DownloadQualityTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.defaultDownloadQuality == .auto)
        settings.imageResolution = .x980
        #expect(settings.defaultDownloadQuality == .x980)
        settings.downloadOriginImage = true
        #expect(settings.defaultDownloadQuality == .original)
        settings.defaultDownloadQuality = .x1600
        #expect(settings.imageResolution == .x980)
        #expect(settings.downloadOriginImage)
        #expect(AppSettings(defaults: defaults).defaultDownloadQuality == .x1600)
        let backup = try SettingsBackup.exportJSON(from: defaults)
        let export = try #require(try JSONSerialization.jsonObject(with: backup) as? [String: Any])
        #expect(export["default_download_quality"] as? String == "1600")
    }

    @Test func restoresQualityAndRejectsAnUnsupportedValueWithoutWritingIt() throws {
        let suite = "EhViewer.DownloadQualityTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        _ = try SettingsBackup.restoreJSON(Data(#"{"default_download_quality":"original"}"#.utf8), into: defaults)
        #expect(settings.defaultDownloadQuality == .original)
        #expect(throws: SettingsBackup.RestoreError.invalidValue(key: "default_download_quality")) {
            try SettingsBackup.restoreJSON(Data(#"{"default_download_quality":"unrecognized"}"#.utf8), into: defaults)
        }
        #expect(settings.defaultDownloadQuality == .original)
    }
}
