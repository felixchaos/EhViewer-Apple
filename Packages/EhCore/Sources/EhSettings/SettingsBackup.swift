import Foundation

/// The flat JSON archive shared by the Apple settings import/export screens.
/// File access, sharing, and refreshing the active UI are the caller's responsibility.
public enum SettingsBackup {
    public enum RestoreError: Error {
        case notJSONObject
    }

    private static let exportKeys = [
        "gallery_site", "domain_fronting", "dns_over_https", "built_in_hosts",
        "multi_thread_download", "preload_image", "download_delay", "download_timeout",
        "download_origin_image", "image_resolution", "read_cache_size", "list_mode",
        "show_jpn_title", "show_tag_translations", "show_gallery_comment", "show_gallery_rating",
        "show_read_progress", "wide_screen_list_mode", "show_eh_events", "show_eh_limits",
        "default_categories", "excluded_tag_namespaces", "excluded_languages",
        "reading_direction", "page_scaling", "start_position", "keep_screen_on",
        "reading_fullscreen", "gallery_show_clock", "gallery_show_progress", "gallery_show_battery",
        "show_page_interval", "volume_page", "reverse_volume_page", "screen_rotation",
        "auto_page_interval", "color_filter", "default_favorite_2", "thumb_size",
        "detail_size", "thumb_resolution", "fix_thumb_url",
        "enable_secure", "security_delay", "save_parse_error_body", "history_info_size",
        "theme", "launch_page", "show_gallery_pages", "cellular_network_warning",
        "custom_screen_lightness", "screen_lightness",
    ]

    public static func exportJSON(from defaults: UserDefaults) throws -> Data {
        var archive: [String: Any] = [:]
        for key in exportKeys {
            if let value = defaults.object(forKey: key) {
                archive[key] = value
            }
        }

        for index in 0..<10 {
            let key = "fav_cat_\(index)"
            if let name = defaults.string(forKey: key) {
                archive[key] = name
            }
        }
        return try JSONSerialization.data(withJSONObject: archive, options: .prettyPrinted)
    }

    public static func restoreJSON(_ data: Data, into defaults: UserDefaults) throws {
        guard let archive = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RestoreError.notJSONObject
        }

        // The original importer is an overlay, not a replacement, and does not use
        // the export key list to filter older or hand-edited archives.
        for (key, value) in archive {
            defaults.set(value, forKey: key)
        }
    }
}
