import Foundation
import Testing
@testable import EhSpider

private actor PreviewTrace {
    private(set) var requests: [Int] = []

    func load(_ page: Int) async throws -> [Int: String] {
        requests.append(page)
        try await Task.sleep(for: .milliseconds(150))
        return [page * 20: "fixture"]
    }
}

@Suite struct DownloadPreviewRequestsTests {
    @Test func simultaneousPagesInTheSamePreviewGroupShareOneRequest() async throws {
        let pool = DownloadPreviewRequests()
        let trace = PreviewTrace()
        async let first = pool.load(page: 0) { try await trace.load(0) }
        async let second = pool.load(page: 0) { try await trace.load(0) }
        async let third = pool.load(page: 1) { try await trace.load(1) }
        let (a, b, c) = try await (first, second, third)
        #expect(a == [0: "fixture"])
        #expect(b == a)
        #expect(c == [20: "fixture"])
        #expect(await trace.requests.sorted() == [0, 1])
    }

    @Test func cancelledPreviewIsNotReusedOnResume() async throws {
        let pool = DownloadPreviewRequests()
        let trace = PreviewTrace()
        let batch = Task { try await pool.load(page: 0) { try await trace.load(0) } }
        for _ in 0..<100 where await trace.requests.isEmpty {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await trace.requests == [0])
        batch.cancel()
        do {
            _ = try await batch.value
            Issue.record("Retired download retained its preview result")
        } catch is CancellationError {}
        let resumed = try await pool.load(page: 0) { try await trace.load(0) }
        #expect(resumed == [0: "fixture"])
        #expect(await trace.requests == [0, 0])
    }
}
