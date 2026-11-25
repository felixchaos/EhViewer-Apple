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

struct FavoritesView: View {
    @Environment(\.ehTagWorkspaceNavigation) private var workspaceNavigation
    private let workspaceRoute: TagWorkspaceRoute?
    private var selectedOrigin: ((WorkspaceGalleryDestination) -> Void)?
    /// selectedSlot: -2 = 本地收藏, -1 = 全部, 0-9 = 云收藏夹
    /// 当前收藏夹。-2 本地 / -1 全部 / 0–9 云端收藏夹。
    ///
    /// 初值取上次看的那个（对齐 Android FavoritesScene.onInit 里的
    /// `mUrlBuilder.setFavCat(Settings.getRecentFavCat())`）。
    /// recentFavCat 此前只写不读——收藏页每次打开都回到「全部」。
    @State private var selectedSlot = FavoritesView.restoredSlot()

    /// 上次看的收藏夹，限制在合法范围内
    private static func restoredSlot() -> Int {
        let saved = AppSettings.shared.recentFavCat
        return (saved >= -2 && saved <= 9) ? saved : -1
    }
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
    @State private var downloadNetworkConfirmation: DownloadNetworkPrompt?

    /// 外部选择绑定（嵌入模式）
    private var externalSelection: Binding<GalleryInfo?>?
    private var isEmbedded: Bool { externalSelection != nil }

    init(workspaceRoute: TagWorkspaceRoute? = nil, selection: Binding<GalleryInfo?>? = nil,
         selectedOrigin: ((WorkspaceGalleryDestination) -> Void)? = nil) {
        self.workspaceRoute = workspaceRoute
        self.externalSelection = selection
        self.selectedOrigin = selectedOrigin
        if let workspaceRoute {
            switch workspaceRoute.origin.scope {
            case .localFavorites: _selectedSlot = State(initialValue: -2)
            default: _selectedSlot = State(initialValue: workspaceRoute.origin.cloudSlot ?? -1)
            }
        }
    }

    private var favoriteNames: [String] {
        (0..<10).map { AppSettings.shared.favCatName($0) }
    }

    var body: some View {
        favoritesContent.downloadNetworkPrompt($downloadNetworkConfirmation)
    }

    @ViewBuilder private var favoritesContent: some View {
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
                    cloudFavoritesList(slot: selectedSlot)
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
                        if (selectedSlot == -2 || selectedSlot == -1) && !localFavorites.isEmpty && !isSelectMode {
                            localBatchToolbar
                        }
                        // 云端收藏夹的批量操作（对齐 Android FavoritesScene 的
                        // 长按多选 + 次级 FAB：批量下载 / 移出收藏 / 换收藏夹）。
                        // 此前只有本地收藏有批量操作，云端收藏夹连多选都没有。
                        if selectedSlot >= 0 && !isCloudSelecting {
                            cloudBatchToolbar
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("favorites-page-header")

                    slotPicker
                    Divider()
                    if selectedSlot == -2 {
                        localFavoritesContent
                    } else if selectedSlot == -1 {
                        // "全部": 合并本地收藏 + 在线收藏
                        allFavoritesContent(embedded: false)
                    } else {
                        cloudFavoritesList(slot: selectedSlot)
                        .id(selectedSlot)
                    }
                    #if os(iOS)
                    if isSelectMode || isCloudSelecting {
                        favoriteSelectionBar
                    }
                    #endif
                }
                #if os(iOS)
                .ehHidesTabBar(isSelectMode || isCloudSelecting)
                #endif
                .ehWorkspaceBatchSelection(isSelectMode || isCloudSelecting)
                .ehPageSearch(isActive: $isSearching, text: $searchText, placeholder: "搜索收藏")
                .ehCompactHeader()
                .navigationDestination(for: GalleryInfo.self) { gallery in
                    GalleryDetailView(gallery: gallery).id(gallery.gid)
                }
                .ehWorkspaceGalleryDestination()
                .navigationDestination(for: TagSearchDestination.self) { destination in
                    GalleryListView(mode: .tag(keyword: destination.tag), isPushed: true)
                }
                // 去掉 .searchable：iOS 26 把搜索栏放在屏幕底部，与浮起导航条重叠。
                // 设计稿这一屏顶部只有标题与过滤胶囊，检索由胶囊承担。
                .onChange(of: searchText) { _, _ in
                    if selectedSlot == -2 || selectedSlot == -1 { loadLocalFavorites() }
                }
                .onChange(of: selectedSlot) { _, newValue in
                    // 记住这次看的是哪个收藏夹，下次进来直接到这里
                    AppSettings.shared.recentFavCat = newValue
                    // 换收藏夹时退出多选，否则选中项会跨收藏夹残留
                    isCloudSelecting = false
                    cloudSelection.removeAll()
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
        .accessibilityIdentifier("cloud-favorite-actions")
    }

    /// 批量下载选中的云端收藏
    private func batchDownloadCloud() {
        let selected = cloudGalleries.filter { cloudSelection.contains($0.gid) }
        DownloadNetworkPrompt.request(galleryCount: selected.count, in: $downloadNetworkConfirmation) {
            Task {
                for info in selected {
                    await GalleryActionService.shared.startDownload(gallery: info)
                }
                isCloudSelecting = false
                cloudSelection.removeAll()
            }
        }
    }

    /// 批量移动 / 移出。slot == -1 表示移出收藏。
    private func batchMoveCloud(to slot: Int) {
        let gids = cloudSelection
        guard !gids.isEmpty else { return }
        let selected = cloudGalleries.filter { gids.contains($0.gid) }
        let actions = GalleryActionService.shared
        let context = actions.cloudFavoriteContext
        Task {
            var moved = 0
            for info in selected {
                do {
                    try await actions.mutateCloudFavorite(gid: info.gid, token: info.token, slot: slot, context: context)
                    moved += 1
                } catch is CloudFavoriteContext.Superseded {
                    return
                } catch {
                    debugLog("[Favorites] 批量操作失败 gid=\(info.gid): \(error)")
                }
            }
            guard actions.isCurrentCloudFavoriteContext(context) else { return }
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
        .accessibilityIdentifier("local-favorite-actions")
        .sheet(isPresented: $showMoveSheet) {
            FavoriteSlotPicker(
                onSelect: { slot in
                    showMoveSheet = false
                    guard slot >= 0 else { return }
                    batchMoveToCloud(slot: slot)
                },
                onCancel: { showMoveSheet = false },
                purpose: .moveToCloud
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
        let origin = localTagOrigin
        return Group {
            if isLoadingLocal && localFavorites.isEmpty {
                ProgressView("加载中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if localFavorites.isEmpty {
                EhStateView(kind: .empty(
                    symbol: "heart.slash",
                    title: "还没有本地收藏",
                    message: "可从画廊详情添加本地收藏，无需登录。"
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
                            localFavoriteLink(record, origin: origin)
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
        .onReceive(NotificationCenter.default.publisher(for: .galleryFavoriteChanged)) { _ in
            loadLocalFavorites()
        }
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
        let origin = localTagOrigin
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
                        localFavoriteLink(record, origin: origin)
                            .padding(.horizontal, 16)
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
            cloudFavoritesList(slot: -1)
        }
        .onAppear { loadLocalFavorites() }
        // 在别处加/取消收藏后要跟着变——此前只有 onAppear 会重新读库，
        // 从详情页收藏完返回收藏页，列表还是老样子
        .onReceive(NotificationCenter.default.publisher(for: .galleryFavoriteChanged)) { _ in
            loadLocalFavorites()
        }
    }

    @ViewBuilder
    private func cloudFavoritesList(slot: Int) -> some View {
        let hiddenEmpty = slot == -1 && !localFavorites.isEmpty
        let unifiedSource: TagWorkspaceOrigin? = slot == -1 ? localTagOrigin : nil
        if let workspaceRoute {
            GalleryListView(workspace: workspaceRoute.retargeted(to: .cloudFavorites(slot)),
                            selection: externalSelection, selectedOrigin: selectedOrigin,
                            externalQuery: searchText, embeddedFavorites: !isEmbedded,
                            hidesEmptyState: hiddenEmpty,
                            isSelecting: $isCloudSelecting, selectedGids: $cloudSelection,
                            visibleGalleries: $cloudGalleries, tagOriginOverride: unifiedSource)
        } else if let sel = externalSelection {
            GalleryListView(mode: .favorites(slot: slot), selection: sel,
                            searchKeyword: searchText.isEmpty ? nil : searchText, hidesOwnSearchBar: true,
                            hidesEmptyState: hiddenEmpty, selectedOrigin: selectedOrigin,
                            tagOriginOverride: unifiedSource)
        } else {
            GalleryListView(mode: .favorites(slot: slot), searchKeyword: searchText.isEmpty ? nil : searchText,
                            hidesOwnSearchBar: true, hidesEmptyState: hiddenEmpty, embeddedFavorites: true,
                            isSelecting: $isCloudSelecting, selectedGids: $cloudSelection,
                            visibleGalleries: $cloudGalleries, tagOriginOverride: unifiedSource)
        }
    }

    private var localTagOrigin: TagWorkspaceOrigin {
        .init(scope: selectedSlot == -1 ? .allFavorites : .localFavorites,
              query: workspaceRoute?.origin.query ?? searchText,
              candidates: localFavorites.map { $0.toGalleryInfo() })
    }

    @ViewBuilder
    private func localFavoriteLink(_ record: LocalFavoriteRecord, origin: TagWorkspaceOrigin) -> some View {
        let gallery = record.toGalleryInfo()
        let route = workspaceRoute?.retargeted(to: origin.scope, candidates: origin.candidates)
        let filters = route?.origin.filters ?? .init()
        let destination = WorkspaceGalleryDestination(gallery: gallery, origin: origin,
                                                      route: route, extra: searchText, filters: filters)
        let row = EhGalleryRow(gallery: gallery, onTagTap: workspaceNavigation.map { navigation in
            { tag in
                navigation.open(route?.descending(into: tag, extra: searchText, filters: filters)
                                ?? origin.selecting(tag))
            }
        })
        if let externalSelection {
            row.onTapGesture {
                selectedOrigin?(destination)
                externalSelection.wrappedValue = gallery
            }
            .accessibilityAction(named: Text("打开画廊")) {
                selectedOrigin?(destination)
                externalSelection.wrappedValue = gallery
            }
        } else {
            ZStack {
                NavigationLink(value: destination) { EmptyView() }
                    .opacity(0)
                row
            }
        }
    }

    #if os(iOS)
    private var favoriteSelectionBar: some View {
        HStack {
            Button("完成") {
                isSelectMode = false
                isCloudSelecting = false
                selectedGids.removeAll()
                cloudSelection.removeAll()
            }
            .accessibilityIdentifier("favorites-selection-done")
            Spacer()
            if isCloudSelecting {
                Button("全选") { cloudSelection = Set(cloudGalleries.map(\.gid)) }
                Spacer()
                cloudBatchToolbar
            } else {
                Button("全选") { selectedGids = Set(localFavorites.map(\.gid)) }
                Spacer()
                localBatchToolbar
            }
        }
        .padding(.horizontal, 16)
        .frame(height: EhSize.tabBarHeight)
        .ehGlass(cornerRadius: EhSize.tabBarRadius)
        .padding(.horizontal, EhSize.tabBarSideInset)
        .padding(.bottom, EhSize.tabBarBottomInset)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("favorites-selection-bar")
    }
    #endif

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
                if let workspaceRoute {
                    let all = try EhDatabase.shared.getAllLocalFavorites()
                    let items = all.map { record -> GalleryInfo in
                        var item = record.toGalleryInfo()
                        if let cached = GalleryCache.shared.getDetail(gid: item.gid), !cached.tags.isEmpty {
                            item.simpleTags = cached.tags.flatMap { group in
                                group.tags.map { "\(group.groupName):\($0)" }
                            }
                        }
                        return item
                    }
                    let filter = workspaceRoute.retargeted(to: .localFavorites, candidates: items)
                    let ids = Set(filter.localList(extra: searchText, filters: filter.origin.filters).galleries.map(\.gid))
                    records = all.filter { ids.contains($0.gid) }
                } else if searchText.isEmpty {
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
        let selected = localFavorites.filter { selectedGids.contains($0.gid) }.map { $0.toGalleryInfo() }
        DownloadNetworkPrompt.request(galleryCount: selected.count, in: $downloadNetworkConfirmation) {
            Task {
                for gallery in selected {
                    await GalleryActionService.shared.startDownload(gallery: gallery)
                }
            }
            isSelectMode = false
            selectedGids.removeAll()
        }
    }

    private func batchMoveToCloud(slot: Int) {
        let selected = localFavorites.filter { selectedGids.contains($0.gid) }
        let actions = GalleryActionService.shared
        let context = actions.cloudFavoriteContext
        isBatchProcessing = true
        Task {
            defer {
                isBatchProcessing = false
                if actions.isCurrentCloudFavoriteContext(context) {
                    isSelectMode = false
                    selectedGids.removeAll()
                }
                loadLocalFavorites()
            }
            for record in selected {
                do {
                    try await actions.addFavorite(gid: record.gid, token: record.token, slot: slot, context: context)
                    guard actions.isCurrentCloudFavoriteContext(context) else { return }
                    try actions.removeLocalFavorite(gid: record.gid)
                } catch is CloudFavoriteContext.Superseded {
                    return
                } catch {
                    debugLog("[Favorites] Move to cloud failed; local copy retained: \(error)")
                }
            }
        }
    }

    private func batchDeleteSelected() {
        deleteLocalFavorites(gids: selectedGids)
        isSelectMode = false
        selectedGids.removeAll()
    }

    private func deleteLocalFavorites(at offsets: IndexSet) {
        deleteLocalFavorites(gids: Set(offsets.map { localFavorites[$0].gid }))
    }

    private func deleteLocalFavorites(gids: Set<Int64>) {
        for gid in gids {
            do {
                try GalleryActionService.shared.removeLocalFavorite(gid: gid)
            } catch {
                EhToast.failure("移出本地收藏失败")
            }
        }
        loadLocalFavorites()
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
        .accessibilityIdentifier("favorites-slot-\(slot)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
