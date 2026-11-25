import Foundation
import Testing
@testable import EhSpider

private actor Trace {
    private(set) var arrivals: [Int] = []
    private(set) var finishes: [Int] = []
    private(set) var peak = 0
    private var active = 0
    private var attempts: [Int: Int] = [:]

    func enter(_ page: Int) -> Int {
        arrivals.append(page)
        active += 1
        peak = max(peak, active)
        attempts[page, default: 0] += 1
        return attempts[page, default: 0]
    }

    func finish(_ page: Int) {
        active -= 1
        finishes.append(page)
    }
}

@Suite struct DownloadPageBatchTests {
    @Test func independentPagesFinishWhileSlowPageDoesNotConsumeRetriesEarly() async {
        let trace = Trace()
        await DownloadPageBatch.run(pages: Array(0..<8), concurrency: 3, attemptLimit: 2, retryDelay: { _ in }) { page, final in
            let attempt = await trace.enter(page)
            try? await Task.sleep(for: page == 0 && attempt == 1 ? .milliseconds(180) : .milliseconds(10))
            await trace.finish(page)
            if page == 0 { #expect(final == (attempt == 2)) }
            return page == 0 && attempt == 1
        }
        let arrivals = await trace.arrivals
        let finishes = await trace.finishes
        #expect(await trace.peak == 3)
        #expect(arrivals.count == 9)
        #expect(Set(arrivals.prefix(8)) == Set(0..<8))
        #expect(arrivals.last == 0)
        #expect(finishes.first != 0)
    }

    @Test func singleWorkerDoesNotHoldNewPagesWhileRetrying() async {
        let trace = Trace()
        await DownloadPageBatch.run(pages: [0, 1, 2], concurrency: 1, attemptLimit: 3, retryDelay: { _ in }) { page, final in
            _ = await trace.enter(page)
            await trace.finish(page)
            return page == 0 && !final
        }
        #expect(await trace.arrivals == [0, 1, 2, 0, 0])
        #expect(await trace.peak == 1)
    }
}
