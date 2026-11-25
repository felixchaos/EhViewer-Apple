import SwiftUI

@MainActor
final class DownloadNetworkPrompt {
    let galleryCount: Int
    private var start: (@MainActor () -> Void)?

    init(galleryCount: Int, start: @escaping @MainActor () -> Void) {
        self.galleryCount = galleryCount
        self.start = start
    }

    /// Confirm only the request shown to the user; a second tap cannot
    /// replace an outstanding request with a different gallery or batch.
    static func request(galleryCount: Int = 1, in pending: Binding<DownloadNetworkPrompt?>,
                        warningRequired: Bool? = nil,
                        start: @escaping @MainActor () -> Void) {
        guard galleryCount > 0, pending.wrappedValue == nil else { return }
        if warningRequired ?? requiresConfirmation {
            pending.wrappedValue = DownloadNetworkPrompt(galleryCount: galleryCount, start: start)
        } else {
            start()
        }
    }

    private static var requiresConfirmation: Bool {
        #if EH_OFFLINE_UI_FIXTURE && targetEnvironment(simulator)
        if EhOfflineUIFixture.enabled,
           ProcessInfo.processInfo.environment["EH_FIXTURE_DOWNLOAD_NETWORK_CONFIRMATION"] == "1" {
            return true
        }
        #endif
        return GalleryActionService.shared.shouldWarnAboutCellular
    }

    static func respond(in pending: Binding<DownloadNetworkPrompt?>, confirmed: Bool) {
        guard let prompt = pending.wrappedValue else { return }
        pending.wrappedValue = nil
        prompt.complete(confirmed: confirmed)
    }

    fileprivate func complete(confirmed: Bool) {
        let action = start
        start = nil
        if confirmed { action?() }
    }
}

extension View {
    func downloadNetworkPrompt(_ pending: Binding<DownloadNetworkPrompt?>) -> some View {
        modifier(DownloadNetworkPromptPresenter(pending: pending))
    }
}

private struct DownloadNetworkPromptPresenter: ViewModifier {
    @Binding var pending: DownloadNetworkPrompt?
    @Environment(\.ehWorkspaceIsActive) private var isWorkspaceActive

    func body(content: Content) -> some View {
        content
            .alert("下载网络确认", isPresented: Binding(
                get: { pending != nil && isWorkspaceActive },
                set: { if !$0 { pending = nil } }
            ), presenting: pending) { prompt in
                Button("继续下载") {
                    pending = nil
                    prompt.complete(confirmed: isWorkspaceActive)
                }
                Button("取消", role: .cancel) {
                    pending = nil
                    prompt.complete(confirmed: false)
                }
            } message: { prompt in
                Text("当前使用蜂窝网络或受限网络。下载项目：\(prompt.galleryCount)。")
            }
            .onChange(of: isWorkspaceActive) { _, active in
                if !active { DownloadNetworkPrompt.respond(in: $pending, confirmed: false) }
            }
            .onDisappear {
                DownloadNetworkPrompt.respond(in: $pending, confirmed: false)
            }
    }
}
