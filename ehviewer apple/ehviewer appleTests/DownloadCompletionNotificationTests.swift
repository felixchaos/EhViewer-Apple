import Foundation
import Testing
import UserNotifications
@testable import ehviewer_apple

@MainActor
struct DownloadCompletionNotificationTests {
    @Test func newBatchDoesNotCountEarlierCompletedItemsOrDismissTheirNotification() {
        var sent = [UNNotificationRequest]()
        var removed = [String]()
        let service = DownloadNotificationService(send: { sent.append($0) }, remove: { removed.append($0) })

        service.onDownloadFinish(gid: 71, title: "Fixture A", success: true, batchID: UUID(), isBatchFinished: false)
        #expect(sent.last?.content.body == "Fixture A")
        service.onDownloadFinish(gid: 73, title: "Fixture C", success: true, batchID: UUID(), isBatchFinished: true)

        #expect(sent.map { $0.content.body } == ["Fixture A", "Fixture C"])
        #expect(sent.map { $0.content.subtitle } == ["", ""])
        #expect(!removed.contains("ehviewer.downloaded"))
        service.clearCompletedItems()
        #expect(removed.last == "ehviewer.downloaded")
    }

    @Test func uninterruptedBatchStillAggregatesSuccessAndFailure() {
        var sent = [UNNotificationRequest]()
        let service = DownloadNotificationService(send: { sent.append($0) }, remove: { _ in })
        let batch = UUID()
        service.onDownloadFinish(gid: 71, title: "Fixture A", success: true, batchID: batch, isBatchFinished: false)
        service.onDownloadFinish(gid: 72, title: "Fixture B", success: false, batchID: batch, isBatchFinished: true)
        #expect(sent.last?.content.body == "1 个成功，1 个失败")
        #expect(sent.last?.content.subtitle == "✓ Fixture A\n✗ Fixture B")
    }
}
