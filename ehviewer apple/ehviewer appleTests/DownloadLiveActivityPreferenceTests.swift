#if os(iOS) && targetEnvironment(simulator)
import ActivityKit
import EhSettings
import Foundation
import Testing
@testable import ehviewer_apple

@MainActor
struct DownloadLiveActivityPreferenceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EH_OFFLINE_UNIT_TEST_HOST"] == "1"))
    func turningOffEndsCurrentDisplayAndDoesNotAdmitTheNextDownload() async throws {
        let bridge = DownloadNotificationBridge.shared
        let original = AppSettings.shared.showLiveActivity
        let first: Int64 = 900010000201
        let next: Int64 = 900010000202
        defer {
            DownloadLiveActivityManager.shared.endActivity()
            DownloadNotificationBridge.setLiveActivityEnabled(original)
        }

        DownloadNotificationBridge.setLiveActivityEnabled(true)
        await bridge.onDownloadStart(gid: first, title: "Synthetic transfer")
        let activity = try #require(runningActivity(gid: first))

        DownloadNotificationBridge.setLiveActivityEnabled(false)
        #expect(!AppSettings.shared.showLiveActivity)
        // Another progress update can arrive while ActivityKit dismisses the display.
        await bridge.onDownloadProgress(gid: first, title: "Synthetic transfer", downloaded: 2, total: 4, speed: 128)
        for _ in 0..<30 {
            if activity.activityState == .ended || activity.activityState == .dismissed { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(activity.activityState == .ended || activity.activityState == .dismissed)
        #expect(runningActivity(gid: first) == nil)

        await bridge.onDownloadStart(gid: next, title: "Next synthetic transfer")
        #expect(runningActivity(gid: next) == nil)

        DownloadNotificationBridge.setLiveActivityEnabled(true)
        await bridge.onDownloadProgress(gid: next, title: "Next synthetic transfer", downloaded: 1, total: 4, speed: 128)
        #expect(runningActivity(gid: next) == nil)
        await bridge.onDownloadStart(gid: next, title: "Next synthetic transfer")
        #expect(runningActivity(gid: next) != nil)
    }

    private func runningActivity(gid: Int64) -> Activity<DownloadActivityAttributes>? {
        Activity<DownloadActivityAttributes>.activities.first {
            $0.attributes.gid == gid && ($0.activityState == .active || $0.activityState == .stale)
        }
    }
}
#endif
