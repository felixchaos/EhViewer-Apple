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
                        ContentUnavailableView("暂无历史记录",
                            systemImage: "clock",
                            description: Text("浏览过的画廊会显示在这里"))
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
                NavigationLink(value: record.toGalleryInfo()) {
                    HStack(spacing: 12) {
                        CachedAsyncImage(url: URL(string: record.thumb ?? "")) { img in
                            img.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Color(.tertiarySystemFill)
                        }
                        .frame(width: 52, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.titleJpn ?? record.title)
                                .font(.subheadline)
                                .lineLimit(2)

                            Text(formattedTime(record.date))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
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
        .navigationDestination(for: GalleryInfo.self) { gallery in
            GalleryDetailView(gallery: gallery)
        }
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
            print("Failed to load history: \(error)")
        }
    }

    func delete(at offsets: IndexSet) {
        for index in offsets {
            let record = records[index]
            do {
                try EhDatabase.shared.deleteHistory(gid: record.gid)
            } catch {
                print("Failed to delete history: \(error)")
            }
        }
        records.remove(atOffsets: offsets)
    }

    func deleteByGid(_ gid: Int64) {
        do {
            try EhDatabase.shared.deleteHistory(gid: gid)
            records.removeAll { $0.gid == gid }
        } catch {
            print("Failed to delete history: \(error)")
        }
    }

    func clearAll() {
        do {
            try EhDatabase.shared.clearHistory()
            records.removeAll()
        } catch {
            print("Failed to clear history: \(error)")
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
            print("Failed to add history: \(error)")
        }
    }
}

#Preview {
    HistoryView()
}
