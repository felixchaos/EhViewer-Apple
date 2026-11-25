import EhModels
import Foundation
import Testing
@testable import ehviewer_apple

@MainActor
struct GalleryAuxiliaryRecoveryTests {
    private enum Failure: Error { case offline }

    private func previews(_ positions: [Int]) -> PreviewSet {
        .large(positions.map { LargePreview(position: $0) })
    }

    @Test func previewJumpFindsOnlyTheExactPositionAndStopsAtTheLastPage() async throws {
        let model = GalleryPreviewsViewModel(seed: previews([0, 4]), totalPages: 3)
        var pages: [Int] = []
        let found = try await model.loadUpTo(position: 2) { page in
            pages.append(page)
            // An overlapping preview and a position greater than the target
            // must not stop the search early, even if the target never appears.
            return self.previews([4, page + 4])
        }
        #expect(!found)
        #expect(pages == [1, 2])
        #expect(model.allPreviews.map(\.position) == [0, 4, 5, 6])
    }

    @Test func failedPreviewPageRetainsDataAndIsRetriedBeforeScrolling() async throws {
        let model = GalleryPreviewsViewModel(seed: previews([0]), totalPages: 4)
        var pages: [Int] = []
        do {
            _ = try await model.loadUpTo(position: 1) { page in
                pages.append(page)
                throw Failure.offline
            }
            Issue.record("Expected preview request to fail")
        } catch Failure.offline {}
        #expect(model.pageFailed)
        #expect(model.nextPage == 1)
        #expect(model.allPreviews.map(\.position) == [0])
        let found = try await model.loadUpTo(position: 1) { page in
            pages.append(page)
            return self.previews([1, 1])
        }
        #expect(found && !model.pageFailed)
        #expect(pages == [1, 1])
        #expect(model.allPreviews.map(\.position) == [0, 1])
    }

    @Test func previewJumpJoinsAnInFlightGridRequest() async throws {
        let model = GalleryPreviewsViewModel(seed: previews([0]), totalPages: 3)
        let started = Gate(), unblock = Gate(), jumpStarted = Gate()
        let grid = Task {
            try await model.loadNextPage { page in
                #expect(page == 1)
                started.open()
                await unblock.wait()
                return self.previews([1])
            }
        }
        await started.wait()
        let jump = Task {
            jumpStarted.open()
            return try await model.loadUpTo(position: 1) { _ in
                Issue.record("A second fetch was started for an existing request")
                return self.previews([])
            }
        }
        await jumpStarted.wait()
        unblock.open()
        #expect(try await grid.value)
        #expect(try await jump.value)
        #expect(model.nextPage == 2)
    }

    @Test func aCancelledPreviewRequestCannotCommitALateResponse() async throws {
        let model = GalleryPreviewsViewModel(seed: previews([0]), totalPages: 2)
        let started = Gate(), unblock = Gate()
        let jump = Task {
            try await model.loadUpTo(position: 7) { _ in
                started.open()
                await unblock.wait()
                return self.previews([7])
            }
        }
        await started.wait()
        model.cancelPageRequest()
        unblock.open()
        do {
            _ = try await jump.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {}
        #expect(!model.pageFailed && !model.isLoadingMore)
        #expect(model.nextPage == 1)
        #expect(model.allPreviews.map(\.position) == [0])
    }

    @Test func allCommentsFailurePreservesSeedAndExplicitRetryReplacesIt() async {
        let model = GalleryCommentsViewModel(comments: [GalleryComment(id: 1)], hasMore: true)
        await model.loadAllComments { throw Failure.offline }
        #expect(model.comments.map(\.id) == [1])
        #expect(model.hasMore && model.loadFailed && !model.isLoading)
        await model.loadAllComments {
            GalleryCommentList(comments: [GalleryComment(id: 1), GalleryComment(id: 2)])
        }
        #expect(model.comments.map(\.id) == [1, 2])
        #expect(!model.hasMore && !model.loadFailed && !model.isLoading)
    }

    @Test func cancelledCommentLoadCannotReplaceANewerResult() async {
        let model = GalleryCommentsViewModel(comments: [GalleryComment(id: 1)], hasMore: true)
        let started = Gate(), unblock = Gate()
        let load = Task {
            await model.loadAllComments {
                started.open()
                await unblock.wait()
                return GalleryCommentList(comments: [GalleryComment(id: 2)])
            }
        }
        await started.wait()
        model.cancelLoading()
        #expect(model.comments.map(\.id) == [1])
        #expect(model.hasMore && !model.loadFailed && !model.isLoading)
        await model.loadAllComments { GalleryCommentList(comments: [GalleryComment(id: 3)]) }
        unblock.open()
        await load.value
        #expect(model.comments.map(\.id) == [3])
    }

    @MainActor
    private final class Gate {
        private var opened = false
        private var waiter: CheckedContinuation<Void, Never>?
        func wait() async {
            if !opened { await withCheckedContinuation { waiter = $0 } }
        }
        func open() {
            opened = true
            waiter?.resume()
            waiter = nil
        }
    }
}
