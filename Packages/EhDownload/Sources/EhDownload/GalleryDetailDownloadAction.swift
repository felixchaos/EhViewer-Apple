/// The available detail-page action implied by the gallery's queue state.
/// Presentation converts these cases to localized labels/icons without changing
/// download ownership, offline readiness, or reader routing.
public enum GalleryDetailDownloadAction: Equatable, Sendable {
    case enqueue
    case resume
    case retry
    case queued
    case downloading
    case openReader

    public init(state: Int) {
        switch state {
        case DownloadManager.stateNone: self = .resume
        case DownloadManager.stateFailed: self = .retry
        case DownloadManager.stateWait: self = .queued
        case DownloadManager.stateDownload: self = .downloading
        case DownloadManager.stateFinish: self = .openReader
        default: self = .enqueue
        }
    }

    public var isActionable: Bool {
        switch self {
        case .queued, .downloading: false
        case .enqueue, .resume, .retry, .openReader: true
        }
    }
}
