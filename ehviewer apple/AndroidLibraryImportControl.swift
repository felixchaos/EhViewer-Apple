import EhDatabase
import EhSettings
import SwiftUI
import UniformTypeIdentifiers

/// Separate from the existing Apple settings JSON import.
struct AndroidLibraryImportControl: View {
    @State private var showsFilePicker = false
    @State private var isWorking = false
    @State private var preview: Preview?
    @State private var showsOutcome = false
    @State private var outcomeTitle = ""
    @State private var outcomeBody = ""

    private struct Preview: Identifiable, Sendable {
        let id = UUID()
        let source: AndroidLibraryImport
        let summary: AndroidLibraryImportSummary
        let historyLimit: Int
    }

    var body: some View {
        Button {
            #if EH_OFFLINE_UI_FIXTURE && targetEnvironment(simulator)
            if let fixture = EhOfflineUIFixture.injectedImportURL {
                preparePreview(fixture)
                return
            }
            #endif
            showsFilePicker = true
        } label: {
            HStack {
                Text("从安卓导入收藏与历史")
                if isWorking { ProgressView().controlSize(.small) }
            }
        }
        .accessibilityIdentifier("settings-android-library-import")
        .disabled(isWorking)
        // Some file providers mark SQLite exports as generic data. Validate
        // inside the importer rather than relying on extension/UTI alone.
        .fileImporter(isPresented: $showsFilePicker, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url): preparePreview(url)
            case .failure: showFailure(.cannotRead)
            }
        }
        .sheet(item: $preview, onDismiss: {
            // Present results only after the sheet finishes dismissing, including
            // the case where the transaction returns before its animation.
            if !outcomeTitle.isEmpty { showsOutcome = true }
        }) { candidate in
            NavigationStack {
                Form {
                    Section {
                        Text("仅导入安卓本地收藏和阅读历史。不覆盖已有记录，不导入书签、下载文件或账号资料。")
                    }
                    Section("导入预览") {
                        LabeledContent("本地收藏", value: Self.describe(candidate.summary.favorites))
                        LabeledContent("阅读历史", value: Self.describe(candidate.summary.history))
                        if candidate.summary.history.overHistoryLimit > 0 {
                            Text("\(candidate.summary.history.overHistoryLimit) 条记录超出上限（\(candidate.historyLimit) 条），本次跳过。可在高级设置调整上限。")
                                .foregroundStyle(.secondary)
                        }
                        Text("导入不清除已有历史。之后新增记录仍受上限限制。")
                            .foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("导入安卓资料")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { preview = nil }
                            .disabled(isWorking)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("导入") { apply(candidate) }
                            .disabled(isWorking || candidate.summary.importableCount == 0)
                    }
                }
                .interactiveDismissDisabled(isWorking)
            }
        }
        .alert(outcomeTitle, isPresented: $showsOutcome) {
            Button("好", role: .cancel) { outcomeTitle = "" }
        } message: {
            Text(outcomeBody)
        }
    }

    private static func describe(_ counts: AndroidLibraryImportCounts) -> String {
        "新增 \(counts.new) · 已存在 \(counts.existing) · 无效 \(counts.invalid)"
    }

    private func preparePreview(_ url: URL) {
        guard !isWorking else { return }
        isWorking = true
        outcomeTitle = ""
        let historyLimit = AppSettings.shared.historyInfoSize
        Task { @MainActor in
            defer { isWorking = false }
            do {
                let (source, summary) = try await Task.detached(priority: .userInitiated) {
                    guard url.startAccessingSecurityScopedResource() else {
                        throw AndroidLibraryImportError.cannotRead
                    }
                    defer { url.stopAccessingSecurityScopedResource() }
                    let source = try AndroidLibraryImport(exportAt: url)
                    let summary = try EhDatabase.shared.previewAndroidLibrary(source, historyLimit: historyLimit)
                    return (source, summary)
                }.value
                preview = Preview(source: source, summary: summary, historyLimit: historyLimit)
            } catch {
                showFailure((error as? AndroidLibraryImportError) ?? .destinationUnavailable)
            }
        }
    }

    private func apply(_ candidate: Preview) {
        guard !isWorking else { return }
        isWorking = true
        let historyLimit = AppSettings.shared.historyInfoSize
        Task { @MainActor in
            defer { isWorking = false; preview = nil }
            do {
                let summary = try await Task.detached(priority: .userInitiated) {
                    try EhDatabase.shared.importAndroidLibrary(candidate.source, historyLimit: historyLimit)
                }.value
                if summary.favorites.new > 0 {
                    GalleryActionService.shared.localFavoritesDidImport()
                }
                if summary.history.new > 0 {
                    NotificationCenter.default.post(name: .galleryHistoryChanged, object: nil)
                }
                outcomeTitle = summary.importableCount > 0 ? "导入完成" : "无新增记录"
                outcomeBody = "本地收藏：\(Self.describe(summary.favorites))\n阅读历史：\(Self.describe(summary.history))"
                if summary.history.overHistoryLimit > 0 {
                    outcomeBody += "\n另有 \(summary.history.overHistoryLimit) 条历史超出上限，未导入。"
                }
            } catch {
                outcomeTitle = "未能导入"
                outcomeBody = AndroidLibraryImportError.destinationUnavailable.localizedDescription
            }
        }
    }

    private func showFailure(_ error: AndroidLibraryImportError) {
        outcomeTitle = "未能导入"
        outcomeBody = error.localizedDescription
        showsOutcome = true
    }
}
