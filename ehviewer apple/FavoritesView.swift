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
    @State private var isSearching = false
    @State private var localFavorites: [LocalFavoriteRecord] = []
    @State private var isLoadingLocal = false

    // MARK: - 批量操作状态 (对齐 Android FavoritesScene 选择模式)
    @State private var isSelectMode = false
    /// 云端收藏夹的多选状态（与本地收藏的 isSelectMode 分开：
    /// 两者的批量动作完全不同，本地是删库、云端是调接口换收藏夹）
    @State private var isCloudSelecting = false
    @State private var cloudSelection: Set<Int64> = []
    /// 当前云端收藏夹列表的内容，用来把选中的 gid 解析回 GalleryInfo
    @State private var cloudGalleries: [GalleryInfo] = []
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
                    GalleryListView(mode: .favorites(slot: selectedSlot), selection: externalSelection!, searchKeyword: searchText.isEmpty ? nil : searchText, hidesOwnSearchBar: true)
                        .id(selectedSlot)
                }
            }
            .navigationTitle("收藏")
            .ehPageSearch(isActive: $isSearching, text: $searchText, placeholder: "搜索收藏")
                // 去掉 .searchable：iOS 26 把搜索栏放在屏幕底部，与浮起导航条重叠。
                // 设计稿这一屏顶部只有标题与过滤胶囊，检索由胶囊承担。
            .onChange(of: searchText) { _, _ in
                if selectedSlot == -2 || selectedSlot == -1 { loadLocalFavorites() }
            }
        } else {
            NavigationStack {
                VStack(spacing: 0) {
                    // 紧凑页头：标题与动作同一行。同步状态作为副标题挂在标题下方，
                    // 它是对标题的注解，不该单独占一行。
                    EhPageHeader(
                        title: "收藏",
                        subtitle: selectedSlot >= 0 ? syncStatusText : nil
                    ) {
                        EhSearchToggleButton(isActive: $isSearching)
                        if (selectedSlot == -2 || selectedSlot == -1) && !localFavorites.isEmpty {
                            localBatchToolbar
                        }
                        // 云端收藏夹的批量操作（对齐 Android FavoritesScene 的
                        // 长按多选 + 次级 FAB：批量下载 / 移出收藏 / 换收藏夹）。
                        // 此前只有本地收藏有批量操作，云端收藏夹连多选都没有。
                        if selectedSlot >= 0 {
                            cloudBatchToolbar
                        }
                    }

                    slotPicker
                    Divider()
                    if selectedSlot == -2 {
                        localFavoritesContent
                    } else if selectedSlot == -1 {
                        // "全部": 合并本地收藏 + 在线收藏
                        allFavoritesContent(embedded: false)
                    } else {
                        GalleryListView(
                            mode: .favorites(slot: selectedSlot),
                            searchKeyword: searchText.isEmpty ? nil : searchText,
                            hidesOwnSearchBar: true,
                            isSelecting: $isCloudSelecting,
                            selectedGids: $cloudSelection,
                            visibleGalleries: $cloudGalleries
                        )
                        .id(selectedSlot)
                    }
                }
                .ehPageSearch(isActive: $isSearching, text: $searchText, placeholder: "搜索收藏")
                .ehCompactHeader()
                // 去掉 .searchable：iOS 26 把搜索栏放在屏幕底部，与浮起导航条重叠。
                // 设计稿这一屏顶部只有标题与过滤胶囊，检索由胶囊承担。
                .onChange(of: searchText) { _, _ in
                    if selectedSlot == -2 || selectedSlot == -1 { loadLocalFavorites() }
                }
                // 动作已并入页头，不再用系统工具栏
            }
        }
    }

    // MARK: - 云端收藏夹批量操作

    private var cloudBatchToolbar: some View {
        Menu {
            if isCloudSelecting {
                Button {
                    isCloudSelecting = false
                    cloudSelection.removeAll()
                } label: {
                    Label("退出选择", systemImage: "xmark.circle")
                }

                Divider()

                Button {
                    batchDownloadCloud()
                } label: {
                    Label("下载选中 (\(cloudSelection.count))", systemImage: "arrow.down.circle")
                }
                .disabled(cloudSelection.isEmpty)

                // 换收藏夹和移出，走的都是 addFavorites：
                // dstCat 0–9 = 移动到该收藏夹，-1 = 移出收藏
                Menu {
                    ForEach(0..<10) { slot in
                        if slot != selectedSlot {
                            Button(AppSettings.shared.favCatName(slot)) {
                                batchMoveCloud(to: slot)
                            }
                        }
                    }
                } label: {
                    Label("移动到… (\(cloudSelection.count))", systemImage: "folder")
                }
                .disabled(cloudSelection.isEmpty)

                Divider()

                Button(role: .destructive) {
                    batchMoveCloud(to: -1)
                } label: {
                    Label("移出收藏 (\(cloudSelection.count))", systemImage: "heart.slash")
                }
                .disabled(cloudSelection.isEmpty)
            } else {
                Button {
                    isCloudSelecting = true
                    cloudSelection.removeAll()
                } label: {
                    Label("批量操作", systemImage: "checkmark.circle")
                }
            }
        } label: {
            Image(systemName: isCloudSelecting ? "checkmark.circle.fill" : "ellipsis.circle")
        }
    }

    /// 批量下载选中的云端收藏
    private func batchDownloadCloud() {
        let gids = cloudSelection
        guard !gids.isEmpty else { return }
        Task {
            for info in cloudGalleries where gids.contains(info.gid) {
                await GalleryActionService.shared.startDownload(gallery: info)
            }
            isCloudSelecting = false
            cloudSelection.removeAll()
        }
    }

    /// 批量移动 / 移出。slot == -1 表示移出收藏。
    private func batchMoveCloud(to slot: Int) {
        let gids = cloudSelection
        guard !gids.isEmpty else { return }
        Task {
            var moved = 0
            for info in cloudGalleries where gids.contains(info.gid) {
                do {
                    try await EhAPI.shared.addFavorites(
                        gid: info.gid, token: info.token, dstCat: slot)
                    moved += 1
                    NotificationCenter.default.post(
                        name: .galleryFavoriteChanged, object: nil,
                        userInfo: ["gid": info.gid, "favorited": slot >= 0, "slot": slot])
                } catch {
                    debugLog("[Favorites] 批量操作失败 gid=\(info.gid): \(error)")
                }
            }
            if moved == gids.count {
                EhToast.success(slot >= 0 ? "已移动 \(moved) 本" : "已移出 \(moved) 本")
            } else {
                EhToast.failure("成功 \(moved) / \(gids.count) 本")
            }
            isCloudSelecting = false
            cloudSelection.removeAll()
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
                EhStateView(kind: .empty(
                    symbol: "heart.slash",
                    title: "还没有本地收藏",
                    message: "在画廊详情页点 ♡ 即可加入本地收藏，不需要登录"
                ))
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
                #if os(iOS)
                .ehTabBarAutoHide()
                #endif
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
                    // 分组头用统一的 ehSectionHeader，跟历史页、我的页一致。
                    // 此前这里是手写的 .pink + secondarySystemBackground，
                    // 同一类东西（区块标题）在不同页面长得不一样。
                    HStack(spacing: 6) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(EhColor.danger)
                        Text("本地收藏 (\(localFavorites.count))")
                            .ehSectionHeader()
                        Spacer()
                    }
                    .padding(.horizontal, EhSpacing.page)
                    .padding(.top, 14)
                    .padding(.bottom, 8)

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

            // 在线收藏。
            // 已经有本地收藏时不让它再画一次空状态：没登录的用户会在
            // 自己的收藏列表下面永远看到一句「这个收藏夹是空的」。
            if embedded, let sel = externalSelection {
                GalleryListView(mode: .favorites(slot: -1), selection: sel,
                                searchKeyword: searchText.isEmpty ? nil : searchText,
                                hidesOwnSearchBar: true,
                                hidesEmptyState: !localFavorites.isEmpty)
            } else {
                GalleryListView(mode: .favorites(slot: -1),
                                searchKeyword: searchText.isEmpty ? nil : searchText,
                                hidesOwnSearchBar: true,
                                hidesEmptyState: !localFavorites.isEmpty)
            }
        }
        .onAppear { loadLocalFavorites() }
        // 在别处加/取消收藏后要跟着变——此前只有 onAppear 会重新读库，
        // 从详情页收藏完返回收藏页，列表还是老样子
        .onReceive(NotificationCenter.default.publisher(for: .galleryFavoriteChanged)) { _ in
            loadLocalFavorites()
        }
    }

    private func localFavoriteRow(_ record: LocalFavoriteRecord) -> some View {
        // 与首页、下载、历史共用同一个入口：字段由组件铺开，
        // 这里不再挑着传，否则又会变成「收藏页只有标题和封面」。
        EhGalleryRow(gallery: record.toGalleryInfo())
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
        VStack(alignment: .leading, spacing: 0) {
            // 同步状态只在页头副标题里出现一次。
            // 这里原本还有一行带同步图标的同名文字，是把状态挪进 EhPageHeader
            // 时忘了删的旧实现——「云端收藏夹」在同一屏上下紧挨着显示两遍。
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    slotPill(slot: -1, title: "全部", symbol: nil, count: 0)
                    slotPill(slot: -2, title: "本地收藏", symbol: "heart.fill", count: 0)
                    ForEach(0..<10, id: \.self) { slot in
                        slotPill(
                            slot: slot,
                            title: favoriteNames[slot],
                            symbol: nil,
                            count: AppSettings.shared.favCount(slot)
                        )
                    }
                }
                .padding(.horizontal, EhSpacing.page)
            }
            .frame(height: 46)
        }
    }

    private func slotPill(slot: Int, title: String, symbol: String?, count: Int) -> some View {
        let isSelected = selectedSlot == slot
        return Button {
            selectedSlot = slot
            Haptics.tap()
        } label: {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 10))
                }
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                if count > 0 {
                    Text("\(count)")
                        .font(EhFont.mono(11))
                        .foregroundStyle(isSelected ? EhColor.onAccentFill.opacity(0.7) : EhColor.tertiaryLabel)
                }
            }
            .foregroundStyle(isSelected ? EhColor.onAccentFill : EhColor.secondaryLabel)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background { Capsule().fill(isSelected ? EhColor.accentFill : EhColor.fill) }
        }
        .buttonStyle(.plain)
    }

    /// 上次同步时间。没同步过就不说「刚刚」——那是错的。
    private var syncStatusText: String {
        guard let ts = UserDefaults.standard.object(forKey: "fav_last_sync") as? TimeInterval else {
            return "云端收藏夹"
        }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        return "云端同步 · " + f.localizedString(for: Date(timeIntervalSince1970: ts), relativeTo: Date())
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
            simpleTags: simpleTags,
            simpleLanguage: simpleLanguage
        )
    }
}

#Preview {
    FavoritesView()
}
