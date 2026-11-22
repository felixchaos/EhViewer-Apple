import Foundation

/// Reading progress persisted by gallery ID. The on-disk key and zero-based
/// page index are shared with the existing history, detail and preview UI.
struct ReaderProgressStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func savedPage(for galleryID: Int64) -> Int? {
        defaults.object(forKey: key(for: galleryID)) as? Int
    }

    func save(_ page: Int, for galleryID: Int64) {
        defaults.set(page, forKey: key(for: galleryID))
    }

    /// Nil means to keep the current page. In particular, an explicit but
    /// out-of-range request must not silently become a resume.
    func openingPage(for galleryID: Int64, requested: Int?, pageCount: Int) -> Int? {
        if let requested {
            return (0..<max(0, pageCount)).contains(requested) ? requested : nil
        }
        guard pageCount > 0, let saved = savedPage(for: galleryID) else { return nil }
        return min(saved, pageCount - 1)
    }

    private func key(for galleryID: Int64) -> String { "reading_progress_\(galleryID)" }
}
