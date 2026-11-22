import EhSettings
import Foundation
import Testing

struct SettingsBackupTests {
    @Test func exportKeepsTheFlatArchiveKeysAndValues() throws {
        try withIsolatedDefaults { defaults in
            // The shipped archive contract, not a list derived from the new implementation.
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
                "color_filter": 0, "default_favorite_2": -2, "thumb_size": 1, "detail_size": 2,
                "thumb_resolution": 1, "fix_thumb_url": true, "enable_secure": false, "security_delay": 30,
                "save_parse_error_body": false, "history_info_size": 200, "theme": 2, "launch_page": 1,
                "show_gallery_pages": true, "cellular_network_warning": false,
                "custom_screen_lightness": true, "screen_lightness": 75,
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
        }
    }

    @Test func restoreOverlaysKnownAndLegacyKeysWithoutClearingOtherPreferences() throws {
        try withIsolatedDefaults { defaults in
            defaults.set(1, forKey: "theme")
            defaults.set("locally retained", forKey: "unmentioned_fixture")
            defaults.set("retain category name", forKey: "fav_cat_1")
            let archive = Data("""
            {"theme":2,"show_jpn_title":true,"fav_cat_0":"Samples",
             "legacy_fixture":{"enabled":true,"values":[1,2]}}
            """.utf8)

            try SettingsBackup.restoreJSON(archive, into: defaults)
            #expect(defaults.integer(forKey: "theme") == 2)
            #expect(defaults.bool(forKey: "show_jpn_title"))
            #expect(defaults.string(forKey: "fav_cat_0") == "Samples")
            #expect(defaults.string(forKey: "fav_cat_1") == "retain category name")
            #expect(defaults.string(forKey: "unmentioned_fixture") == "locally retained")
            let legacy = try #require(defaults.dictionary(forKey: "legacy_fixture"))
            #expect(legacy["enabled"] as? Bool == true)
            #expect(legacy["values"] as? [Int] == [1, 2])
        }
    }

    @Test func anEmptyArchiveIsAnOverlayNoOp() throws {
        try withIsolatedDefaults { defaults in
            defaults.set(2, forKey: "theme")
            try SettingsBackup.restoreJSON(Data("{}".utf8), into: defaults)
            #expect(defaults.integer(forKey: "theme") == 2)
        }
    }

    @Test(arguments: ["{\"theme\":2,", "[{\"theme\":2}]", "SQLite format 3"])
    func rejectedInputDoesNotModifyPreferences(archive: String) throws {
        try withIsolatedDefaults { defaults in
            defaults.set(1, forKey: "theme")
            #expect(throws: (any Error).self) {
                try SettingsBackup.restoreJSON(Data(archive.utf8), into: defaults)
            }
            #expect(defaults.integer(forKey: "theme") == 1)
        }
    }

    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "EhViewer.SettingsBackupTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }
}
