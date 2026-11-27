import EhSettings
import Foundation
import Testing
@testable import ehviewer_apple

struct SettingsBackupTests {
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EH_OFFLINE_UNIT_TEST_HOST"] == "1"))
    func appRestoreUpdatesWebsiteCookiesWithoutChangingDownloadDefault() throws {
        try #require(EhUnitTestHost.isOffline)
        let store = UserDefaults.standard
        let keys = ["image_resolution", "thumb_resolution", "default_download_quality", "download_origin_image", "theme"]
        let previous = keys.map { ($0, store.object(forKey: $0)) }
        let jar = HTTPCookieStorage.shared
        let sites = [URL(string: "https://e-hentai.org/")!, URL(string: "https://exhentai.org/")!]
        func cookies() -> [HTTPCookie] {
            sites.flatMap { jar.cookies(for: $0) ?? [] }.filter { $0.name == "uconfig" }
        }
        let oldCookies = cookies()
        defer {
            for (key, value) in previous { store.set(value, forKey: key) }
            EhConfigSync.apply()
            for cookie in cookies() { jar.deleteCookie(cookie) }
            for cookie in oldCookies { jar.setCookie(cookie) }
        }

        store.set("780", forKey: "image_resolution")
        store.set(0, forKey: "thumb_resolution")
        store.set(false, forKey: "download_origin_image")
        store.removeObject(forKey: "default_download_quality")
        EhConfigSync.apply()
        let baseline = cookies().map(\.value)
        try #require(baseline.count == 2)
        #expect(baseline.allSatisfy { $0.split(separator: "-").contains("xr_780") })
        #expect(AppSettings.shared.defaultDownloadQuality == .x780)

        let invalid = Data(#"{"image_resolution":"1600","thumb_resolution":"bad"}"#.utf8)
        #expect(throws: SettingsBackup.RestoreError.invalidValue(key: "thumb_resolution")) {
            _ = try SettingsBackup.restoreAppJSON(invalid)
        }
        #expect(cookies().map(\.value) == baseline)
        #expect(store.string(forKey: "default_download_quality") == nil)

        _ = try SettingsBackup.restoreAppJSON(Data(#"{"theme":2}"#.utf8))
        #expect(cookies().map(\.value) == baseline)

        let accepted = try SettingsBackup.restoreAppJSON(Data(#"{"image_resolution":"1600","thumb_resolution":1}"#.utf8))
        #expect(accepted.appliedCount == 2)
        #expect(AppSettings.shared.imageResolution == .x1600)
        #expect(AppSettings.shared.defaultDownloadQuality == .x780)
        let current = cookies().map { $0.value.split(separator: "-") }
        #expect(current.count == 2)
        #expect(current.allSatisfy { $0.contains("xr_1600") && $0.contains("tp_l") })

        _ = try SettingsBackup.restoreAppJSON(Data(#"{"default_download_quality":"original"}"#.utf8))
        #expect(AppSettings.shared.defaultDownloadQuality == .original)
        #expect(cookies().map { $0.value.split(separator: "-") } == current)
    }

    @Test func exportKeepsTheFlatArchiveKeysAndValues() throws {
        try withIsolatedDefaults { defaults in
            // Explicit archive contract, not a list derived from the implementation.
            var expected: [String: Any] = [
                "gallery_site": 1, "domain_fronting": true, "dns_over_https": false, "built_in_hosts": false,
                "multi_thread_download": 3, "preload_image": 2, "download_delay": 1, "download_timeout": 45,
                "download_origin_image": false, "image_resolution": "auto", "read_cache_size": 256,
                "list_mode": 1, "show_jpn_title": true, "show_tag_translations": false,
                "show_gallery_comment": true, "show_gallery_rating": false, "show_read_progress": true,
                "wide_screen_list_mode": 0, "show_eh_events": false, "show_eh_limits": true,
                "default_categories": 31, "excluded_tag_namespaces": 2, "excluded_languages": "en",
                "reading_direction": 1, "page_scaling": 3, "start_position": 0, "keep_screen_on": true,
                "reading_fullscreen": false, "gallery_show_clock": true, "gallery_show_progress": true,
                "gallery_show_battery": false, "show_page_interval": true, "volume_page": false,
                "reverse_volume_page": false, "screen_rotation": 0, "auto_page_interval": 6,
                "color_filter": false, "default_favorite_2": -2, "thumb_size": 1, "detail_size": 2,
                "thumb_resolution": 1, "fix_thumb_url": true, "enable_secure": false, "security_delay": 30,
                "save_parse_error_body": false, "history_info_size": 200, "theme": 2, "launch_page": 1,
                "show_gallery_pages": true, "cellular_network_warning": false,
                "custom_screen_lightness": true, "screen_lightness": 75,
                "automatically_check_app_updates": false, "show_live_activity": false,
                "sync_download_while_reading": true,
            ]
            for index in 0..<10 {
                expected["fav_cat_\(index)"] = index == 0 ? "" : "Sample \(index)"
            }
            for (key, value) in expected {
                defaults.set(value, forKey: key)
            }
            defaults.set("example.invalid", forKey: "proxy_host")
            defaults.set("not in archive", forKey: "fav_cat_10")
            defaults.set("not in archive", forKey: "local_fixture_only")

            let encoded = try SettingsBackup.exportJSON(from: defaults)
            let decoded = try JSONSerialization.jsonObject(with: encoded)
            let actualJSON = try JSONSerialization.data(withJSONObject: decoded, options: .sortedKeys)
            let expectedJSON = try JSONSerialization.data(withJSONObject: expected, options: .sortedKeys)
            #expect(actualJSON == expectedJSON)

            try withIsolatedDefaults { restored in
                let report = try SettingsBackup.restoreJSON(encoded, into: restored)
                #expect(report.appliedCount == expected.count)
                #expect(!report.skippedObsoleteMediaScan)
                #expect(report.skippedUnknownCount == 0)

                let roundTrip = try SettingsBackup.exportJSON(from: restored)
                let roundTripObject = try JSONSerialization.jsonObject(with: roundTrip)
                let roundTripJSON = try JSONSerialization.data(withJSONObject: roundTripObject, options: .sortedKeys)
                #expect(roundTripJSON == expectedJSON)
            }
        }
    }

    @Test func mixedArchiveOverlaysSupportedKeysAndReportsEachKindOfSkip() throws {
        try withIsolatedDefaults { defaults in
            defaults.set(1, forKey: "theme")
            defaults.set("locally retained", forKey: "unmentioned_fixture")
            defaults.set("retain category name", forKey: "fav_cat_1")
            defaults.set("prior.example.invalid", forKey: "proxy_host")
            defaults.set(false, forKey: "media_scan")
            let archive = Data("""
            {"theme":2,"show_jpn_title":true,"fav_cat_0":"Samples","media_scan":true,
             "proxy_host":"ignored.example.invalid","extra_fixture":{"nested":[null]}}
            """.utf8)

            let report = try SettingsBackup.restoreJSON(archive, into: defaults)
            #expect(report.appliedCount == 3)
            #expect(report.skippedObsoleteMediaScan)
            #expect(report.skippedUnknownCount == 2)
            #expect(defaults.integer(forKey: "theme") == 2)
            #expect(defaults.bool(forKey: "show_jpn_title"))
            #expect(defaults.string(forKey: "fav_cat_0") == "Samples")
            #expect(defaults.string(forKey: "fav_cat_1") == "retain category name")
            #expect(defaults.string(forKey: "unmentioned_fixture") == "locally retained")
            #expect(defaults.string(forKey: "proxy_host") == "prior.example.invalid")
            #expect(!defaults.bool(forKey: "media_scan"))
            #expect(defaults.object(forKey: "extra_fixture") == nil)
        }
    }

    @Test func restoresExplicitSwitchChoicesWithoutResettingOlderOverlays() throws {
        try withIsolatedDefaults { source in
            source.set(false, forKey: "automatically_check_app_updates")
            source.set(false, forKey: "show_live_activity")
            source.set(true, forKey: "sync_download_while_reading")
            let data = try SettingsBackup.exportJSON(from: source)
            let archive = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let switches = Set(["automatically_check_app_updates", "show_live_activity", "sync_download_while_reading"])
            // UserDefaults suite names isolate writes, but do not hide the hosted app's registered defaults.
            let switchOverlay = try JSONSerialization.data(withJSONObject: archive.filter { switches.contains($0.key) })
            try withIsolatedDefaults { target in
                target.set(true, forKey: "automatically_check_app_updates")
                target.set(true, forKey: "show_live_activity")
                target.set(false, forKey: "sync_download_while_reading")
                let rejected = Data(#"{"automatically_check_app_updates":false,"show_live_activity":false,"sync_download_while_reading":1}"#.utf8)
                #expect(throws: SettingsBackup.RestoreError.invalidValue(key: "sync_download_while_reading")) {
                    _ = try SettingsBackup.restoreJSON(rejected, into: target)
                }
                #expect(target.bool(forKey: "automatically_check_app_updates"))
                #expect(target.bool(forKey: "show_live_activity"))
                #expect(!target.bool(forKey: "sync_download_while_reading"))

                let report = try SettingsBackup.restoreJSON(switchOverlay, into: target)
                #expect(report.appliedCount == 3)
                #expect(report.skippedUnknownCount == 0)
                _ = try SettingsBackup.restoreJSON(Data(#"{"theme":2}"#.utf8), into: target)
                #expect(!target.bool(forKey: "automatically_check_app_updates"))
                #expect(!target.bool(forKey: "show_live_activity"))
                #expect(target.bool(forKey: "sync_download_while_reading"))
            }
        }
    }

    @Test func allUnknownFieldsAreReportedWithoutWritingAnything() throws {
        try withIsolatedDefaults { defaults in
            defaults.set(2, forKey: "theme")
            let archive = Data("""
            {"fav_cat_10":"skip","fav_cat_00":"skip","FAV_CAT_9":"skip","extra_fixture":null}
            """.utf8)

            let report = try SettingsBackup.restoreJSON(archive, into: defaults)
            #expect(report.appliedCount == 0)
            #expect(!report.skippedObsoleteMediaScan)
            #expect(report.skippedUnknownCount == 4)
            #expect(defaults.integer(forKey: "theme") == 2)
            for key in ["fav_cat_10", "fav_cat_00", "FAV_CAT_9", "extra_fixture"] {
                #expect(defaults.object(forKey: key) == nil)
            }
        }
    }

    @Test func anEmptyArchiveIsAnOverlayNoOp() throws {
        try withIsolatedDefaults { defaults in
            defaults.set(2, forKey: "theme")
            let report = try SettingsBackup.restoreJSON(Data("{}".utf8), into: defaults)
            #expect(report.appliedCount == 0)
            #expect(!report.skippedObsoleteMediaScan)
            #expect(report.skippedUnknownCount == 0)
            #expect(defaults.integer(forKey: "theme") == 2)
        }
    }

    @Test(arguments: ["{\"theme\":2,", "[{\"theme\":2}]", "SQLite format 3"])
    func rejectedDocumentDoesNotModifyPreferences(archive: String) throws {
        try withIsolatedDefaults { defaults in
            defaults.set(1, forKey: "theme")
            #expect(throws: (any Error).self) {
                _ = try SettingsBackup.restoreJSON(Data(archive.utf8), into: defaults)
            }
            #expect(defaults.integer(forKey: "theme") == 1)
        }
    }

    @Test(arguments: [
        #""theme":null"#,
        #""theme":true"#,
        #""theme":"2""#,
        #""theme":2.5"#,
        #""theme":9223372036854775808"#,
        #""show_jpn_title":1"#,
        #""show_jpn_title":"true""#,
        #""image_resolution":{"nested":[null]}"#,
        #""fav_cat_0":["not a name"]"#,
        #""media_scan":null"#,
    ])
    func invalidSupportedValueRejectsWholeOverlay(_ invalidMember: String) throws {
        try withIsolatedDefaults { defaults in
            defaults.set(1, forKey: "launch_page")
            let invalidKey = String(invalidMember.split(separator: "\"")[0])
            let archive = Data("{\"launch_page\":2,\(invalidMember)}".utf8)

            #expect(throws: SettingsBackup.RestoreError.invalidValue(key: invalidKey)) {
                _ = try SettingsBackup.restoreJSON(archive, into: defaults)
            }
            #expect(defaults.integer(forKey: "launch_page") == 1)
        }
    }

    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "EhViewer.SettingsBackupTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }
}
