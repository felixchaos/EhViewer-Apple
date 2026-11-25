import Foundation
import Testing
@testable import EhSettings

@Suite struct DownloadConcurrencyTests {
    @Test func freshDownloadsDefaultToThreeButRespectOne() throws {
        let suite = "EhDownloadConcurrencyTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.multiThreadDownload == 3)
        settings.multiThreadDownload = 1
        #expect(settings.multiThreadDownload == 1)
        #expect(AppSettings(defaults: defaults).multiThreadDownload == 1)
    }

    @Test func cancelledWaiterQuitsBeforeActiveImagesReleaseSlots() async throws {
        let limiter = EhRateLimiter()
        for _ in 0..<5 { try await limiter.acquireImageSlot() }
        let cancelled = Task { try await limiter.acquireImageSlot() }
        for _ in 0..<100 where await limiter.queuedImageWaiterCount == 0 {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await limiter.queuedImageWaiterCount == 1)
        cancelled.cancel()
        for _ in 0..<100 where await limiter.queuedImageWaiterCount != 0 {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await limiter.queuedImageWaiterCount == 0)
        // Release even if the expectation fails, so a regression cannot hang the test.
        for _ in 0..<5 { await limiter.releaseImageSlot() }
        do {
            try await cancelled.value
            await limiter.releaseImageSlot()
            Issue.record("A retired transfer still acquired a live slot")
        } catch is CancellationError {}
        try await limiter.acquireImageSlot()
        await limiter.releaseImageSlot()
    }
}
