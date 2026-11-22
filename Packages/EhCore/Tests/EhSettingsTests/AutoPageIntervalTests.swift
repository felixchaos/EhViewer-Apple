import Foundation
import Testing
@testable import EhSettings

@Suite struct AutoPageIntervalTests {
    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "EhViewer.AutoPageIntervalTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test(arguments: [1, 5, 60])
    func stockValuesSurviveBackupAndSettingsAccessor(_ interval: Int) throws {
        try withIsolatedDefaults { defaults in
            let archive = Data("{\"auto_page_interval\":\(interval),\"show_read_progress\":true}".utf8)
            let report = try SettingsBackup.restoreJSON(archive, into: defaults)
            #expect(report.appliedCount == 2)
            #expect(AppSettings(defaults: defaults).autoPageInterval == interval)
            #expect(defaults.bool(forKey: "show_read_progress"))
            let exported = try #require(try JSONSerialization.jsonObject(with: SettingsBackup.exportJSON(from: defaults)) as? [String: Any])
            #expect(exported["auto_page_interval"] as? Int == interval)
        }
    }

    @Test(arguments: ["-1", "0", "61", "9223372036854775807", "true", "1.5"])
    func malformedBackupRejectsEverythingWithoutPartialWrites(_ rawInterval: String) throws {
        try withIsolatedDefaults { defaults in
            defaults.set(10, forKey: AppSettings.autoPageIntervalKey)
            defaults.set(false, forKey: "show_read_progress")
            let archive = Data("{\"show_read_progress\":true,\"auto_page_interval\":\(rawInterval)}".utf8)
            #expect(throws: SettingsBackup.RestoreError.invalidValue(key: AppSettings.autoPageIntervalKey)) {
                try SettingsBackup.restoreJSON(archive, into: defaults)
            }
            #expect(defaults.integer(forKey: AppSettings.autoPageIntervalKey) == 10)
            #expect(!defaults.bool(forKey: "show_read_progress"))
        }
    }

    @Test func alreadyPersistedBadValuesUseAndExportTheDefault() throws {
        try withIsolatedDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            #expect(settings.autoPageInterval == 5)
            for invalid in [Int.min, -1, 0, 61, Int.max] {
                defaults.set(invalid, forKey: AppSettings.autoPageIntervalKey)
                #expect(settings.autoPageInterval == 5)
            }
            let archive = try SettingsBackup.exportJSON(from: defaults)
            let exported = try #require(try JSONSerialization.jsonObject(with: archive) as? [String: Any])
            #expect(exported["auto_page_interval"] as? Int == 5)
            _ = try SettingsBackup.restoreJSON(archive, into: defaults)
            #expect(defaults.integer(forKey: AppSettings.autoPageIntervalKey) == 5)
            settings.autoPageInterval = -8
            #expect(defaults.integer(forKey: AppSettings.autoPageIntervalKey) == 5)
            settings.autoPageInterval = 60
            #expect(defaults.integer(forKey: AppSettings.autoPageIntervalKey) == 60)
        }
    }
}
