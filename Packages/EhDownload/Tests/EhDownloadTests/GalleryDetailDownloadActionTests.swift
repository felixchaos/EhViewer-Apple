import EhDownload
import Testing

@Suite struct GalleryDetailDownloadActionTests {
    @Test func missingAndInterruptionStatesHaveDistinctActions() {
        #expect(GalleryDetailDownloadAction(state: DownloadManager.stateInvalid) == .enqueue)
        #expect(GalleryDetailDownloadAction(state: DownloadManager.stateNone) == .resume)
        #expect(GalleryDetailDownloadAction(state: DownloadManager.stateFailed) == .retry)
        #expect(GalleryDetailDownloadAction.enqueue.isActionable)
        #expect(GalleryDetailDownloadAction.resume.isActionable)
        #expect(GalleryDetailDownloadAction.retry.isActionable)
    }

    @Test func waitAndActiveOnlyShowStatusButCompletionCanOpenReader() {
        #expect(GalleryDetailDownloadAction(state: DownloadManager.stateWait) == .queued)
        #expect(GalleryDetailDownloadAction(state: DownloadManager.stateDownload) == .downloading)
        #expect(GalleryDetailDownloadAction(state: DownloadManager.stateFinish) == .openReader)
        #expect(!GalleryDetailDownloadAction.queued.isActionable)
        #expect(!GalleryDetailDownloadAction.downloading.isActionable)
        #expect(GalleryDetailDownloadAction.openReader.isActionable)
    }
}
