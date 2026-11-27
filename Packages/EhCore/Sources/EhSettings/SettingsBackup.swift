import CoreFoundation
import Foundation

/// The flat JSON archive shared by the Apple settings import/export screens.
/// File access, sharing, and refreshing the active UI are the caller's responsibility.
public enum SettingsBackup {
    public static let automaticUpdateCheckKey = "automatically_check_app_updates"

    public enum RestoreError: Error, Equatable {
        case notJSONObject
        case invalidValue(key: String)
    }

    public struct RestoreReport: Equatable, Sendable {
        public let appliedCount: Int
        public let skippedObsoleteMediaScan: Bool
        public let skippedUnknownCount: Int
    }

    private enum ValueKind: Sendable {
        case boolean
        case integer
        case integerRange(ClosedRange<Int>)
        case string
        case downloadQuality

        func accepts(_ value: Any) -> Bool {
            switch self {
            case .boolean:
                guard let number = value as? NSNumber else { return false }
                return CFGetTypeID(number) == CFBooleanGetTypeID()
            case .integer, .integerRange:
                guard let number = value as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(),
                      let integer = number as? Int else { return false }
                if case .integerRange(let valid) = self { return valid.contains(integer) }
                return true
            case .string:
                return value is String
            case .downloadQuality:
                guard let raw = value as? String else { return false }
                return DownloadQuality(rawValue: raw) != nil
            }
        }
    }

    // These types match the setters and registered defaults in AppSettings, including
    // the integer raw values for gallery site/list mode and the string for resolution.
    private static let preferenceKinds: [String: ValueKind] = [
        "gallery_site": .integer, "domain_fronting": .boolean, "dns_over_https": .boolean,
        "built_in_hosts": .boolean, "multi_thread_download": .integer, "preload_image": .integer,
        "download_delay": .integer, "download_timeout": .integer, "download_origin_image": .boolean,
        "default_download_quality": .downloadQuality,
        "image_resolution": .string, "read_cache_size": .integer, "list_mode": .integer,
        "show_jpn_title": .boolean, "show_tag_translations": .boolean, "show_gallery_comment": .boolean,
        "show_gallery_rating": .boolean, "show_read_progress": .boolean, "wide_screen_list_mode": .integer,
        "show_eh_events": .boolean, "show_eh_limits": .boolean, "default_categories": .integer,
        "excluded_tag_namespaces": .integer, "excluded_languages": .string, "reading_direction": .integer,
        "page_scaling": .integer, "start_position": .integer, "keep_screen_on": .boolean,
        "reading_fullscreen": .boolean, "gallery_show_clock": .boolean, "gallery_show_progress": .boolean,
        "gallery_show_battery": .boolean, "show_page_interval": .boolean, "volume_page": .boolean,
        "reverse_volume_page": .boolean, "screen_rotation": .integer,
        AppSettings.autoPageIntervalKey: .integerRange(AppSettings.autoPageIntervalRange),
        "color_filter": .boolean, "default_favorite_2": .integer, "thumb_size": .integer,
        "detail_size": .integer, "thumb_resolution": .integer, "fix_thumb_url": .boolean,
        "enable_secure": .boolean, "security_delay": .integer, "save_parse_error_body": .boolean,
        "history_info_size": .integer, "theme": .integer, "launch_page": .integer,
        "show_gallery_pages": .boolean, "cellular_network_warning": .boolean,
        "custom_screen_lightness": .boolean, "screen_lightness": .integer,
        automaticUpdateCheckKey: .boolean, "show_live_activity": .boolean,
        "sync_download_while_reading": .boolean,
    ]
    private static let favoriteKeys = (0..<10).map { "fav_cat_\($0)" }

    public static func exportJSON(from defaults: UserDefaults) throws -> Data {
        var archive: [String: Any] = [:]
        for key in preferenceKinds.keys {
            if let value = defaults.object(forKey: key) {
                if key == AppSettings.autoPageIntervalKey {
                    // Export the effective value rather than a stale invalid value
                    // restored by older builds, so the archive can be restored later.
                    archive[key] = AppSettings.validAutoPageInterval(value as? Int)
                } else {
                    archive[key] = value
                }
            }
        }

        for key in favoriteKeys {
            if let name = defaults.string(forKey: key) {
                archive[key] = name
            }
        }
        return try JSONSerialization.data(withJSONObject: archive, options: .prettyPrinted)
    }

    /// Restore the active app's settings and publish changed website preferences
    /// only after the entire archive has been validated and applied.
    @MainActor
    public static func restoreAppJSON(_ data: Data) throws -> RestoreReport {
        let previous = EhConfigSync.Preferences(settings: .shared)
        let report = try restoreJSON(data, into: .standard)
        if previous != EhConfigSync.Preferences(settings: .shared) {
            EhConfigSync.apply()
        }
        return report
    }

    public static func restoreJSON(_ data: Data, into defaults: UserDefaults) throws -> RestoreReport {
        guard let archive = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RestoreError.notJSONObject
        }

        var updates: [String: Any] = [:]
        var skippedObsoleteMediaScan = false
        var skippedUnknownCount = 0

        // Validate the entire supported payload before changing preferences. All supported
        // settings are scalars, so neither null nor a collection can reach UserDefaults.
        for (key, value) in archive {
            if key == "media_scan" {
                guard ValueKind.boolean.accepts(value) else { throw RestoreError.invalidValue(key: key) }
                // Older Apple versions exported this unused Android-only toggle.
                skippedObsoleteMediaScan = true
                continue
            }
            let kind = preferenceKinds[key] ?? (favoriteKeys.contains(key) ? .string : nil)
            guard let kind else {
                skippedUnknownCount += 1
                continue
            }
            guard kind.accepts(value) else { throw RestoreError.invalidValue(key: key) }
            updates[key] = value
        }

        // An online-only restore should not change the inherited download
        // quality. Explicit or legacy download fields retain their archive behavior.
        if let raw = updates["image_resolution"] as? String,
           updates["default_download_quality"] == nil, updates["download_origin_image"] == nil,
           defaults.string(forKey: "default_download_quality").flatMap(DownloadQuality.init(rawValue:)) == nil {
            let previous = defaults.string(forKey: "image_resolution").flatMap(ImageResolution.init(rawValue:)) ?? .auto
            let incoming = ImageResolution(rawValue: raw) ?? .auto
            if incoming != previous {
                let inherited = defaults.bool(forKey: "download_origin_image") ? .original
                    : (DownloadQuality(rawValue: previous.rawValue) ?? .auto)
                defaults.set(inherited.rawValue, forKey: "default_download_quality")
            }
        }

        // Overlay only the recognized incoming values; absent preferences are untouched.
        for (key, value) in updates {
            defaults.set(value, forKey: key)
        }
        return RestoreReport(
            appliedCount: updates.count,
            skippedObsoleteMediaScan: skippedObsoleteMediaScan,
            skippedUnknownCount: skippedUnknownCount
        )
    }
}
