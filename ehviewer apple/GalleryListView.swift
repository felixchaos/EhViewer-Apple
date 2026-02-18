//
//  GalleryListView.swift
//  ehviewer apple
//
//  画廊列表视图 — 首页/热门/搜索结果
//

import SwiftUI
import EhModels
import EhAPI
import EhSettings
import EhDatabase
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct GalleryListView: View {
    let mode: ListMode

    enum ListMode {
        case home
        case popular
        case search(keyword: String)
        case tag(keyword: String)
        case favorites(slot: Int)
    }

    @State private var viewModel = GalleryListViewModel()
    @State private var showQuickSearch = false
    @State private var showAdvancedSearch = false
    @State private var advancedSearch = AdvancedSearchState()
    @State private var selectedQuickSearch: QuickSearchRecord?
    @State private var selectedGallery: GalleryInfo?
    @FocusState private var isSearchFocused: Bool
    /// 跳页模式切换 (对齐 Android JumpDateSelector: DATE_PICKER_TYPE / DATE_NODE_TYPE)
    @State private var jumpUseQuickNode = true

    /// 标签导航路径 — iPad 双栏布局中支持标签推入左侧
    @State private var sidebarPath = NavigationPath()

    /// 外部选择绑定（嵌入三栏布局时使用）
    private var externalSelection: Binding<GalleryInfo?>?
    private var isEmbedded: Bool { externalSelection != nil }

    /// 是否作为 push 目标（避免嵌套 NavigationStack）
    private var isPushed: Bool = false

    /// 收藏夹搜索关键字 (对齐 Android FavoritesScene 搜索)
    private var favSearchKeyword: String?

    private var selectionBinding: Binding<GalleryInfo?> {
        externalSelection ?? $selectedGallery
    }

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// iPad 侧边栏由 MainTabView 统一管理，GalleryListView 不再创建自己的 SplitView
    private var isRegularWidth: Bool { false }
    #else
    /// macOS 也支持全宽单列表模式
    private var isRegularWidth: Bool { AppSettings.shared.wideScreenListMode == 0 }
    #endif

    init(mode: ListMode) {
        self.mode = mode
        self.externalSelection = nil
    }

    /// 作为导航目标推入时使用，不创建自己的 NavigationStack/SplitView
    init(mode: ListMode, isPushed: Bool) {
        self.mode = mode
        self.isPushed = isPushed
        self.externalSelection = nil
    }

    init(mode: ListMode, selection: Binding<GalleryInfo?>) {
        self.mode = mode
        self.externalSelection = selection
    }

    /// 收藏搜索模式
    init(mode: ListMode, searchKeyword: String?) {
        self.mode = mode
        self.favSearchKeyword = searchKeyword
        self.externalSelection = nil
    }

    /// 收藏搜索模式 (嵌入)
    init(mode: ListMode, selection: Binding<GalleryInfo?>, searchKeyword: String?) {
        self.mode = mode
        self.externalSelection = selection
        self.favSearchKeyword = searchKeyword
    }

    /// 当前实际运行模式 — 如果搜索框有内容，则为搜索模式
    /// 但收藏夹模式下搜索应保持在收藏夹内 (对齐 Android: 收藏夹搜索只搜收藏内容)
    private var effectiveMode: ListMode {
        if !viewModel.searchText.isEmpty {
            if case .favorites = mode {
                // 收藏夹下搜索保持在收藏夹模式，搜索关键词通过 searchText 传递给 API
                return mode
            }
            return .search(keyword: viewModel.searchText)
        }
        return mode
    }



    var body: some View {
        // 诊断: 确认 body 是否被无限重渲染 (NSLog 不受缓冲影响，崩溃前也能看到)
        #if DEBUG
        let _ = Self._printChanges()  // ★ 精确显示触发源: @self/@identity/_property
        #endif
        let _ = NSLog("[RENDER] GalleryListView body, mode=%@, galleries=%d", String(describing: mode), viewModel.galleries.count)
        Group {
            if isEmbedded {
                // 嵌入模式: 仅展示列表，由父视图管理导航
                embeddedContent
            } else if isPushed {
                // 被推入导航栈时: 不创建自己的 NavigationStack，避免嵌套
                pushedContent
        } else if isRegularWidth {
            // iPadOS / macOS 独立模式: 双栏布局
            NavigationSplitView {
                NavigationStack(path: $sidebarPath) {
                    sidebarContent
                        .navigationTitle(navigationTitle)
                        .navigationDestination(for: TagSearchDestination.self) { dest in
                            // 标签点击推入的画廊列表 (对齐 Android: onTagClick → 叠加新列表)
                            GalleryListView(mode: .tag(keyword: dest.tag), selection: $selectedGallery)
                        }
                }
                .navigationSplitViewColumnWidth(min: 350, ideal: 400, max: 500)
            } detail: {
                // Detail 部分需要 NavigationStack 才能支持 navigationDestination
                NavigationStack {
                    if let gallery = selectedGallery {
                        GalleryDetailView(gallery: gallery)
                            .id(gallery.gid)  // 强制在选择变更时重新创建视图，修复封面不刷新问题
                    } else {
                        ContentUnavailableView("选择画廊", systemImage: "photo.stack", description: Text("从左侧列表选择一个画廊"))
                    }
                }
                .environment(\.tagNavigationAction, TagNavigationAction { tag in
                    sidebarPath.append(TagSearchDestination(tag: tag))
                })
            }
        } else {
            // iPhone: 单栏布局
            compactContent
        }
        }
        .task {
            print("[EhView] body .task fired, mode=\(mode), galleries=\(viewModel.galleries.count), isLoading=\(viewModel.isLoading)")
            // 异步执行 ViewModel 初始化 — 避免 .onAppear 同步变更 @Observable 导致 NavigationStack 多次更新
            viewModel.favSearchKeyword = favSearchKeyword
            viewModel.loadSearchHistory()
            if case .tag(let keyword) = mode, viewModel.searchText.isEmpty {
                viewModel.searchText = keyword
            }
            // 安全兜底: 确保数据加载在任何分支下都能触发
            if viewModel.galleries.isEmpty && !viewModel.isLoading {
                print("[EhView] body .task → loadGalleries")
                viewModel.loadGalleries(mode: mode)
            }
        }
        .onChange(of: showAdvancedSearch) { _, isShowing in
            if !isShowing {
                // 高级搜索面板关闭时，静默保存参数到 ViewModel (不自动触发搜索)
                // 用户提交搜索或点击搜索按钮时才会使用这些参数
                viewModel.syncAdvancedSettings(advancedSearch)
            }
        }
    }

    // iPhone 布局
    private var compactContent: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 搜索栏 (全宽，置于内容顶部)
                searchBarView

                Group {
                    if viewModel.galleries.isEmpty && viewModel.errorMessage != nil && !viewModel.isLoading {
                        errorView
                    } else {
                        // 离线可用: 始终显示列表结构，加载指示器为内联行，不阻塞界面
                        galleryList
                    }
                }
            }
            .navigationTitle(navigationTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { galleryToolbar }
            #if os(iOS)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { isSearchFocused = false }
                }
            }
            #endif
            .overlay(alignment: .top) {
                searchSuggestionsOverlay
                    .padding(.top, 44) // 搜索建议浮层偏移到搜索栏下方
            }
            .rightDrawer(isOpen: $showQuickSearch) {
                QuickSearchDrawerContent(
                    selectedSearch: $selectedQuickSearch,
                    currentKeyword: viewModel.searchText,
                    onDismiss: { showQuickSearch = false }
                )
            }
            .sheet(isPresented: $showAdvancedSearch) {
                AdvancedSearchView(state: advancedSearch)
            }
            .onChange(of: selectedQuickSearch) { _, newValue in
                if let search = newValue {
                    viewModel.applyQuickSearch(search)
                    selectedQuickSearch = nil
                }
            }
        }
        // ★ 已移除 compactContent 级 .task — 避免与 body .task 重复加载，由 body .task 统一管理
        .sheet(isPresented: $viewModel.showJumpDialog) {
            jumpSheet
        }
        .alert("跳页", isPresented: $viewModel.showGoToDialog) {
            TextField("页码", text: $viewModel.goToPageInput)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            Button("取消", role: .cancel) { viewModel.goToPageInput = "" }
            Button("确定") {
                if let page = Int(viewModel.goToPageInput), page >= 1,
                   page <= viewModel.totalPages {
                    viewModel.goToPage(page - 1, mode: effectiveMode)
                }
                viewModel.goToPageInput = ""
            }
        } message: {
            Text("输入页码 (1-\(viewModel.totalPages))")
        }
    }

    /// 被推入导航栈时的内容 — 不包装 NavigationStack，避免嵌套
    private var pushedContent: some View {
        VStack(spacing: 0) {
            // 搜索栏 (全宽，置于内容顶部)
            searchBarView

            Group {
                if viewModel.galleries.isEmpty && viewModel.errorMessage != nil && !viewModel.isLoading {
                    errorView
                } else {
                    galleryList
                }
            }
        }
        .navigationTitle(navigationTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { galleryToolbar }
        #if os(iOS)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { isSearchFocused = false }
            }
        }
        #endif
        .overlay(alignment: .top) {
            searchSuggestionsOverlay
                .padding(.top, 44)
        }
        .rightDrawer(isOpen: $showQuickSearch) {
            QuickSearchDrawerContent(
                selectedSearch: $selectedQuickSearch,
                currentKeyword: viewModel.searchText,
                onDismiss: { showQuickSearch = false }
            )
        }
        .sheet(isPresented: $showAdvancedSearch) {
            AdvancedSearchView(state: advancedSearch)
        }
        .onChange(of: selectedQuickSearch) { _, newValue in
            if let search = newValue {
                viewModel.applyQuickSearch(search)
                selectedQuickSearch = nil
            }
        }
        .task {
            if viewModel.galleries.isEmpty {
                viewModel.loadGalleries(mode: mode)
            }
        }
        .sheet(isPresented: $viewModel.showJumpDialog) {
            jumpSheet
        }
        .alert("跳页", isPresented: $viewModel.showGoToDialog) {
            TextField("页码", text: $viewModel.goToPageInput)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            Button("取消", role: .cancel) { viewModel.goToPageInput = "" }
            Button("确定") {
                if let page = Int(viewModel.goToPageInput), page >= 1,
                   page <= viewModel.totalPages {
                    viewModel.goToPage(page - 1, mode: effectiveMode)
                }
                viewModel.goToPageInput = ""
            }
        } message: {
            Text("输入页码 (1-\(viewModel.totalPages))")
        }
    }

    private var navigationTitle: String {
        switch mode {
        case .home: return AppSettings.shared.gallerySite == .exHentai ? "ExHentai" : "E-Hentai"
        case .popular: return "热门"
        case .search(let kw): return "搜索: \(kw)"
        case .tag: return "标签搜索"  // 对齐 Android: 标签关键字显示在搜索框而非标题
        case .favorites: return "收藏"
        }
    }

    private var galleryList: some View {
        // Perf P0-3: 一次性读取配置，避免每个 Row 重复读 UserDefaults
        let showJpn = AppSettings.shared.showJpnTitle
        let fixThumb = AppSettings.shared.fixThumbUrl
        return List {
            // Fix F2-1: \u9996\u9875\u9876\u90e8\u663e\u793a\u201c\u7ee7\u7eed\u9605\u8bfb\u201d\u5361\u7247
            if case .home = mode {
                ContinueReadingCard()
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }

            // 内联加载指示器 (不阻塞界面，用户可正常操作其他 Tab 和功能)
            if viewModel.isLoading && viewModel.galleries.isEmpty {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("正在加载…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .listRowSeparator(.hidden)
            }

            ForEach(viewModel.galleries, id: \.gid) { gallery in
                NavigationLink(value: gallery) {
                    GalleryRow(gallery: gallery, showJpnTitle: showJpn, fixThumbUrl: fixThumb)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    // 下载 (对齐 Android onItemLongClick: Download)
                    Button {
                        Task { await GalleryActionService.shared.startDownload(gallery: gallery) }
                    } label: {
                        Label("下载", systemImage: "arrow.down.circle")
                    }
                    .tint(.blue)

                    // 收藏 (对齐 Android onItemLongClick: Add to Favorites)
                    Button {
                        Task { await GalleryActionService.shared.quickFavorite(gallery: gallery) }
                    } label: {
                        Label(gallery.favoriteSlot >= 0 ? "取消收藏" : "收藏", systemImage: gallery.favoriteSlot >= 0 ? "heart.slash" : "heart")
                    }
                    .tint(gallery.favoriteSlot >= 0 ? .gray : .red)
                }
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
            }

            // 加载更多
            if viewModel.hasMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding()
                    .task {
                        await viewModel.loadMore(mode: effectiveMode)
                    }
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        #if os(iOS)
        .scrollDismissesKeyboard(.immediately)
        #endif
        .refreshable {
            await viewModel.refreshAsync(mode: effectiveMode)
        }
        .navigationDestination(for: GalleryInfo.self) { gallery in
            GalleryDetailView(gallery: gallery)
                .id(gallery.gid)
        }
    }

    // 嵌入模式内容（无导航包装器，用于三栏布局的 content 列）
    private var embeddedContent: some View {
        sidebarContent
            .navigationTitle(navigationTitle)
            .task {
                if viewModel.galleries.isEmpty {
                    viewModel.loadGalleries(mode: mode)
                }
            }
    }

    // iPad/Mac 侧边栏内容
    private var sidebarContent: some View {
        // Perf P0-3: 一次性读取配置
        let showJpn = AppSettings.shared.showJpnTitle
        let fixThumb = AppSettings.shared.fixThumbUrl
        return VStack(spacing: 0) {
            // 搜索栏 (全宽，置于内容顶部)
            searchBarView

            Group {
                if viewModel.galleries.isEmpty && viewModel.errorMessage != nil && !viewModel.isLoading {
                    errorView
                } else {
                    List(selection: selectionBinding) {
                        // 内联加载指示器 (不阻塞界面)
                        if viewModel.isLoading && viewModel.galleries.isEmpty {
                            VStack(spacing: 8) {
                                ProgressView()
                                Text("正在加载…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                            .listRowSeparator(.hidden)
                        }

                        ForEach(viewModel.galleries, id: \.gid) { gallery in
                            GalleryRow(gallery: gallery, showJpnTitle: showJpn, fixThumbUrl: fixThumb)
                                .tag(gallery)
                        }

                        if viewModel.hasMore {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding()
                                .task {
                                    await viewModel.loadMore(mode: effectiveMode)
                                }
                        }
                    }
                    .listStyle(.sidebar)
                    .refreshable {
                        await viewModel.refreshAsync(mode: effectiveMode)
                    }
                }
            }
        }
        .toolbar { galleryToolbar }
        #if os(iOS)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { isSearchFocused = false }
            }
        }
        #endif
        .overlay(alignment: .top) {
            searchSuggestionsOverlay
                .padding(.top, 44)
        }
        .rightDrawer(isOpen: $showQuickSearch) {
            QuickSearchDrawerContent(
                selectedSearch: $selectedQuickSearch,
                currentKeyword: viewModel.searchText,
                onDismiss: { showQuickSearch = false }
            )
        }
        .sheet(isPresented: $showAdvancedSearch) {
            AdvancedSearchView(state: advancedSearch)
        }
        .onChange(of: selectedQuickSearch) { _, newValue in
            if let search = newValue {
                viewModel.applyQuickSearch(search)
                selectedQuickSearch = nil
            }
        }
        .sheet(isPresented: $viewModel.showJumpDialog) {
            jumpSheet
        }
        .alert("跳页", isPresented: $viewModel.showGoToDialog) {
            TextField("页码", text: $viewModel.goToPageInput)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            Button("取消", role: .cancel) { viewModel.goToPageInput = "" }
            Button("确定") {
                if let page = Int(viewModel.goToPageInput), page >= 1,
                   page <= viewModel.totalPages {
                    viewModel.goToPage(page - 1, mode: effectiveMode)
                }
                viewModel.goToPageInput = ""
            }
        } message: {
            Text("输入页码 (1-\(viewModel.totalPages))")
        }
    }

    // MARK: - 搜索栏 (对齐 Android SearchBar，从 toolbar 移到 body header 以获得完整宽度)

    private var searchBarView: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.subheadline)

            TextField("搜索", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .onSubmit {
                    isSearchFocused = false
                    viewModel.searchWithAdvanced(advancedSearch)
                }
                .onChange(of: viewModel.searchText) { _, _ in
                    viewModel.updateSuggestions()
                }
                #if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                #endif

            // 右侧图标 (对齐 Android AddDeleteDrawable)
            Button {
                if viewModel.searchText.isEmpty {
                    showAdvancedSearch = true
                } else {
                    viewModel.searchText = ""
                }
            } label: {
                Image(systemName: viewModel.searchText.isEmpty
                      ? (advancedSearch.isEnabled ? "plus.circle.fill" : "plus.circle")
                      : "xmark.circle.fill")
                    .foregroundStyle(viewModel.searchText.isEmpty ? .primary : .secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: - 统一工具栏 (对齐 Android FAB secondaryButtons)

    @ToolbarContentBuilder
    private var galleryToolbar: some ToolbarContent {
        // 其余按钮 (对齐 Android FAB secondaryButtons)
        ToolbarItem(placement: .automatic) {
            HStack(spacing: 4) {
                // 快速搜索 (对齐 Android QuickSearch)
                Button { showQuickSearch = true } label: {
                    Image(systemName: "bookmark")
                }

                // 跳页 (对齐 Android showGoToDialog: mPages>0 → 页码, mPages<0 → 日期)
                Button {
                    if viewModel.totalPages > 0 {
                        viewModel.showGoToDialog = true
                    } else {
                        viewModel.showJumpDialog = true
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .disabled(viewModel.galleries.isEmpty)
            }
        }
    }

    // MARK: - 搜索建议浮层 (对齐 Android SearchBar.updateSuggestions 下拉列表)

    @ViewBuilder
    private var searchSuggestionsOverlay: some View {
        let showHistory = viewModel.searchText.isEmpty && !viewModel.searchHistory.isEmpty
        let showSuggestions = !viewModel.searchText.isEmpty && !viewModel.suggestions.isEmpty

        if isSearchFocused && (showHistory || showSuggestions) {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // 搜索历史 (搜索框为空时)
                        if showHistory {
                            HStack {
                                Text("搜索历史")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("清除") { viewModel.clearSearchHistory() }
                                    .font(.caption)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)

                            ForEach(viewModel.searchHistory, id: \.self) { term in
                                Button {
                                    viewModel.searchText = term
                                    isSearchFocused = false
                                    viewModel.searchWithAdvanced(advancedSearch)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "clock")
                                            .foregroundStyle(.secondary)
                                        Text(term)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Divider().padding(.leading, 48)
                            }
                        }

                        // 标签建议 (搜索框有内容时)
                        if showSuggestions {
                            searchSuggestionsContent
                        }
                    }
                }
                .frame(maxHeight: 300)

                // 点击空白关闭
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { isSearchFocused = false }
            }
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            .padding(.horizontal, 8)
            .padding(.top, 4)
        }
    }

    // MARK: - 统一搜索建议 (已废弃，保留兼容)

    @ViewBuilder
    private var searchSuggestionsBlock: some View {
        // 搜索历史 (搜索框为空时显示)
        if viewModel.searchText.isEmpty && !viewModel.searchHistory.isEmpty {
            Section {
                ForEach(viewModel.searchHistory, id: \.self) { term in
                    Button {
                        viewModel.searchText = term
                        viewModel.searchWithAdvanced(advancedSearch)
                    } label: {
                        Label(term, systemImage: "clock")
                    }
                }
                Button(role: .destructive) {
                    viewModel.clearSearchHistory()
                } label: {
                    Label("清除搜索历史", systemImage: "trash")
                }
            } header: {
                Text("搜索历史")
            }
        }
        // 标签建议
        if !viewModel.suggestions.isEmpty {
            searchSuggestionsContent
        }
    }

    // MARK: - 跳页 Sheet (对齐 Android JumpDateSelector: 日期 / 快捷节点 双模式)

    /// 快捷跳转节点 (对齐 Android JumpDateSelector DATE_NODE_TYPE)
    private static let jumpNodes: [(label: String, value: String)] = [
        ("1 天", "1d"), ("3 天", "3d"),
        ("1 周", "1w"), ("2 周", "2w"),
        ("1 月", "1m"), ("6 月", "6m"),
        ("1 年", "1y"), ("2 年", "2y"),
    ]
    @State private var selectedJumpNode: String = "1d"

    private var jumpSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // 模式切换 (对齐 Android JumpDateSelector 的 toggle 按钮)
                    Picker("跳页模式", selection: $jumpUseQuickNode) {
                        Text("快捷跳转").tag(true)
                        Text("日期选择").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.top, 8)

                    if jumpUseQuickNode {
                        // 快捷节点 (对齐 Android JumpDateSelector RadioGroup)
                        VStack(spacing: 12) {
                            Text("选择时间范围快速跳转")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            LazyVGrid(columns: [
                                GridItem(.flexible()),
                                GridItem(.flexible()),
                            ], spacing: 10) {
                                ForEach(Self.jumpNodes, id: \.value) { node in
                                    Button {
                                        selectedJumpNode = node.value
                                    } label: {
                                        Text(node.label)
                                            .font(.body)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 12)
                                            .background(
                                                selectedJumpNode == node.value
                                                    ? Color.accentColor.opacity(0.15)
                                                    : Color.secondary.opacity(0.08)
                                            )
                                            .foregroundStyle(
                                                selectedJumpNode == node.value
                                                    ? Color.accentColor
                                                    : .primary
                                            )
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8)
                                                    .stroke(
                                                        selectedJumpNode == node.value
                                                            ? Color.accentColor
                                                            : Color.clear,
                                                        lineWidth: 1.5
                                                    )
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal)
                        }
                    } else {
                        // 日期选择器 (对齐 Android JumpDateSelector DATE_PICKER_TYPE)
                        Text("选择日期跳转到对应时间的画廊")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        DatePicker(
                            "跳转日期",
                            selection: $viewModel.jumpDate,
                            in: ...Date(),
                            displayedComponents: .date
                        )
                        .datePickerStyle(.graphical)
                        .padding(.horizontal)
                    }

                    // 前/后页快捷按钮 (仅收藏模式)
                    if viewModel.isFavoritesMode {
                        HStack(spacing: 16) {
                            if let prevHref = viewModel.prevHref {
                                Button {
                                    viewModel.showJumpDialog = false
                                    viewModel.goToFavoritesHref(prevHref, mode: effectiveMode)
                                } label: {
                                    Label("上一页", systemImage: "chevron.left")
                                }
                                .buttonStyle(.bordered)
                            }
                            if let nextHref = viewModel.nextHref {
                                Button {
                                    viewModel.showJumpDialog = false
                                    viewModel.goToFavoritesHref(nextHref, mode: effectiveMode)
                                } label: {
                                    Label("下一页", systemImage: "chevron.right")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
                .padding(.bottom, 16)
            }
            .navigationTitle("跳页")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { viewModel.showJumpDialog = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("跳转") {
                        viewModel.showJumpDialog = false
                        if jumpUseQuickNode {
                            viewModel.goToJump("jump=\(selectedJumpNode)", mode: effectiveMode)
                        } else {
                            viewModel.goToDate(viewModel.jumpDate, mode: effectiveMode)
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - 搜索建议内容 (对齐 Android SearchBar.updateSuggestions)

    @ViewBuilder
    private var searchSuggestionsContent: some View {
        ForEach(Array(viewModel.suggestions.enumerated()), id: \.offset) { _, suggestion in
            Button {
                viewModel.applySuggestion(suggestion.english)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(suggestion.chinese)
                            .font(.body)
                            .foregroundStyle(.primary)
                        Text(suggestion.english)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider().padding(.leading, 16)
        }
    }

    private var errorView: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(viewModel.errorMessage ?? "加载失败")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            // 网络提示
            if let msg = viewModel.errorMessage,
               msg.contains("超时") || msg.contains("timed out") || msg.contains("连接") || msg.contains("域名") || msg.contains("DNS") {
                VStack(alignment: .leading, spacing: 6) {
                    Label("请确认 VPN / 代理已开启", systemImage: "lock.shield")
                    Label("可在设置中尝试开启域名前置", systemImage: "server.rack")
                    Label("检查 DNS 是否被污染", systemImage: "globe")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            }

            Button("重试") {
                viewModel.loadGalleries(mode: effectiveMode)
            }
            .buttonStyle(.bordered)
        }
    }
}

// MARK: - 星级评分视图 (对齐 Android SimpleRatingView)

struct SimpleRatingView: View {
    let rating: Float

    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<5, id: \.self) { index in
                starImage(for: index)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
    }

    private func starImage(for index: Int) -> Image {
        let threshold = Float(index) + 1
        if rating >= threshold {
            return Image(systemName: "star.fill")
        } else if rating >= threshold - 0.5 {
            return Image(systemName: "star.leadinghalf.filled")
        } else {
            return Image(systemName: "star")
        }
    }
}

// MARK: - Gallery Row (对齐 Android item_gallery_list.xml 布局)
// Perf P0-3: showJpnTitle 从外部传入，禁止在 body 中读 AppSettings.shared

struct GalleryRow: View {
    let gallery: GalleryInfo
    let showJpnTitle: Bool
    let fixThumbUrl: Bool

    @Environment(\.responsiveLayout) private var layout

    /// 对齐 Android EhUrl.getFixedThumbUrl: 修复缩略图 CDN 域名不可达问题
    /// 开启时将 ehgt.org / gt0-3.ehgt.org 替换为当前站点的缩略图前缀
    private var thumbURL: URL? {
        guard var urlStr = gallery.thumb, !urlStr.isEmpty else { return nil }
        if fixThumbUrl {
            // 替换 ehgt.org 变体 (gt0.ehgt.org, gt1.ehgt.org ...)
            let site = AppSettings.shared.gallerySite
            let fixedPrefix = EhURL.thumbPrefix(for: site)
            // 匹配 https://ehgt.org/ 或 https://gt[0-3].ehgt.org/
            if let range = urlStr.range(of: "https://(?:gt\\d\\.)?ehgt\\.org/", options: .regularExpression) {
                urlStr.replaceSubrange(range, with: fixedPrefix)
            }
        }
        return URL(string: urlStr)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // 缩略图 (对齐 Android @id/thumb) - 使用响应式尺寸
            CachedAsyncImage(url: thumbURL) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Color(.secondarySystemBackground)
            }
            .frame(width: layout.galleryThumbnailSize.width, height: layout.galleryThumbnailSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            // 信息区 (对齐 Android RelativeLayout 右侧元素)
            VStack(alignment: .leading, spacing: 0) {
                // 标题 (对齐 Android @id/title: alignParentTop, toRightOf thumb)
                Text(gallery.suitableTitle(preferJpn: showJpnTitle))
                    .font(.subheadline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.primary)

                // 上传者 (对齐 Android @id/uploader: below title)
                if let uploader = gallery.uploader {
                    Text(uploader)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.top, 2)
                }

                Spacer(minLength: 4)

                // 底部区域 — 评分 + 图标行 (对齐 Android rating + LinearLayout)
                HStack {
                    // 评分星星 (对齐 Android SimpleRatingView: above category)
                    SimpleRatingView(rating: gallery.rating)

                    Spacer(minLength: 4)

                    // 右侧图标 (对齐 Android LinearLayout: downloaded, favourited, simple_language, pages)
                    HStack(spacing: 6) {
                        if gallery.favoriteSlot >= 0 {
                            Image(systemName: "heart.fill")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                        if let lang = gallery.simpleLanguage, !lang.isEmpty {
                            Text(lang)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text("\(gallery.pages)P")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                // 分类 + 发布时间 (对齐 Android category + posted)
                HStack {
                    // 分类标签 (对齐 Android @id/category: alignBottom thumb)
                    Text(gallery.category.name)
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(gallery.category.color)
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                    Spacer(minLength: 4)

                    // 发布时间 (对齐 Android @id/posted: alignBottom thumb, alignParentRight)
                    if let posted = gallery.posted, !posted.isEmpty {
                        Text(posted)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu {
            // 下载
            Button {
                Task { await GalleryActionService.shared.startDownload(gallery: gallery) }
            } label: {
                Label("下载", systemImage: "arrow.down.circle")
            }

            // 收藏
            Button {
                Task { await GalleryActionService.shared.quickFavorite(gallery: gallery) }
            } label: {
                Label("收藏", systemImage: gallery.favoriteSlot >= 0 ? "heart.fill" : "heart")
            }

            Divider()

            // 复制链接
            Button {
                GalleryActionService.shared.copyLink(gid: gallery.gid, token: gallery.token)
            } label: {
                Label("复制链接", systemImage: "doc.on.doc")
            }

            // 分享 (仅 iOS)
            #if os(iOS)
            ShareLink(item: URL(string: GalleryActionService.shared.galleryURL(gid: gallery.gid, token: gallery.token))!) {
                Label("分享", systemImage: "square.and.arrow.up")
            }
            #endif
        }
    }
}

// MARK: - ViewModel

@MainActor
@Observable
class GalleryListViewModel {
    var galleries: [GalleryInfo] = []
    var isLoading = false
    var errorMessage: String?
    var searchText = ""
    var hasMore = false
    var totalPages = 0 // 总页数 (对齐 Android mHelper.mPages)
    var showGoToDialog = false // 跳页对话框 (页码模式，仅 TopList 使用)
    var goToPageInput: String = "" // 跳页输入
    var showJumpDialog = false // 跳页对话框 (日期模式，对齐 Android GoToDialog)
    var jumpDate = Date() // 跳页日期

    /// 收藏夹分页导航链接 (searchnav 模式: prev/next)
    var prevHref: String?
    var nextHref: String?
    /// 是否为收藏模式 (使用 seek 跳页而非整数页码)
    var isFavoritesMode: Bool {
        if case .favorites = currentMode { return true }
        return false
    }

    /// 收藏夹搜索关键字 (由 FavoritesView 传入)
    var favSearchKeyword: String?

    // MARK: - 搜索历史 (对齐 Android SearchBar 搜索历史)
    var searchHistory: [String] = []

    private static let searchHistoryKey = "ehSearchHistory"
    private static let maxHistoryCount = 50

    func loadSearchHistory() {
        searchHistory = UserDefaults.standard.stringArray(forKey: Self.searchHistoryKey) ?? []
    }

    func addSearchToHistory(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var history = UserDefaults.standard.stringArray(forKey: Self.searchHistoryKey) ?? []
        history.removeAll { $0 == text }
        history.insert(text, at: 0)
        if history.count > Self.maxHistoryCount {
            history = Array(history.prefix(Self.maxHistoryCount))
        }
        UserDefaults.standard.set(history, forKey: Self.searchHistoryKey)
        searchHistory = history
    }

    func removeSearchHistory(_ text: String) {
        var history = UserDefaults.standard.stringArray(forKey: Self.searchHistoryKey) ?? []
        history.removeAll { $0 == text }
        UserDefaults.standard.set(history, forKey: Self.searchHistoryKey)
        searchHistory = history
    }

    func clearSearchHistory() {
        UserDefaults.standard.removeObject(forKey: Self.searchHistoryKey)
        searchHistory = []
    }

    // MARK: - 搜索建议 (对齐 Android SearchBar.updateSuggestions)
    var suggestions: [(chinese: String, english: String)] = []
    private var suggestionTask: Task<Void, Never>?

    /// 更新搜索建议 (对齐 Android SearchBar.updateSuggestions)
    func updateSuggestions() {
        suggestionTask?.cancel()
        suggestionTask = Task { @MainActor in
            // 防抖 200ms
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }

            guard let extracted = EhTagDatabase.extractLastKeyword(from: searchText) else {
                suggestions = []
                return
            }
            let results = EhTagDatabase.shared.suggest(extracted.keyword)
            if !Task.isCancelled {
                suggestions = results
            }
        }
    }

    /// 应用搜索建议到搜索文本
    func applySuggestion(_ suggestion: String) {
        searchText = EhTagDatabase.applySuggestion(to: searchText, suggestion: suggestion)
        suggestions = []
    }

    private var currentPage = 0
    private var currentCacheKey: String?
    private var currentMode: GalleryListView.ListMode?
    /// 高级搜索参数 (对齐 Android AdvanceSearchTable 状态持久化)
    private var currentAdvanceSearch: Int = -1
    private var currentMinRating: Int = -1
    private var currentPageFrom: Int = -1
    private var currentPageTo: Int = -1
    private var currentCategory: Int = 0
    private var currentSearchMode: SearchMode = .normal

    func loadGalleries(mode: GalleryListView.ListMode) {
        guard !isLoading else {
            print("[EhVM] loadGalleries: SKIPPED (already loading)")
            return
        }
        print("[EhVM] loadGalleries: START mode=\(mode)")

        currentMode = mode
        
        // 先查缓存 (空结果不视为有效缓存 — 可能是之前网络失败)
        let cacheKey = Self.cacheKey(for: mode, page: 0)
        if let cached = GalleryCache.shared.getListResult(forKey: cacheKey),
           !cached.galleries.isEmpty {
            print("[EhVM] loadGalleries: CACHE HIT \(cached.galleries.count) galleries")
            galleries = cached.galleries
            hasMore = cached.hasMore
            totalPages = cached.totalPages ?? 0
            currentCacheKey = cacheKey
            return
        }

        isLoading = true
        errorMessage = nil
        currentPage = 0
        currentCacheKey = cacheKey

        Task {
            // 超时保护: 如果网络请求超过 20 秒仍未完成，显示错误让用户可以重试
            let fetchTask = Task {
                await fetchPage(mode: mode, page: 0)
            }
            let timeoutTask = Task {
                try? await Task.sleep(for: .seconds(20))
                // 仅在仍处于加载状态且画廊为空时触发超时
                if self.isLoading && self.galleries.isEmpty {
                    fetchTask.cancel()
                    self.isLoading = false
                    self.errorMessage = "网络请求超时，请检查网络连接或 VPN 设置后重试"
                    print("[EhVM] loadGalleries: TIMEOUT after 20s")
                }
            }
            await fetchTask.value
            timeoutTask.cancel()
        }
    }

    func refresh(mode: GalleryListView.ListMode) {
        // 刷新时清除当前 mode 的缓存
        if let key = currentCacheKey {
            GalleryCache.shared.removeListResult(forKey: key)
        }
        // 不清除 galleries — loadGalleries/fetchPage 成功后会替换
        // 避免列表被清空后触发 ProgressView，导致 .refreshable 任务被 SwiftUI 取消
        isLoading = false  // 重置状态，确保 loadGalleries 不会被 guard 拦截
        loadGalleries(mode: mode)
    }

    /// 异步刷新 — 用于 .refreshable ，等待网络请求完成后才结束下拉动画
    func refreshAsync(mode: GalleryListView.ListMode) async {
        if let key = currentCacheKey {
            GalleryCache.shared.removeListResult(forKey: key)
        }
        // 不清除 galleries、不设置 isLoading = true
        // — 保持旧数据可见，防止 SwiftUI 将 galleryList 替换为 ProgressView
        //   从而取消 .refreshable 的结构化并发任务
        currentMode = mode
        errorMessage = nil
        currentPage = 0
        let cacheKey = Self.cacheKey(for: mode, page: 0)
        currentCacheKey = cacheKey
        await fetchPage(mode: mode, page: 0)
    }

    func search() {
        guard !searchText.isEmpty else { return }
        addSearchToHistory(searchText)
        galleries = []
        isLoading = true
        errorMessage = nil
        currentPage = 0
        // 清除高级搜索参数
        currentAdvanceSearch = -1
        currentMinRating = -1
        currentPageFrom = -1
        currentPageTo = -1
        currentCategory = 0
        currentSearchMode = .normal

        Task {
            await fetchPage(mode: .search(keyword: searchText), page: 0)
        }
    }

    /// 带高级搜索参数的搜索 (对齐 Android AdvanceSearchTable → ListUrlBuilder)
    func searchWithAdvanced(_ state: AdvancedSearchState) {
        if !searchText.isEmpty { addSearchToHistory(searchText) }
        currentAdvanceSearch = state.advanceSearchValue
        currentMinRating = state.minRatingValue
        currentPageFrom = state.pageFromValue
        currentPageTo = state.pageToValue
        currentCategory = state.categoryValue
        currentSearchMode = state.searchMode

        // 没有关键字时，按分类过滤首页 (对齐 Android: 无关键字也能按分类搜索)
        if searchText.isEmpty {
            galleries = []
            isLoading = true
            errorMessage = nil
            currentPage = 0
            Task {
                await fetchPage(mode: .home, page: 0)
            }
            return
        }

        galleries = []
        isLoading = true
        errorMessage = nil
        currentPage = 0
        Task {
            await fetchPage(mode: .search(keyword: searchText), page: 0)
        }
    }

    /// 高级搜索面板关闭后自动应用设置 (对齐 Android GalleryListScene.onApplySearch)
    func applyAdvancedSettings(_ state: AdvancedSearchState, initialMode: GalleryListView.ListMode) {
        syncAdvancedSettings(state)

        // 清除缓存，强制使用新参数重新加载
        if let key = currentCacheKey {
            GalleryCache.shared.removeListResult(forKey: key)
        }

        // 有活跃搜索关键字时，重新执行搜索
        if !searchText.isEmpty {
            galleries = []
            isLoading = true
            errorMessage = nil
            currentPage = 0
            Task {
                await fetchPage(mode: .search(keyword: searchText), page: 0)
            }
            return
        }

        // 首页模式: 用分类重新加载
        if case .home = initialMode {
            galleries = []
            isLoading = true
            errorMessage = nil
            currentPage = 0
            Task {
                await fetchPage(mode: .home, page: 0)
            }
        }
    }

    /// 静默同步高级搜索参数到 ViewModel (不触发搜索)
    func syncAdvancedSettings(_ state: AdvancedSearchState) {
        currentCategory = state.categoryValue
        currentSearchMode = state.searchMode
        currentAdvanceSearch = state.advanceSearchValue
        currentMinRating = state.minRatingValue
        currentPageFrom = state.pageFromValue
        currentPageTo = state.pageToValue
    }

    func applyQuickSearch(_ search: QuickSearchRecord) {
        guard let keyword = search.keyword, !keyword.isEmpty else { return }
        searchText = keyword
        galleries = []
        isLoading = true
        errorMessage = nil
        currentPage = 0

        // 构建带有分类和评分过滤的搜索
        Task {
            await fetchQuickSearch(search)
        }
    }

    private func fetchQuickSearch(_ search: QuickSearchRecord) async {
        do {
            let site = AppSettings.shared.gallerySite
            let host = EhURL.host(for: site)

            var urlComponents = URLComponents(string: host)!
            var queryItems: [URLQueryItem] = []

            // 关键词
            if let keyword = search.keyword {
                queryItems.append(URLQueryItem(name: "f_search", value: keyword))
            }

            // 分类过滤 (E-Hentai 使用 f_cats 参数，是要排除的分类的位掩码)
            if search.category > 0 {
                // category 是要包含的分类，需要计算排除的分类
                let allCategories = 0x3FF  // 全部分类
                let excludeCategories = allCategories ^ search.category
                queryItems.append(URLQueryItem(name: "f_cats", value: String(excludeCategories)))
            }

            // 最低评分
            if search.minRating > 0 {
                queryItems.append(URLQueryItem(name: "f_srdd", value: String(search.minRating)))
                queryItems.append(URLQueryItem(name: "f_sr", value: "on"))
            }

            // 高级搜索标记
            if search.advanceSearch > 0 || search.minRating > 0 {
                queryItems.append(URLQueryItem(name: "advsearch", value: "1"))
            }

            urlComponents.queryItems = queryItems.isEmpty ? nil : queryItems

            let result = try await EhAPI.shared.getGalleryList(url: urlComponents.url!.absoluteString)

            self.galleries = result.galleries
            self.hasMore = result.nextPage != nil
            self.isLoading = false
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                self.isLoading = false
                return
            }
            self.errorMessage = EhError.localizedMessage(for: error)
            self.isLoading = false
        }
    }

    func loadMore(mode: GalleryListView.ListMode) async {
        guard !isLoading, hasMore else { return }
        
        // 收藏夹模式: 使用 nextHref 翻页 (不是整数页码)
        if case .favorites = mode, let nextHref = nextHref {
            isLoading = true
            do {
                let result = try await EhAPI.shared.getGalleryList(url: nextHref)
                self.galleries.append(contentsOf: result.galleries)
                self.hasMore = result.nextHref != nil
                self.prevHref = result.prevHref
                self.nextHref = result.nextHref
                self.totalPages = result.pages
                self.isLoading = false
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    self.isLoading = false
                    return
                }
                self.errorMessage = EhError.localizedMessage(for: error)
                self.isLoading = false
            }
            return
        }
        
        isLoading = true
        currentPage += 1
        await fetchPage(mode: mode, page: currentPage)
    }
    
    /// 跳转到指定页 (对齐 Android ContentHelper.goTo(page), 仅 TopList 使用)
    func goToPage(_ page: Int, mode: GalleryListView.ListMode) {
        guard page >= 0 && page < totalPages else { return }
        
        galleries = []
        isLoading = true
        errorMessage = nil
        currentPage = page
        currentMode = mode
        
        Task {
            await fetchPage(mode: mode, page: page)
        }
    }

    /// 通用日期跳转 (对齐 Android GoToDialog: 所有模式统一使用日期选择器)
    func goToDate(_ date: Date, mode: GalleryListView.ListMode) {
        if case .favorites = mode {
            // 收藏模式: ?seek=YYYY-MM-DD
            goToFavoritesDate(date, mode: mode)
        } else {
            // 普通模式: ?next=UNIX_TIMESTAMP (对齐 Android: 日期转时间戳跳转)
            goToNormalDate(date, mode: mode)
        }
    }

    /// 普通画廊按日期跳转 (对齐 Android GoToDialog 普通模式: ?next=TIMESTAMP)
    private func goToNormalDate(_ date: Date, mode: GalleryListView.ListMode) {
        galleries = []
        isLoading = true
        errorMessage = nil
        currentPage = 0
        currentMode = mode
        
        Task {
            await fetchNormalSeek(date: date, mode: mode)
        }
    }

    /// 收藏跳转到指定日期 (对齐 Android FavoritesScene: ?seek=YYYY-MM-DD)
    func goToFavoritesDate(_ date: Date, mode: GalleryListView.ListMode) {
        guard case .favorites(let slot) = mode else { return }
        
        galleries = []
        isLoading = true
        errorMessage = nil
        currentPage = 0
        currentMode = mode
        
        Task {
            await fetchFavoritesSeek(slot: slot, date: date)
        }
    }

    /// 收藏通过 URL 导航 (prev/next 链接)
    func goToFavoritesHref(_ href: String, mode: GalleryListView.ListMode) {
        galleries = []
        isLoading = true
        errorMessage = nil
        currentMode = mode
        
        Task {
            do {
                let result = try await EhAPI.shared.getGalleryList(url: href)
                self.galleries = result.galleries
                self.hasMore = result.nextHref != nil
                self.prevHref = result.prevHref
                self.nextHref = result.nextHref
                self.totalPages = result.pages
                self.isLoading = false
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    self.isLoading = false
                    return
                }
                self.errorMessage = EhError.localizedMessage(for: error)
                self.isLoading = false
            }
        }
    }

    /// 快捷跳转 (对齐 Android jumpHrefBuild + onTimeSelected)
    /// appendParam 为 "jump=1d" / "seek=2024-01-15" 之类的 URL 追加参数
    func goToJump(_ appendParam: String, mode: GalleryListView.ListMode) {
        galleries = []
        isLoading = true
        errorMessage = nil
        currentMode = mode

        Task {
            let jumpUrl = buildJumpUrl(appendParam, mode: mode)
            do {
                let result = try await EhAPI.shared.getGalleryList(url: jumpUrl)
                self.galleries = result.galleries
                self.hasMore = result.nextPage != nil || result.nextHref != nil
                self.prevHref = result.prevHref
                self.nextHref = result.nextHref
                self.totalPages = result.pages
                self.isLoading = false
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    self.isLoading = false
                    return
                }
                self.errorMessage = EhError.localizedMessage(for: error)
                self.isLoading = false
            }
        }
    }

    /// 构建跳转 URL (对齐 Android ListUrlBuilder.jumpHrefBuild)
    /// 如果有 nextHref，修改它；否则从当前模式构建基础 URL
    private func buildJumpUrl(_ appendParam: String, mode: GalleryListView.ListMode) -> String {
        var baseUrl: String

        if let href = nextHref, !href.isEmpty {
            baseUrl = href
        } else {
            let site = AppSettings.shared.gallerySite
            switch mode {
            case .home:
                var builder = ListUrlBuilder()
                builder.mode = .normal
                builder.category = currentCategory
                baseUrl = builder.build(site: site)
            case .search(let keyword):
                var builder = ListUrlBuilder()
                builder.mode = ListUrlBuilder.Mode(rawValue: currentSearchMode.listMode) ?? .normal
                builder.keyword = keyword
                builder.advanceSearch = currentAdvanceSearch
                builder.minRating = currentMinRating
                builder.pageFrom = currentPageFrom
                builder.pageTo = currentPageTo
                builder.category = currentCategory
                baseUrl = builder.build(site: site)
            case .tag(let keyword):
                let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? keyword
                baseUrl = "\(EhURL.host(for: site))tag/\(encoded)"
            case .favorites(let slot):
                if slot < 0 {
                    baseUrl = EhURL.favoritesUrl(for: site)
                } else {
                    baseUrl = "\(EhURL.favoritesUrl(for: site))?favcat=\(slot)"
                }
            case .popular:
                baseUrl = EhURL.popularUrl(for: site)
            }
        }

        // 移除已有的 seek/jump 参数 (对齐 Android jumpHrefBuild 正则替换逻辑)
        baseUrl = baseUrl.replacingOccurrences(
            of: "seek=\\d+-\\d+-\\d+",
            with: "",
            options: .regularExpression
        )
        baseUrl = baseUrl.replacingOccurrences(
            of: "jump=\\d[ymwd]",
            with: "",
            options: .regularExpression
        )
        // 清除残留分隔符
        baseUrl = baseUrl.replacingOccurrences(of: "&&", with: "&")
        baseUrl = baseUrl.replacingOccurrences(of: "?&", with: "?")
        while baseUrl.hasSuffix("?") || baseUrl.hasSuffix("&") {
            baseUrl.removeLast()
        }

        // 追加新参数
        let separator = baseUrl.contains("?") ? "&" : "?"
        return "\(baseUrl)\(separator)\(appendParam)"
    }

    /// 普通画廊按日期跳转 (对齐 Android: ?next=UNIX_TIMESTAMP)
    private func fetchNormalSeek(date: Date, mode: GalleryListView.ListMode) async {
        let site = AppSettings.shared.gallerySite
        let timestamp = Int(date.timeIntervalSince1970)

        // 基于当前模式构建 URL，附加 &next=TIMESTAMP
        var baseUrl: String
        switch mode {
        case .home:
            var builder = ListUrlBuilder()
            builder.mode = .normal
            builder.category = currentCategory
            baseUrl = builder.build(site: site)
        case .search(let keyword):
            var builder = ListUrlBuilder()
            builder.mode = ListUrlBuilder.Mode(rawValue: currentSearchMode.listMode) ?? .normal
            builder.keyword = keyword
            builder.advanceSearch = currentAdvanceSearch
            builder.minRating = currentMinRating
            builder.pageFrom = currentPageFrom
            builder.pageTo = currentPageTo
            builder.category = currentCategory
            baseUrl = builder.build(site: site)
        case .tag(let keyword):
            let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? keyword
            baseUrl = "\(EhURL.host(for: site))tag/\(encoded)"
        default:
            // popular 等模式不支持日期跳转
            return
        }

        // 附加 next=TIMESTAMP 参数
        let separator = baseUrl.contains("?") ? "&" : "?"
        let seekUrl = "\(baseUrl)\(separator)next=\(timestamp)"

        do {
            let result = try await EhAPI.shared.getGalleryList(url: seekUrl)
            self.galleries = result.galleries
            self.hasMore = result.nextPage != nil || result.nextHref != nil
            self.prevHref = result.prevHref
            self.nextHref = result.nextHref
            self.totalPages = result.pages
            self.isLoading = false
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                self.isLoading = false
                return
            }
            self.errorMessage = EhError.localizedMessage(for: error)
            self.isLoading = false
        }
    }

    /// 按日期跳转收藏 (对齐 Android: ?seek=YYYY-MM-DD)
    private func fetchFavoritesSeek(slot: Int, date: Date) async {
        let site = AppSettings.shared.gallerySite
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateStr = formatter.string(from: date)
        
        var favUrl: String
        if slot < 0 {
            favUrl = "\(EhURL.favoritesUrl(for: site))?seek=\(dateStr)"
        } else {
            favUrl = "\(EhURL.favoritesUrl(for: site))?favcat=\(slot)&seek=\(dateStr)"
        }
        
        if let keyword = favSearchKeyword, !keyword.isEmpty {
            let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
            favUrl += "&f_search=\(encoded)"
        }
        
        do {
            let result = try await EhAPI.shared.getGalleryList(url: favUrl)
            self.galleries = result.galleries
            self.hasMore = result.nextHref != nil
            self.prevHref = result.prevHref
            self.nextHref = result.nextHref
            self.totalPages = result.pages
            self.isLoading = false
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                self.isLoading = false
                return
            }
            self.errorMessage = EhError.localizedMessage(for: error)
            self.isLoading = false
        }
    }

    private func fetchPage(mode: GalleryListView.ListMode, page: Int) async {
        print("[EhVM] fetchPage: mode=\(mode) page=\(page)")
        do {
            let site = AppSettings.shared.gallerySite
            let host = EhURL.host(for: site)
            let urlString: String

            switch mode {
            case .home:
                var builder = ListUrlBuilder()
                builder.mode = .normal
                builder.pageIndex = page
                builder.category = currentCategory
                urlString = builder.build(site: site)
            case .popular:
                urlString = EhURL.popularUrl(for: site)
            case .search(let keyword):
                var builder = ListUrlBuilder()
                builder.mode = ListUrlBuilder.Mode(rawValue: currentSearchMode.listMode) ?? .normal
                builder.keyword = keyword
                builder.pageIndex = page
                builder.advanceSearch = currentAdvanceSearch
                builder.minRating = currentMinRating
                builder.pageFrom = currentPageFrom
                builder.pageTo = currentPageTo
                builder.category = currentCategory
                urlString = builder.build(site: site)
            case .tag(let keyword):
                let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? keyword
                if page > 0 {
                    urlString = "\(host)tag/\(encoded)/\(page)"
                } else {
                    urlString = "\(host)tag/\(encoded)"
                }
            case .favorites(let slot):
                // slot -1 = 全部收藏, 0-9 = 指定收藏夹 (对齐 Android FavoritesScene)
                var favUrl: String
                if slot < 0 {
                    favUrl = "\(EhURL.favoritesUrl(for: site))?page=\(page)"
                } else {
                    favUrl = "\(EhURL.favoritesUrl(for: site))?favcat=\(slot)&page=\(page)"
                }
                // 收藏搜索 (对齐 Android FavoritesScene.onGetFavoritesSuccess)
                if let keyword = favSearchKeyword, !keyword.isEmpty {
                    let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
                    favUrl += "&f_search=\(encoded)"
                }
                urlString = favUrl
            }

            let result = try await EhAPI.shared.getGalleryList(url: urlString)

            if page == 0 {
                self.galleries = result.galleries
            } else {
                self.galleries.append(contentsOf: result.galleries)
            }
            self.hasMore = result.nextPage != nil || result.nextHref != nil
            self.prevHref = result.prevHref
            self.nextHref = result.nextHref
            // 解析总页数 (对齐 Android: GalleryListParser 返回的 pages)
            self.totalPages = result.pages
            self.isLoading = false
            print("[EhVM] fetchPage: SUCCESS — \(self.galleries.count) galleries loaded")

            // 缓存第一页结果
            if page == 0 {
                let cacheKey = Self.cacheKey(for: mode, page: 0)
                GalleryCache.shared.putListResult(
                    CachedGalleryListResult(
                        galleries: self.galleries,
                        hasMore: self.hasMore,
                        nextPage: result.nextPage,
                        totalPages: self.totalPages
                    ),
                    forKey: cacheKey
                )
            }

        } catch {
            self.isLoading = false  // 始终重置，包括取消
            print("[EhVM] fetchPage: ERROR \(error)")
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                print("[EhVM] fetchPage: cancelled, no errorMessage set")
                return
            }
            self.errorMessage = EhError.localizedMessage(for: error)
        }
    }

    /// 生成缓存 key
    private static func cacheKey(for mode: GalleryListView.ListMode, page: Int) -> String {
        switch mode {
        case .home: return "home:\(page)"
        case .popular: return "popular:\(page)"
        case .search(let kw): return "search:\(kw):\(page)"
        case .tag(let kw): return "tag:\(kw):\(page)"
        case .favorites(let slot): return "fav:\(slot):\(page)"
        }
    }
}

#if os(iOS)
// iOS already has secondarySystemBackground
#else
extension NSColor {
    static var secondarySystemBackground: NSColor { .controlBackgroundColor }
}
#endif

// MARK: - Right Drawer Overlay (对齐 Android EhDrawerLayout 右侧抽屉)

struct RightDrawerOverlay<DrawerContent: View>: View {
    @Binding var isOpen: Bool
    @ViewBuilder let drawerContent: () -> DrawerContent

    private let drawerWidth: CGFloat = 280
    /// 实时拖拽偏移 (正值 = 向右拖, 负值 = 向左拖)
    @State private var dragOffset: CGFloat = 0
    /// 边缘拖拽进度 (0 = 关闭, 1 = 完全打开)
    @State private var edgeDragProgress: CGFloat = 0
    private let edgeSwipeWidth: CGFloat = 30

    /// 抽屉实际偏移量 (0 = 完全打开, drawerWidth = 完全关闭)
    private var currentOffset: CGFloat {
        if isOpen {
            // 打开状态: 向右拖拽关闭
            return max(0, dragOffset)
        } else {
            // 关闭状态: 边缘拖拽打开
            return drawerWidth * (1 - edgeDragProgress)
        }
    }

    /// 遮罩透明度
    private var overlayOpacity: Double {
        let progress = 1 - (currentOffset / drawerWidth)
        return Double(max(0, min(0.3, progress * 0.3)))
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            // 半透明遮罩
            Color.black
                .opacity(overlayOpacity)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        isOpen = false
                    }
                }
                .allowsHitTesting(isOpen || edgeDragProgress > 0)

            // ★ 懒加载抽屉内容: 仅在打开或拖拽时才渲染 drawerContent，避免每次父视图重渲染时创建 QuickSearchDrawerContent
            Group {
                if isOpen || edgeDragProgress > 0 {
                    drawerContent()
                } else {
                    Color.clear
                }
            }
                .frame(width: drawerWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(.regularMaterial)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12))
                .shadow(color: .black.opacity(overlayOpacity > 0.05 ? 0.15 : 0), radius: 8, x: -3)
                .offset(x: currentOffset)
                .gesture(
                    // 打开状态: 向右拖拽关闭
                    isOpen ?
                    DragGesture(minimumDistance: 8, coordinateSpace: .global)
                        .onChanged { value in
                            let translation = value.translation.width
                            if translation > 0 {
                                dragOffset = translation
                            }
                        }
                        .onEnded { value in
                            let velocity = value.predictedEndTranslation.width
                            if dragOffset > drawerWidth * 0.3 || velocity > 200 {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                    isOpen = false
                                }
                            } else {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                                    dragOffset = 0
                                }
                            }
                            dragOffset = 0
                        }
                    : nil
                )

            // 右侧边缘滑动感应区 (关闭时: 从右向左滑动打开)
            if !isOpen {
                HStack {
                    Spacer()
                    Color.clear
                        .frame(width: edgeSwipeWidth)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 5, coordinateSpace: .global)
                                .onChanged { value in
                                    let translation = -value.translation.width  // 向左为正
                                    if translation > 0 {
                                        edgeDragProgress = min(1, translation / drawerWidth)
                                    }
                                }
                                .onEnded { value in
                                    let velocity = -value.predictedEndTranslation.width
                                    if edgeDragProgress > 0.3 || velocity > 200 {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                            isOpen = true
                                        }
                                    }
                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                                        edgeDragProgress = 0
                                    }
                                }
                        )
                }
            }
        }
        .onChange(of: isOpen) { _, newValue in
            dragOffset = 0
            edgeDragProgress = 0
        }
    }
}

extension View {
    /// 右侧抽屉修饰器 (对齐 Android EhDrawerLayout)
    func rightDrawer<Content: View>(isOpen: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        self.overlay {
            RightDrawerOverlay(isOpen: isOpen, drawerContent: content)
        }
    }
}

#Preview {
    GalleryListView(mode: .home)
}
