import EhDatabase
import EhModels
import EhSettings
import Foundation

/// The persisted representation of a queue entry. Filesystem discovery and I/O
/// stay with the manager; the mapper does not access the singleton or user paths.
enum DownloadTaskPersistence {
    static func record(for task: DownloadTask, date: Date? = nil) -> DownloadRecord {
        let gallery = task.gallery
        var record = DownloadRecord(
            gid: gallery.gid, token: gallery.token,
            // Preserve the existing canonical title and resulting directory path.
            title: gallery.bestTitle, titleJpn: gallery.titleJpn,
            thumb: gallery.thumb, category: gallery.category.rawValue,
            posted: gallery.posted, uploader: gallery.uploader,
            rating: gallery.rating, simpleLanguage: gallery.simpleLanguage,
            pages: gallery.pages, state: task.state, label: task.label, date: date ?? task.createdAt
        )
        record.simpleTags = gallery.simpleTags
        record.quality = task.quality?.rawValue
        return record
    }

    static func restore(_ record: DownloadRecord, storedPageCount: (GalleryInfo) -> Int) -> DownloadTask {
        let gallery = GalleryInfo(
            gid: record.gid, token: record.token,
            title: record.title, titleJpn: record.titleJpn,
            thumb: record.thumb, category: EhCategory(rawValue: record.category),
            posted: record.posted, uploader: record.uploader,
            rating: record.rating, pages: record.pages,
            simpleTags: record.simpleTags, simpleLanguage: record.simpleLanguage
        )
        var task = DownloadTask(gallery: gallery, label: record.label, state: record.state, createdAt: record.date,
                                quality: record.quality.flatMap(DownloadQuality.init(rawValue:)))
        // Preserve reported queue state. Reader offline readiness separately
        // checks the actual files; this value does not promise they're present.
        if record.state == DownloadManager.stateFinish {
            task.downloadedPages = gallery.pages
        } else if gallery.pages > 0 {
            task.downloadedPages = storedPageCount(gallery)
        }
        return task
    }
}
