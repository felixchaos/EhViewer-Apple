import SwiftUI
import Testing
@testable import ehviewer_apple

@MainActor
struct DownloadNetworkPromptTests {
    @Test func cancelsWithoutStartingAndConfirmsTheOriginalBatchOnlyOnce() {
        var pending: DownloadNetworkPrompt?
        var submitted: [Int] = []
        let binding = Binding(get: { pending }, set: { pending = $0 })

        DownloadNetworkPrompt.request(galleryCount: 2, in: binding, warningRequired: true) {
            submitted.append(contentsOf: [1, 2])
        }
        #expect(pending?.galleryCount == 2)
        #expect(submitted.isEmpty)
        DownloadNetworkPrompt.respond(in: binding, confirmed: false)
        #expect(pending == nil)
        #expect(submitted.isEmpty)

        DownloadNetworkPrompt.request(galleryCount: 2, in: binding, warningRequired: true) {
            submitted.append(contentsOf: [1, 2])
        }
        DownloadNetworkPrompt.request(in: binding, warningRequired: true) { submitted.append(3) }
        DownloadNetworkPrompt.respond(in: binding, confirmed: true)
        DownloadNetworkPrompt.respond(in: binding, confirmed: true)
        #expect(pending == nil)
        #expect(submitted == [1, 2])
    }

    @Test func skipsAnEmptyBatchAndStartsWithoutPromptWhenNotRequired() {
        var pending: DownloadNetworkPrompt?
        var starts = 0
        let binding = Binding(get: { pending }, set: { pending = $0 })

        DownloadNetworkPrompt.request(galleryCount: 0, in: binding, warningRequired: true) { starts += 1 }
        #expect(pending == nil)
        #expect(starts == 0)

        DownloadNetworkPrompt.request(in: binding, warningRequired: false) { starts += 1 }
        #expect(pending == nil)
        #expect(starts == 1)
    }
}
