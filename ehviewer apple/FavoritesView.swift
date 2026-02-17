//
//  FavoritesView.swift
//  ehviewer apple
//
//  收藏视图 — 全部 + 10个收藏夹 + 本地收藏 (对齐 Android FavoritesActivity)
//

import SwiftUI
import EhModels
import EhSettings
import EhDatabase
import EhDownload
import EhAPI

struct FavoritesView: View {
    /// selectedSlot: -2 = 本地收藏, -1 = 全部, 0-9 = 云收藏夹
    @State private var selectedSlot = -1
    @State private var searchText = ""
    @State private var localFavorites: [LocalFavoriteRecord] = []
    @State private var isLoadingLocal = false

    // MARK: - 批量操作状态 (对齐 Android FavoritesScene 选择模式)
    @State private var isSelectMode = false
    @State private var selectedGids: Set<Int64> = []
    @State private var showMoveSheet = false
    @State private var showDeleteConfirm = false
    @State private var isBatchProcessing = false

    /// 外部选择绑定（嵌入模式）
    private var externalSelection: Binding<GalleryInfo?>?
    private var isEmbedded: Bool { externalSelection != nil }

    init() {
        self.externalSelection = nil
    }

    init(selection: Binding<GalleryInfo?>) {
        self.externalSelection = selection
    }

    private var favoriteNames: [String] {
        (0..<10).map { AppSettings.shared.favCatName($0) }
    }

    var body: some View {
        if isEmbedded {
            VStack(spacing: 0) {
                slotPicker
                Divider()
                if selectedSlot == -2 {
                    localFavoritesContent
                } else if selectedSlot == -1 {
                    // "全部": 合并本地收藏 + 在线收藏 (对齐 Android: 全部包含所有来源)
                    allFavoritesContent(embedded: true)
                } else {
                    GalleryListView(mode: .favorites(slot: selectedSlot), selection: externalSelection!, searchKeyword: searchText.isEmpty ? nil : searchText)
                        .id(selectedSlot)
                }
            }
            .navigationTitle("收藏")
            .searchable(text: $searchText, prompt: selectedSlot == -2 ? "搜索本地收藏" : "搜索收藏")
            .onChange(of: searchText) { _, _ in
                if selectedSlot == -2 || selectedSlot == -1 { loadLocalFavorites() }
            }
        } else {
            NavigationStack {
                VStack(spacing: 0) {
                    slotPicker
                    Divider()
                    if selectedSlot == -2 {
                        localFavoritesContent
                    } else if selectedSlot == -1 {
                        // "全部": 合并本地收藏 + 在线收藏
                        allFavoritesContent(embedded: false)
                    } else {
                        GalleryListView(mode: .favorites(slot: selectedSlot), searchKeyword: searchText.isEmpty ? nil : searchText)
                            .id(selectedSlot)
                    }
                }
                .navigationTitle("收藏")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .searchable(text: $searchText, prompt: selectedSlot == -2 ? "搜索本地收藏" : "搜索收藏")
                .onChange(of: searchText) { _, _ in
                    if selectedSlot == -2 || selectedSlot == -1 { loadLocalFavorites() }
                }
                .toolbar {
                    // 本地收藏批量操作工具栏 (对齐 Android FavoritesScene FAB)
                    if (selectedSlot == -2 || selectedSlot == -1) && !localFavorites.isEmpty {
                        ToolbarItem(placement: .automatic) {
                            localBatchToolbar
                        }
                    }
                }
            }
        }
    }

    // MARK: - 本地收藏批量操作工具栏 (对齐 Android FavoritesScene FAB)

    private var localBatchToolbar: some View {
        Menu {
            if isSelectMode {
                Button {
                    if selectedGids.count == localFavorites.count {
                        selectedGids.removeAll()
                    } else {
                        selectedGids = Set(localFavorites.map { $0.gid })
                    }
                } label: {
                    Label(selectedGids.count == localFavorites.count ? "取消全选" : "全选",
                          systemImage: selectedGids.count == localFavorites.count ? "square" : "checkmark.square")
                }

                Divider()

                Button {
                    batchDownloadSelected()
                } label: {
                    Label("批量下载 (\(selectedGids.count))", systemImage: "arrow.down.circle")
                }
                .disabled(selectedGids.isEmpty)

                Button {
                    showMoveSheet = true
                } label: {
                    Label("移动到云收藏 (\(selectedGids.count))", systemImage: "arrow.right.circle")
                }
                .disabled(selectedGids.isEmpty)

                Divider()

                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("删除 (\(selectedGids.count))", systemImage: "trash")
                }
                .disabled(selectedGids.isEmpty)

                Divider()

                Button {
                    isSelectMode = false
                    selectedGids.removeAll()
                } label: {
                    Label("退出选择", systemImage: "xmark.circle")
                }
            } else {
                Button {
                    isSelectMode = true
                    selectedGids.removeAll()
                } label: {
                    Label("批量操作", systemImage: "checkmark.circle")
                }
            }
        } label: {
            Image(systemName: isSelectMode ? "checkmark.circle.fill" : "ellipsis.circle")
        }
        .sheet(isPresented: $showMoveSheet) {
            FavoriteSlotPicker(
                onSelect: { slot in
                    showMoveSheet = false
                    guard slot >= 0 else { return }
                    batchMoveToCloud(slot: slot)
                },
                onCancel: { showMoveSheet = false },
                showLocalOption: false
            )
            .presentationDetents([.medium])
        }
        .confirmationDialog("确认删除 \(selectedGids.count) 个收藏？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                batchDeleteSelected()
            }
        }
    }

    // MARK: - 本地收藏内容 (对齐 Android FAV_CAT_LOCAL)

    private var localFavoritesContent: some View {
        Group {
            if isLoadingLocal {
                ProgressView("加载中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if localFavorites.isEmpty {
                ContentUnavailableView("暂无本地收藏", systemImage: "heart.slash", description: Text("在画廊详情页点击 ♡ 添加本地收藏"))
            } else {
                List {
                    ForEach(localFavorites, id: \.gid) { record in
                        if isSelectMode {
                            Button {
                                if selectedGids.contains(record.gid) {
                                    selectedGids.remove(record.gid)
                                } else {
                                    selectedGids.insert(record.gid)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: selectedGids.contains(record.gid) ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(selectedGids.contains(record.gid) ? Color.accentColor : .secondary)
                                    localFavoriteRow(record)
                                }
                            }
                            .buttonStyle(.plain)
                        } else {
                            NavigationLink {
                                GalleryDetailView(gallery: record.toGalleryInfo())
                                    .id(record.gid)
                            } label: {
                                localFavoriteRow(record)
                            }
                        }
                    }
                    .onDelete { indexSet in
                        if !isSelectMode {
                            deleteLocalFavorites(at: indexSet)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .onAppear { loadLocalFavorites() }
        .onChange(of: selectedSlot) { _, newSlot in
            if newSlot == -2 || newSlot == -1 { loadLocalFavorites() }
            isSelectMode = false
            selectedGids.removeAll()
        }
        .overlay {
            if isBatchProcessing {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .overlay {
                        ProgressView("处理中...")
                            .padding()
                            .background(.regularMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
            }
        }
    }

    // MARK: - 全部收藏 (本地 + 在线合并)

    @ViewBuilder
    private func allFavoritesContent(embedded: Bool) -> some View {
        VStack(spacing: 0) {
            // 本地收藏区块 (折叠式, 对齐 Android: 全部分类下显示所有来源)
            if !localFavorites.isEmpty {
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundStyle(.pink)
                        Text("本地收藏 (\(localFavorites.count))")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground))

                    ForEach(localFavorites.prefix(5), id: \.gid) { record in
                        NavigationLink {
                            GalleryDetailView(gallery: record.toGalleryInfo())
                                .id(record.gid)
                        } label: {
                            localFavoriteRow(record)
                                .padding(.horizontal, 16)
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 104)
                    }

                    if localFavorites.count > 5 {
                        Button {
                            selectedSlot = -2  // 切换到本地收藏查看全部
                        } label: {
                            Text("查看全部 \(localFavorites.count) 个本地收藏")
                                .font(.subheadline)
                                .foregroundStyle(Color.accentColor)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                    }

                    Divider()
                }
            }

            // 在线收藏
            if embedded, let sel = externalSelection {
                GalleryListView(mode: .favorites(slot: -1), selection: sel, searchKeyword: searchText.isEmpty ? nil : searchText)
            } else {
                GalleryListView(mode: .favorites(slot: -1), searchKeyword: searchText.isEmpty ? nil : searchText)
            }
        }
        .onAppear { loadLocalFavorites() }
    }

    private func localFavoriteRow(_ record: LocalFavoriteRecord) -> some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: URL(string: record.thumb ?? "")) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color(.secondarySystemBackground)
            }
            .frame(width: 76, height: 106)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(EhCategory(rawValue: record.category).name)
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(EhCategory(rawValue: record.category).color)
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                Text(record.title)
                    .font(.subheadline)
                    .lineLimit(2)

                if let uploader = record.uploader {
                    Text(uploader)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    if record.rating > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                            Text(String(format: "%.1f", record.rating))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if record.pages > 0 {
                        Text("\(record.pages)P")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func loadLocalFavorites() {
        isLoadingLocal = true
        Task {
            do {
                let records: [LocalFavoriteRecord]
                if searchText.isEmpty {
                    records = try EhDatabase.shared.getAllLocalFavorites()
                } else {
                    records = try EhDatabase.shared.searchLocalFavorites(query: searchText)
                }
                await MainActor.run {
                    self.localFavorites = records
                    self.isLoadingLocal = false
                }
            } catch {
                await MainActor.run {
                    self.isLoadingLocal = false
                }
            }
        }
    }

    // MARK: - 批量操作 (对齐 Android FavoritesScene)

    private func batchDownloadSelected() {
        let selected = localFavorites.filter { selectedGids.contains($0.gid) }
        Task {
            for record in selected {
                await GalleryActionService.shared.startDownload(gallery: record.toGalleryInfo())
            }
        }
        isSelectMode = false
        selectedGids.removeAll()
    }

    private func batchMoveToCloud(slot: Int) {
        let selected = localFavorites.filter { selectedGids.contains($0.gid) }
        isBatchProcessing = true
        Task {
            for record in selected {
                try? await GalleryActionService.shared.addFavorite(gid: record.gid, token: record.token, slot: slot)
                try? EhDatabase.shared.deleteLocalFavorite(gid: record.gid)
            }
            await MainActor.run {
                isBatchProcessing = false
                isSelectMode = false
                selectedGids.removeAll()
                loadLocalFavorites()
            }
        }
    }

    private func batchDeleteSelected() {
        for gid in selectedGids {
            try? EhDatabase.shared.deleteLocalFavorite(gid: gid)
        }
        localFavorites.removeAll { selectedGids.contains($0.gid) }
        isSelectMode = false
        selectedGids.removeAll()
    }

    private func deleteLocalFavorites(at offsets: IndexSet) {
        for index in offsets {
            let record = localFavorites[index]
            try? EhDatabase.shared.deleteLocalFavorite(gid: record.gid)
        }
        localFavorites.remove(atOffsets: offsets)
    }

    // MARK: - Slot Picker

    private var slotPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // "全部" 标签 (对齐 Android FavoritesActivity: favCatArray[0] = "All Favorites")
                Button(action: { selectedSlot = -1 }) {
                    Text("全部")
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(selectedSlot == -1 ? Color.accentColor : Color(.tertiarySystemFill))
                        .foregroundStyle(selectedSlot == -1 ? .white : .primary)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                // "本地收藏" 标签 (对齐 Android FAV_CAT_LOCAL)
                Button(action: { selectedSlot = -2 }) {
                    HStack(spacing: 4) {
                        Image(systemName: "heart.fill")
                            .font(.caption2)
                        Text("本地收藏")
                            .font(.subheadline)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(selectedSlot == -2 ? Color.accentColor : Color(.tertiarySystemFill))
                    .foregroundStyle(selectedSlot == -2 ? .white : .primary)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                ForEach(0..<10) { slot in
                    Button(action: { selectedSlot = slot }) {
                        HStack(spacing: 4) {
                            Text(favoriteNames[slot])
                                .font(.subheadline)
                            let count = AppSettings.shared.favCount(slot)
                            if count > 0 {
                                Text("(\(count))")
                                    .font(.caption2)
                                    .foregroundStyle(selectedSlot == slot ? .white.opacity(0.8) : .secondary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(selectedSlot == slot ? Color.accentColor : Color(.tertiarySystemFill))
                        .foregroundStyle(selectedSlot == slot ? .white : .primary)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - LocalFavoriteRecord → GalleryInfo 转换

extension LocalFavoriteRecord {
    func toGalleryInfo() -> GalleryInfo {
        GalleryInfo(
            gid: gid,
            token: token,
            title: title,
            titleJpn: titleJpn,
            thumb: thumb,
            category: EhCategory(rawValue: category),
            posted: posted,
            uploader: uploader,
            rating: rating,
            pages: pages,
            simpleLanguage: simpleLanguage
        )
    }
}

#Preview {
    FavoritesView()
}
