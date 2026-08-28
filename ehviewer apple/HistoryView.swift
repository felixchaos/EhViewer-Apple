//
//  HistoryView.swift
//  ehviewer apple
//
//  浏览历史视图 (对齐 Android HistoryScene)
//

import SwiftUI
import EhModels
import EhDatabase
import EhSettings

struct HistoryView: View {
    @State private var vm = HistoryViewModel()
    @State private var searchText = ""
    /// 点续读钮时直接开阅读器，不经详情页
    @State private var resumeItem: ReaderLaunchItem?

    /// 被推入父导航栈时，不创建自己的 NavigationStack，避免嵌套
    private var isPushed: Bool = false

    init(isPushed: Bool = false) {
        self.isPushed = isPushed
    }

    var body: some View {
        Group {
            if isPushed {
                historyInnerContent
            } else {
                NavigationStack {
                    historyInnerContent
                        .navigationDestination(for: GalleryInfo.self) { gallery in
                            GalleryDetailView(gallery: gallery)
                                .id(gallery.gid)
                        }
                }
            }
        }
        .task {
            vm.loadHistory()
        }
    }

    private var historyInnerContent: some View {
        Group {
                if filteredRecords.isEmpty {
                    if searchText.isEmpty {
                        EhStateView(kind: .empty(
                            symbol: "clock",
                            title: "还没有阅读记录",
                            message: "浏览过的画廊会出现在这里"
                        ))
                    } else {
                        ContentUnavailableView.search(text: searchText)
                    }
                } else {
                    historyList
                }
            }
            .navigationTitle("历史")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $searchText, prompt: "搜索历史")
            .toolbar {
                if !vm.records.isEmpty {
                    ToolbarItem(placement: .automatic) {
                        Button("清空", role: .destructive) {
                            vm.showClearConfirm = true
                        }
                    }
                }
            }
            .confirmationDialog("确认清空所有历史记录？", isPresented: $vm.showClearConfirm, titleVisibility: .visible) {
                Button("清空", role: .destructive) {
                    vm.clearAll()
                }
            }
    }

    private var filteredRecords: [HistoryRecord] {
        if searchText.isEmpty {
            return vm.records
        }
        let q = searchText.lowercased()
        return vm.records.filter {
            $0.title.lowercased().contains(q) ||
            ($0.titleJpn?.lowercased().contains(q) ?? false) ||
            ($0.uploader?.lowercased().contains(q) ?? false)
        }
    }

    private var historyList: some View {
        List {
            ForEach(filteredRecords, id: \.gid) { record in
                // 零透明链接垫底，避免 List 给 NavigationLink 自动补 disclosure 箭头
                ZStack {
                    NavigationLink(value: record.toGalleryInfo()) { EmptyView() }
                        .opacity(0)

                    HStack(spacing: EhSpacing.row) {
                        // 封面底部的 2px 进度条把「读到哪了」直接画在缩略图上，
                        // 不必再占一行文字
                        EhCoverThumbnail(
                            url: record.thumb,
                            size: EhSize.historyThumbnail,
                            cornerRadius: EhRadius.smallThumbnail,
                            readProgress: readProgress(for: record)
                        )

                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.titleJpn ?? record.title)
                                .font(EhFont.body)
                                .foregroundStyle(EhColor.label)
                                .lineLimit(2)

                            Text(formattedTime(record.date))
                                .font(EhFont.meta)
                                .foregroundStyle(EhColor.secondaryLabel)
                        }

                        Spacer(minLength: 8)

                        // 续读钮：历史页最主要的动作就是接着上次读，
                        // 让它有个独立的落点而不是只能整行点进详情
                        Button {
                            Haptics.tap()
                            resumeItem = ReaderLaunchItem(
                                gid: record.gid, token: record.token,
                                pages: record.pages, previewSet: nil,
                                initialPage: UserDefaults.standard.object(
                                    forKey: "reading_progress_\(record.gid)"
                                ) as? Int
                            )
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(EhColor.accent)
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(EhColor.fill))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                }
                .overlay(alignment: .bottom) { EhHairline() }
                .contextMenu {
                    // 对齐 Android HistoryScene 长按菜单
                    Button {
                        Task { await GalleryActionService.shared.startDownload(gallery: record.toGalleryInfo()) }
                    } label: {
                        Label("下载", systemImage: "arrow.down.circle")
                    }

                    Button {
                        Task { await GalleryActionService.shared.quickFavorite(gallery: record.toGalleryInfo()) }
                    } label: {
                        Label("收藏", systemImage: "heart")
                    }

                    Divider()

                    Button(role: .destructive) {
                        vm.deleteByGid(record.gid)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
            .onDelete { indexSet in
                vm.delete(at: indexSet)
            }
        }
        .listStyle(.plain)
        #if os(iOS)
        .fullScreenCover(item: $resumeItem) { item in
            ImageReaderView(
                gid: item.gid, token: item.token,
                pages: item.pages, initialPage: item.initialPage
            )
        }
        #endif
    }

    /// 0...1 的阅读进度；没读过或页数未知则不显示
    private func readProgress(for record: HistoryRecord) -> Double? {
        guard record.pages > 0,
              let index = UserDefaults.standard.object(
                forKey: "reading_progress_\(record.gid)"
              ) as? Int, index > 0 else { return nil }
        return Double(index + 1) / Double(record.pages)
    }

    private func formattedTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - HistoryRecord Extension

extension HistoryRecord {
    func toGalleryInfo() -> GalleryInfo {
        GalleryInfo(
            gid: gid, token: token,
            title: title, titleJpn: titleJpn, thumb: thumb,
            category: EhCategory(rawValue: category),
            posted: posted, uploader: uploader,
            rating: rating, pages: pages
        )
    }
}

// MARK: - ViewModel

@MainActor
@Observable
class HistoryViewModel {
    var records: [HistoryRecord] = []
    var showClearConfirm = false

    func loadHistory() {
        do {
            records = try EhDatabase.shared.getAllHistory(limit: AppSettings.shared.historyInfoSize)
        } catch {
            debugLog("Failed to load history: \(error)")
        }
    }

    func delete(at offsets: IndexSet) {
        for index in offsets {
            let record = records[index]
            do {
                try EhDatabase.shared.deleteHistory(gid: record.gid)
            } catch {
                debugLog("Failed to delete history: \(error)")
            }
        }
        records.remove(atOffsets: offsets)
    }

    func deleteByGid(_ gid: Int64) {
        do {
            try EhDatabase.shared.deleteHistory(gid: gid)
            records.removeAll { $0.gid == gid }
        } catch {
            debugLog("Failed to delete history: \(error)")
        }
    }

    func clearAll() {
        do {
            try EhDatabase.shared.clearHistory()
            records.removeAll()
        } catch {
            debugLog("Failed to clear history: \(error)")
        }
    }

    func addRecord(_ gallery: GalleryInfo) {
        var record = HistoryRecord(
            gid: gallery.gid, token: gallery.token,
            title: gallery.bestTitle, category: gallery.category.rawValue,
            pages: gallery.pages, mode: 0, date: Date()
        )
        record.titleJpn = gallery.titleJpn
        record.thumb = gallery.thumb
        record.uploader = gallery.uploader
        record.rating = gallery.rating
        do {
            try EhDatabase.shared.insertHistory(record)
            // 重新加载以保持顺序
            loadHistory()
        } catch {
            debugLog("Failed to add history: \(error)")
        }
    }
}

#Preview {
    HistoryView()
}
