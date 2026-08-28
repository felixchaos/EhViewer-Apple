//
//  DownloadsView.swift
//  ehviewer apple
//
//  下载管理视图 (对齐 Android DownloadsScene: 标签分组、搜索、批量操作、状态过滤)
//

import SwiftUI
import EhModels
import EhDownload
import EhDatabase
#if os(macOS)
import AppKit
#endif

// MARK: - 状态过滤枚举

enum DownloadStatusFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case downloading = "下载中"
    case waiting = "等待中"
    case paused = "已暂停"
    case finished = "已完成"
    case failed = "失败"

    var id: String { rawValue }
}

struct DownloadsView: View {
    @State private var vm = DownloadsViewModel()

    // MARK: - 标签/搜索/过滤
    @State private var labels: [DownloadLabelRecord] = []
    /// nil = 全部, "" = 默认(无标签), 其他 = 具体标签
    @State private var selectedLabel: String? = nil
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var statusFilter: DownloadStatusFilter = .all

    // MARK: - 批量操作
    @State private var isSelectMode = false
    @State private var selectedGids: Set<Int64> = []
    @State private var showBatchDeleteConfirm = false
    @State private var showMoveLabelSheet = false

    // MARK: - 单项删除确认 (Fix: 从 Row 移至父视图，避免 Timer 刷新销毁 @State)
    @State private var deletingTaskGid: Int64? = nil
    @State private var showSingleDeleteConfirm = false
    // 分享 (issue #2)
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var exportedZip: ExportedArchive?

    // MARK: - 标签管理
    @State private var showNewLabelAlert = false
    @State private var newLabelName = ""
    @State private var showRenameLabelAlert = false
    @State private var renamingLabel: DownloadLabelRecord?
    @State private var renameText = ""
    @State private var showDeleteLabelConfirm = false
    @State private var deletingLabel: DownloadLabelRecord?

    // MARK: - 阅读器 (fullScreenCover 呈现，隐藏导航栏)
    @State private var readerGallery: GalleryInfo?

    // MARK: - 存储信息
    @State private var gallerySizes: [Int64: Int64] = [:]  // gid -> bytes
    @State private var totalStorageSize: Int64 = 0
    @State private var isCalculatingSize = false
    @State private var readingProgress: [Int64: Int] = [:]  // gid -> page index

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 紧凑页头：标题与动作同一行，避免系统大标题那条空导航栏带
                EhPageHeader(title: "下载") {
                    EhSearchToggleButton(isActive: $isSearching)
                    mainToolbarMenu
                }

                // 标签选择栏
                labelPicker

                // 存储空间概览
                if !vm.tasks.isEmpty {
                    storageOverview
                }

                // 内容
                if filteredTasks.isEmpty {
                    EhStateView(kind: .empty(
                        symbol: "arrow.down.circle",
                        title: emptyTitle,
                        message: emptyDescription
                    ))
                    .frame(maxHeight: .infinity)
                } else {
                    downloadList
                }

                // 批量操作底栏
                if isSelectMode {
                    batchActionBar
                }
            }
            .ehCompactHeader()
            // 搜索改为按钮形态：设计稿的默认状态顶部只有标题与过滤胶囊，
            // 点放大镜才展开统一搜索框。此前用 .searchable，iOS 26 会把它
            // 渲染在屏幕底部，与浮起导航条重叠。
            .ehPageSearch(isActive: $isSearching, text: $searchText, placeholder: "搜索标题或标签")
            // 批量移动标签 Sheet
            .sheet(isPresented: $showMoveLabelSheet) {
                batchMoveLabelSheet
            }
            // 批量删除确认
            .confirmationDialog("确认删除 \(selectedGids.count) 个下载？", isPresented: $showBatchDeleteConfirm, titleVisibility: .visible) {
                Button("仅删除记录", role: .destructive) {
                    batchDelete(withFiles: false)
                }
                Button("删除记录和文件", role: .destructive) {
                    batchDelete(withFiles: true)
                }
            }
            // 单项删除确认 (Fix: 放在父视图，不受 Timer 刷新影响)
            .confirmationDialog("确认删除下载？", isPresented: $showSingleDeleteConfirm, titleVisibility: .visible) {
                Button("仅删除记录", role: .destructive) {
                    if let gid = deletingTaskGid {
                        vm.deleteTask(gid: gid, withFiles: false)
                        // 移除缓存的大小
                        gallerySizes.removeValue(forKey: gid)
                        recalcTotalSize()
                    }
                    deletingTaskGid = nil
                }
                Button("删除记录和文件", role: .destructive) {
                    if let gid = deletingTaskGid {
                        vm.deleteTask(gid: gid, withFiles: true)
                        gallerySizes.removeValue(forKey: gid)
                        recalcTotalSize()
                    }
                    deletingTaskGid = nil
                }
            }
            // 新建标签
            .alert("新建标签", isPresented: $showNewLabelAlert) {
                TextField("标签名称", text: $newLabelName)
                Button("取消", role: .cancel) { newLabelName = "" }
                Button("创建") {
                    createLabel(newLabelName)
                    newLabelName = ""
                }
            }
            // 重命名标签
            .alert("重命名标签", isPresented: $showRenameLabelAlert) {
                TextField("新名称", text: $renameText)
                Button("取消", role: .cancel) { renameText = "" }
                Button("确定") {
                    if let label = renamingLabel {
                        renameLabel(label, newName: renameText)
                    }
                    renameText = ""
                }
            }
            // 删除标签确认
            .confirmationDialog("确认删除标签「\(deletingLabel?.label ?? "")」？\n该标签下的下载将移至默认分组。", isPresented: $showDeleteLabelConfirm, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    if let label = deletingLabel {
                        deleteLabel(label)
                    }
                }
            }
        }
        .task {
            await vm.loadTasks()
            loadLabels()
            await loadReadingProgress()
            await calculateStorageSizes()
        }
    }

    // MARK: - 存储空间概览

    /// 汇总条：正在下载 N 本 · 速度 · 剩余时间 · 网络 | 全部暂停
    ///
    /// 设计稿把这一条放在过滤胶囊下方。它回答的是「现在到底在干什么、还要多久」，
    /// 此前只有「总计 xx MB / N 已完成」——那是静态统计，正在下载时最想知道的
    /// 速度与剩余时间都没有。
    private var storageOverview: some View {
        let active = vm.tasks.filter {
            $0.state == DownloadManager.stateDownload || $0.state == DownloadManager.stateWait
        }
        let speed = active.reduce(0) { $0 + $1.speed }
        let remainingBytes = active.reduce(Int64(0)) { sum, t in
            guard t.gallery.pages > 0, t.downloadedPages < t.gallery.pages else { return sum }
            // 用已下载页的平均大小估算剩余量；没有已完成页时按 300KB/页 兜底
            let avg = t.downloadedPages > 0
                ? Int64(1_200_000 / max(t.downloadedPages, 1))
                : Int64(300_000)
            return sum + avg * Int64(t.gallery.pages - t.downloadedPages)
        }

        return HStack(spacing: EhSpacing.meta) {
            if active.isEmpty {
                Image(systemName: "internaldrive")
                    .font(.system(size: 11))
                    .foregroundStyle(EhColor.tertiaryLabel)
                if isCalculatingSize {
                    ProgressView().controlSize(.mini)
                } else {
                    Text("共 \(vm.tasks.count) 本 · \(Self.formatFileSize(totalStorageSize))")
                        .font(EhFont.mono(11))
                        .foregroundStyle(EhColor.secondaryLabel)
                }
            } else {
                Text("正在下载 \(active.count) 本")
                    .font(EhFont.mono(11, weight: .medium))
                    .foregroundStyle(EhColor.accent)
                if speed > 0 {
                    Text("· \(DownloadTaskRow.formatSpeed(speed))")
                        .font(EhFont.mono(11))
                        .foregroundStyle(EhColor.secondaryLabel)
                    if remainingBytes > 0 {
                        Text("· 剩余约 \(Self.formatDuration(seconds: Double(remainingBytes) / Double(speed)))")
                            .font(EhFont.mono(11))
                            .foregroundStyle(EhColor.secondaryLabel)
                    }
                }
                Text("· \(NetworkReachability.isConstrainedOrCellular ? "蜂窝" : "Wi-Fi")")
                    .font(EhFont.mono(11))
                    .foregroundStyle(EhColor.tertiaryLabel)
            }

            Spacer(minLength: 8)

            if !active.isEmpty {
                Button("全部暂停") {
                    Haptics.tap()
                    vm.pauseAll()
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(EhColor.accent)
                .buttonStyle(.plain)
            } else {
                Button {
                    Task { await calculateStorageSizes() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .foregroundStyle(EhColor.tertiaryLabel)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, EhSpacing.page)
        .padding(.vertical, 8)
    }

    /// 把秒数说成人能读的时长
    private static func formatDuration(seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        if seconds < 60 { return "\(Int(seconds)) 秒" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟" }
        return String(format: "%.1f 小时", seconds / 3600)
    }

    // MARK: - 批量操作底栏

    private var batchActionBar: some View {
        // 浮起玻璃条而非通栏工具栏：与底部导航条同一语言，
        // 且多选态下它是临时出现的，浮条更像「临时接管」而不是常驻结构
        HStack(spacing: 0) {
            let allGids = Set(filteredTasks.map { $0.gallery.gid })
            let isAll = !allGids.isEmpty && selectedGids == allGids

            batchButton(
                symbol: isAll ? "checkmark.circle.fill" : "checkmark.circle",
                title: isAll ? "取消全选" : "全选",
                enabled: !filteredTasks.isEmpty
            ) {
                selectedGids = isAll ? [] : allGids
            }

            batchButton(symbol: "play.fill", title: "开始", enabled: !selectedGids.isEmpty) {
                batchResume()
            }
            batchButton(symbol: "pause.fill", title: "暂停", enabled: !selectedGids.isEmpty) {
                batchPause()
            }
            batchButton(symbol: "tag", title: "标签", enabled: !selectedGids.isEmpty) {
                showMoveLabelSheet = true
            }
            batchButton(
                symbol: "trash", title: "删除",
                enabled: !selectedGids.isEmpty, tint: EhColor.danger
            ) {
                showBatchDeleteConfirm = true
            }
        }
        .frame(height: EhSize.tabBarHeight)
        .ehGlass(cornerRadius: EhSize.tabBarRadius)
        .padding(.horizontal, EhSize.tabBarSideInset)
        .padding(.bottom, EhSize.tabBarBottomInset)
    }

    private func batchButton(
        symbol: String, title: String, enabled: Bool,
        tint: Color = EhColor.accent, action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 17))
                Text(title)
                    .font(EhFont.tiny)
            }
            .foregroundStyle(enabled ? tint : EhColor.tertiaryLabel)
            .frame(maxWidth: .infinity)
            .frame(height: EhSize.tabBarHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: - 存储计算

    private func calculateStorageSizes() async {
        isCalculatingSize = true
        let tasks = vm.tasks
        let downloadDir = DownloadManager.shared.downloadDirectory
        let result: ([Int64: Int64], Int64) = await Task.detached {
            var sizes: [Int64: Int64] = [:]
            for task in tasks {
                let dir = DownloadManager.shared.galleryDirectory(gid: task.gallery.gid, title: task.gallery.bestTitle)
                sizes[task.gallery.gid] = StorageUtils.directorySize(at: dir)
            }
            // 总空间直接从下载根目录计算，确保包含所有文件（含孤立目录和元数据）
            let total = StorageUtils.directorySize(at: downloadDir)
            return (sizes, total)
        }.value
        gallerySizes = result.0
        totalStorageSize = result.1
        isCalculatingSize = false
    }

    private func recalcTotalSize() {
        totalStorageSize = gallerySizes.values.reduce(0, +)
    }

    /// 递归计算目录大小
    static func directorySize(at url: URL) -> Int64 {
        StorageUtils.directorySize(at: url)
    }

    /// 格式化文件大小
    static func formatFileSize(_ bytes: Int64) -> String {
        StorageUtils.formatFileSize(bytes)
    }

    // MARK: - 阅读进度

    private func loadReadingProgress() async {
        let tasks = vm.tasks
        let progress: [Int64: Int] = await Task.detached {
            var result: [Int64: Int] = [:]
            for task in tasks {
                let key = "reading_progress_\(task.gallery.gid)"
                if let page = UserDefaults.standard.object(forKey: key) as? Int {
                    result[task.gallery.gid] = page
                }
            }
            return result
        }.value
        readingProgress = progress
    }

    // MARK: - 过滤后的任务列表

    /// 打包并唤起系统分享 (issue #2)
    private func shareGallery(_ gallery: GalleryInfo) async {
        isExporting = true
        defer { isExporting = false }
        do {
            let url = try await GalleryArchiveExporter.exportZip(for: gallery)
            exportedZip = ExportedArchive(url: url)
        } catch {
            exportError = error.localizedDescription
        }
    }

    private var filteredTasks: [DownloadTask] {
        var tasks = vm.tasks

        // 标签过滤
        if let label = selectedLabel {
            if label.isEmpty {
                // "默认" = 无标签
                tasks = tasks.filter { $0.label == nil || $0.label?.isEmpty == true }
            } else {
                tasks = tasks.filter { $0.label == label }
            }
        }

        // 状态过滤
        switch statusFilter {
        case .all: break
        case .downloading:
            tasks = tasks.filter { $0.state == DownloadManager.stateDownload }
        case .waiting:
            tasks = tasks.filter { $0.state == DownloadManager.stateWait }
        case .paused:
            tasks = tasks.filter { $0.state == DownloadManager.stateNone }
        case .finished:
            tasks = tasks.filter { $0.state == DownloadManager.stateFinish }
        case .failed:
            tasks = tasks.filter { $0.state == DownloadManager.stateFailed }
        }

        // 搜索过滤 —— 标题 + 标签，多个词按 AND
        // (对齐上游 2026-04-20「修复了已下载项目的按标签搜索功能」:
        //  以空格拆词，每个词都要命中，标签支持 `female:xxx` 这种带命名空间的写法)
        let terms = searchText
            .split(whereSeparator: { $0 == " " || $0 == "\u{3000}" })
            .map { String($0).lowercased() }
            .filter { !$0.isEmpty }

        if !terms.isEmpty {
            tasks = tasks.filter { task in
                let title = task.gallery.bestTitle.lowercased()
                let tags = EhDatabase.shared.searchableTags(gid: task.gallery.gid)
                    .map { $0.lowercased() }
                return terms.allSatisfy { term in
                    title.contains(term) || tags.contains { $0.contains(term) }
                }
            }
        }

        return tasks
    }

    private var emptyTitle: String {
        if selectedLabel != nil || statusFilter != .all || !searchText.isEmpty {
            return "无匹配下载"
        }
        return "暂无下载"
    }

    private var emptyDescription: String {
        if selectedLabel != nil || statusFilter != .all || !searchText.isEmpty {
            return "试试更换筛选条件"
        }
        return "在画廊详情页点击下载按钮"
    }

    // MARK: - 标签选择栏 (对齐 Android DownloadsScene Label Drawer)

    /// 顶部胶囊：先按状态过滤，再按标签分组。
    ///
    /// 设计稿这一行是「全部 34 / 进行中 2 / 未读 5 / 收藏组」——带计数的状态过滤，
    /// 而不是只有标签。计数很重要：不点进去就能知道有没有正在跑的、有多少没读，
    /// 这正是打开下载页最常问的两个问题。
    private var labelPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                statusChip(.all, title: "全部", count: vm.tasks.count)
                statusChip(.downloading, title: "进行中", count: activeTaskCount)
                statusChip(.finished, title: "已完成", count: finishedTaskCount)

                if !labels.isEmpty || selectedLabel != nil {
                    Rectangle()
                        .fill(EhColor.hairline)
                        .frame(width: 1, height: 18)
                        .padding(.horizontal, 2)
                }

                labelChip(title: "默认", isSelected: selectedLabel == "") {
                    selectedLabel = selectedLabel == "" ? nil : ""
                    exitSelectMode()
                }
                ForEach(labels, id: \.id) { label in
                    labelChip(title: label.label, isSelected: selectedLabel == label.label) {
                        selectedLabel = selectedLabel == label.label ? nil : label.label
                        exitSelectMode()
                    }
                }
            }
            .padding(.horizontal, EhSpacing.page)
        }
        .frame(height: 46)
    }

    private var activeTaskCount: Int {
        vm.tasks.filter {
            $0.state == DownloadManager.stateDownload || $0.state == DownloadManager.stateWait
        }.count
    }

    private var finishedTaskCount: Int {
        vm.tasks.filter { $0.state == DownloadManager.stateFinish }.count
    }

    private func statusChip(_ filter: DownloadStatusFilter, title: String, count: Int) -> some View {
        let isSelected = statusFilter == filter
        return Button {
            statusFilter = filter
            exitSelectMode()
            Haptics.tap()
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                if count > 0 {
                    Text("\(count)")
                        .font(EhFont.mono(11))
                        .foregroundStyle(
                            isSelected ? EhColor.onAccentFill.opacity(0.7) : EhColor.tertiaryLabel
                        )
                }
            }
            .foregroundStyle(isSelected ? EhColor.onAccentFill : EhColor.secondaryLabel)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background { Capsule().fill(isSelected ? EhColor.accentFill : EhColor.fill) }
        }
        .buttonStyle(.plain)
    }

    private func labelChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            Haptics.tap()
        } label: {
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? EhColor.onAccentFill : EhColor.secondaryLabel)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background { Capsule().fill(isSelected ? EhColor.accentFill : EhColor.fill) }
        }
        .buttonStyle(.plain)
    }

    private func countForFilter(_ filter: DownloadStatusFilter) -> Int {
        // 先用标签+搜索过滤，再按状态计数
        var tasks = vm.tasks
        if let label = selectedLabel {
            if label.isEmpty {
                tasks = tasks.filter { $0.label == nil || $0.label?.isEmpty == true }
            } else {
                tasks = tasks.filter { $0.label == label }
            }
        }
        if !searchText.isEmpty {
            tasks = tasks.filter { $0.gallery.bestTitle.localizedCaseInsensitiveContains(searchText) }
        }

        switch filter {
        case .all: return tasks.count
        case .downloading: return tasks.filter { $0.state == DownloadManager.stateDownload }.count
        case .waiting: return tasks.filter { $0.state == DownloadManager.stateWait }.count
        case .paused: return tasks.filter { $0.state == DownloadManager.stateNone }.count
        case .finished: return tasks.filter { $0.state == DownloadManager.stateFinish }.count
        case .failed: return tasks.filter { $0.state == DownloadManager.stateFailed }.count
        }
    }

    // MARK: - 主工具栏菜单

    private var mainToolbarMenu: some View {
        Menu {
            if isSelectMode {
                // 选择模式工具
                Button {
                    let allGids = Set(filteredTasks.map { $0.gallery.gid })
                    if selectedGids == allGids {
                        selectedGids.removeAll()
                    } else {
                        selectedGids = allGids
                    }
                } label: {
                    let allGids = Set(filteredTasks.map { $0.gallery.gid })
                    Label(selectedGids == allGids ? "取消全选" : "全选",
                          systemImage: selectedGids == allGids ? "square" : "checkmark.square")
                }

                Divider()

                Button {
                    batchResume()
                } label: {
                    Label("批量开始 (\(selectedGids.count))", systemImage: "play")
                }
                .disabled(selectedGids.isEmpty)

                Button {
                    batchPause()
                } label: {
                    Label("批量暂停 (\(selectedGids.count))", systemImage: "pause")
                }
                .disabled(selectedGids.isEmpty)

                // 移动标签
                if !labels.isEmpty {
                    Button {
                        showMoveLabelSheet = true
                    } label: {
                        Label("移动标签 (\(selectedGids.count))", systemImage: "tag")
                    }
                    .disabled(selectedGids.isEmpty)
                }

                Divider()

                Button(role: .destructive) {
                    showBatchDeleteConfirm = true
                } label: {
                    Label("批量删除 (\(selectedGids.count))", systemImage: "trash")
                }
                .disabled(selectedGids.isEmpty)

                Divider()

                Button {
                    exitSelectMode()
                } label: {
                    Label("退出选择", systemImage: "xmark.circle")
                }
            } else {
                // 普通模式

                // 状态过滤 (对齐 Android DownloadsScene 状态筛选)
                Picker("状态过滤", selection: $statusFilter) {
                    ForEach(DownloadStatusFilter.allCases) { filter in
                        let count = countForFilter(filter)
                        if filter == .all {
                            Text(filter.rawValue).tag(filter)
                        } else {
                            Text("\(filter.rawValue) (\(count))").tag(filter)
                        }
                    }
                }

                Divider()

                Button {
                    isSelectMode = true
                    selectedGids.removeAll()
                } label: {
                    Label("批量操作", systemImage: "checkmark.circle")
                }

                Divider()

                Button {
                    vm.resumeAll()
                } label: {
                    Label("全部开始", systemImage: "play.fill")
                }

                Button {
                    vm.pauseAll()
                } label: {
                    Label("全部暂停", systemImage: "pause.fill")
                }

                Divider()

                Button(role: .destructive) {
                    vm.clearFinished()
                } label: {
                    Label("清空已完成", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: isSelectMode ? "checkmark.circle.fill" : "ellipsis.circle")
        }
    }

    // MARK: - 下载列表

    private var downloadList: some View {
        List {
            ForEach(filteredTasks, id: \.gallery.gid) { task in
                if isSelectMode {
                    Button {
                        toggleSelection(gid: task.gallery.gid)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selectedGids.contains(task.gallery.gid) ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(selectedGids.contains(task.gallery.gid) ? Color.accentColor : Color.secondary)

                            DownloadTaskRow(
                                task: task,
                                readingPage: readingProgress[task.gallery.gid],
                                storageSize: gallerySizes[task.gallery.gid]
                            ) {
                                vm.pauseTask(gid: task.gallery.gid)
                            } onResume: {
                                vm.resumeTask(gid: task.gallery.gid)
                            } onRequestDelete: {
                                deletingTaskGid = task.gallery.gid
                                showSingleDeleteConfirm = true
                            } onShare: {
                                Task { await shareGallery(task.gallery) }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    // 点击打开阅读器 (使用 fullScreenCover 避免导航栏残留)
                    Button {
                        readerGallery = task.gallery
                    } label: {
                        DownloadTaskRow(
                            task: task,
                            readingPage: readingProgress[task.gallery.gid],
                            storageSize: gallerySizes[task.gallery.gid]
                        ) {
                            vm.pauseTask(gid: task.gallery.gid)
                        } onResume: {
                            vm.resumeTask(gid: task.gallery.gid)
                        } onRequestDelete: {
                            deletingTaskGid = task.gallery.gid
                            showSingleDeleteConfirm = true
                        } onShare: {
                            Task { await shareGallery(task.gallery) }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.plain)
        #if os(iOS)
        .ehTabBarAutoHide()
        #endif
        .overlay {
            if isExporting {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在打包…").font(.footnote).foregroundStyle(.secondary)
                }
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .alert("分享失败", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("好") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .sheet(item: $exportedZip) { archive in
            #if os(iOS)
            ShareSheet(items: [archive.url])
            #else
            // macOS: 直接在 Finder 里定位打包好的 zip
            Color.clear.onAppear {
                NSWorkspace.shared.activateFileViewerSelecting([archive.url])
                exportedZip = nil
            }
            #endif
        }
        #if os(iOS)
        .fullScreenCover(item: $readerGallery) { gallery in
            ImageReaderView(gid: gallery.gid, token: gallery.token, pages: gallery.pages)
                .id(gallery.gid)
        }
        #else
        .sheet(item: $readerGallery) { gallery in
            ImageReaderView(gid: gallery.gid, token: gallery.token, pages: gallery.pages)
                .id(gallery.gid)
                .frame(minWidth: 800, minHeight: 600)
        }
        #endif
    }

    // MARK: - 批量移动标签 Sheet

    private var batchMoveLabelSheet: some View {
        NavigationStack {
            List {
                // 移到默认 (无标签)
                Button {
                    batchChangeLabel(nil)
                    showMoveLabelSheet = false
                } label: {
                    Label("默认", systemImage: "tray")
                }

                // 具体标签
                ForEach(labels, id: \.id) { label in
                    Button {
                        batchChangeLabel(label.label)
                        showMoveLabelSheet = false
                    } label: {
                        Label(label.label, systemImage: "tag")
                    }
                }
            }
            .navigationTitle("移动到标签")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showMoveLabelSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - 辅助

    private func toggleSelection(gid: Int64) {
        if selectedGids.contains(gid) {
            selectedGids.remove(gid)
        } else {
            selectedGids.insert(gid)
        }
    }

    private func exitSelectMode() {
        isSelectMode = false
        selectedGids.removeAll()
    }

    // MARK: - 标签管理

    private func loadLabels() {
        labels = (try? EhDatabase.shared.getAllDownloadLabels()) ?? []
    }

    private func createLabel(_ name: String) {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        try? EhDatabase.shared.insertDownloadLabel(name.trimmingCharacters(in: .whitespaces))
        loadLabels()
    }

    private func renameLabel(_ record: DownloadLabelRecord, newName: String) {
        guard !newName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let oldLabel = record.label
        var updated = record
        updated.label = newName.trimmingCharacters(in: .whitespaces)
        try? EhDatabase.shared.updateDownloadLabel(updated)

        // 更新使用旧标签的下载任务
        Task {
            let tasksWithOldLabel = await DownloadManager.shared.getAllTasks().filter { $0.label == oldLabel }
            await DownloadManager.shared.changeLabel(gids: tasksWithOldLabel.map { $0.gallery.gid }, label: updated.label)
            await vm.loadTasks()
        }

        if selectedLabel == oldLabel {
            selectedLabel = updated.label
        }
        loadLabels()
    }

    private func deleteLabel(_ record: DownloadLabelRecord) {
        guard let id = record.id else { return }
        let labelName = record.label

        // 将该标签下的任务移至默认 (无标签)
        Task {
            let tasksWithLabel = await DownloadManager.shared.getAllTasks().filter { $0.label == labelName }
            await DownloadManager.shared.changeLabel(gids: tasksWithLabel.map { $0.gallery.gid }, label: nil)
            await vm.loadTasks()
        }

        try? EhDatabase.shared.deleteDownloadLabel(id: id)
        if selectedLabel == labelName { selectedLabel = nil }
        loadLabels()
    }

    // MARK: - 批量操作

    private func batchPause() {
        Task {
            for gid in selectedGids {
                await DownloadManager.shared.pauseDownload(gid: gid)
            }
            await vm.loadTasks()
            exitSelectMode()
        }
    }

    private func batchResume() {
        Task {
            for gid in selectedGids {
                await DownloadManager.shared.resumeDownload(gid: gid)
            }
            await vm.loadTasks()
            exitSelectMode()
        }
    }

    private func batchDelete(withFiles: Bool) {
        Task {
            for gid in selectedGids {
                await DownloadManager.shared.deleteDownload(gid: gid, deleteFiles: withFiles)
            }
            await vm.loadTasks()
            exitSelectMode()
        }
    }

    private func batchChangeLabel(_ label: String?) {
        Task {
            await DownloadManager.shared.changeLabel(gids: Array(selectedGids), label: label)
            await vm.loadTasks()
            exitSelectMode()
        }
    }
}

// MARK: - Download Task Row

struct DownloadTaskRow: View {
    let task: DownloadTask
    let readingPage: Int?      // 阅读进度 (当前页索引)
    let storageSize: Int64?    // 画廊占用空间 (字节)
    let onPause: () -> Void
    let onResume: () -> Void
    let onRequestDelete: () -> Void   // 请求删除 (由父视图处理确认)
    let onShare: () -> Void           // 打包为 zip 并分享 (issue #2)

    /// 已读比例，画在封面底部
    private var readProgressFraction: Double? {
        guard let page = readingPage, task.gallery.pages > 0 else { return nil }
        return Double(page + 1) / Double(task.gallery.pages)
    }

    /// 状态色：完成绿 / 下载中琥珀 / 失败红 / 其余次级
    private var statusColor: Color {
        switch task.state {
        case DownloadManager.stateFinish:   return EhColor.success
        case DownloadManager.stateDownload: return EhColor.accent
        case DownloadManager.stateFailed:   return EhColor.danger
        default:                            return EhColor.secondaryLabel
        }
    }

    private func circleActionButton(symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(EhColor.accent)
                .frame(width: 28, height: 28)
                .background(Circle().fill(EhColor.fill))
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        HStack(spacing: EhSpacing.row) {
            EhCoverThumbnail(
                url: task.gallery.thumb,
                size: EhSize.downloadThumbnail,
                cornerRadius: EhRadius.smallThumbnail,
                readProgress: readProgressFraction
            )

            VStack(alignment: .leading, spacing: 5) {
                Text(task.gallery.bestTitle)
                    .font(EhFont.body)
                    .foregroundStyle(EhColor.label)
                    .lineLimit(2)

                // 状态用颜色表达，不再依赖图标 + 灰字：
                // 「失败」和「已完成」在一列灰字里几乎分辨不出来
                HStack(spacing: EhSpacing.meta) {
                    Text(statusText)
                        .font(EhFont.mono(11, weight: .medium))
                        .foregroundStyle(statusColor)

                    Text("\(task.gallery.pages) 页")
                        .font(EhFont.mono(11))
                        .foregroundStyle(EhColor.secondaryLabel)

                    if let size = storageSize, size > 0 {
                        Text(DownloadsView.formatFileSize(size))
                            .font(EhFont.mono(11))
                            .foregroundStyle(EhColor.tertiaryLabel)
                    }

                    Spacer(minLength: 0)
                }

                // 下载中才画进度条：已完成的行画一条 100% 的条没有信息量，
                // 只会让列表看起来更吵
                if task.state == DownloadManager.stateDownload || task.state == DownloadManager.stateWait {
                    HStack(spacing: EhSpacing.meta) {
                        ZStack(alignment: .leading) {
                            Capsule().fill(EhColor.fill)
                            GeometryReader { geo in
                                Capsule()
                                    .fill(EhColor.accentFill)
                                    .frame(width: geo.size.width * max(0, min(1, downloadProgress)))
                            }
                        }
                        .frame(height: 3)

                        Text("\(Int(downloadProgress * 100))%")
                            .font(EhFont.mono(11, weight: .medium))
                            .foregroundStyle(EhColor.accent)
                            .frame(width: 34, alignment: .trailing)
                    }

                    HStack(spacing: EhSpacing.meta) {
                        Text("\(task.downloadedPages)/\(task.gallery.pages)")
                            .font(EhFont.mono(11))
                            .foregroundStyle(EhColor.tertiaryLabel)
                        if task.speed > 0 {
                            Text(Self.formatSpeed(task.speed))
                                .font(EhFont.mono(11))
                                .foregroundStyle(EhColor.info)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }

            // 圆形动作钮：暂停/继续是这一行最常按的东西，
            // 此前只能长按出上下文菜单
            if task.state == DownloadManager.stateDownload || task.state == DownloadManager.stateWait {
                circleActionButton(symbol: "pause.fill", action: onPause)
            } else if task.state != DownloadManager.stateFinish {
                circleActionButton(symbol: "arrow.clockwise", action: onResume)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            // 暂停/恢复
            if task.state == DownloadManager.stateDownload || task.state == DownloadManager.stateWait {
                Button {
                    onPause()
                } label: {
                    Label("暂停", systemImage: "pause")
                }
            } else if task.state != DownloadManager.stateFinish {
                Button {
                    onResume()
                } label: {
                    Label("继续", systemImage: "play")
                }
            }

            // 分享 (issue #2: 打包成 zip 交给系统分享)
            if task.state == DownloadManager.stateFinish {
                Button {
                    onShare()
                } label: {
                    Label("分享 (打包为 zip)", systemImage: "square.and.arrow.up")
                }
            }

            Divider()

            // 删除 (请求父视图弹出确认)
            Button(role: .destructive) {
                onRequestDelete()
            } label: {
                Label("删除", systemImage: "trash")
            }

            #if os(macOS)
            // Mac: 在 Finder 中显示 (Fix A-3: 使用统一路径算法)
            if task.state == DownloadManager.stateFinish {
                Button {
                    let dirName = DownloadManager.galleryDirectoryName(gid: task.gallery.gid, title: task.gallery.bestTitle)
                    let dir = DownloadManager.shared.downloadDirectory
                        .appendingPathComponent(dirName)
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir.path)
                } label: {
                    Label("在 Finder 中显示", systemImage: "folder")
                }
            }
            #endif
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                onRequestDelete()
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            if task.state == DownloadManager.stateDownload || task.state == DownloadManager.stateWait {
                Button {
                    onPause()
                } label: {
                    Label("暂停", systemImage: "pause")
                }
                .tint(.orange)
            } else if task.state != DownloadManager.stateFinish {
                Button {
                    onResume()
                } label: {
                    Label("继续", systemImage: "play")
                }
                .tint(.green)
            }
        }
    }

    private var statusIcon: some View {
        Group {
            switch task.state {
            case DownloadManager.stateDownload:
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
            case DownloadManager.stateWait:
                Image(systemName: "clock.fill")
                    .foregroundStyle(.orange)
            case DownloadManager.stateFinish:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case DownloadManager.stateFailed:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            default:
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    private var statusText: String {
        switch task.state {
        case DownloadManager.stateDownload: return "下载中"
        case DownloadManager.stateWait: return "等待中"
        case DownloadManager.stateFinish: return "已完成"
        case DownloadManager.stateFailed: return "失败"
        default: return "已暂停"
        }
    }

    private var downloadProgress: Double {
        guard task.gallery.pages > 0 else { return 0 }
        return Double(task.downloadedPages) / Double(task.gallery.pages)
    }

    /// 自适应格式化下载速度 (KB/s 或 MB/s)
    static func formatSpeed(_ bytesPerSecond: Int64) -> String {
        let kb = Double(bytesPerSecond) / 1024.0
        if kb < 1024 {
            return String(format: "%.1f KB/s", kb)
        }
        let mb = kb / 1024.0
        return String(format: "%.2f MB/s", mb)
    }
}

// MARK: - ViewModel

@Observable
class DownloadsViewModel {
    var tasks: [DownloadTask] = []
    /// 进度刷新定时器 (有活跃下载时每秒刷新)
    private var refreshTimer: Timer?

    func loadTasks() async {
        tasks = await DownloadManager.shared.getAllTasks()
        updateRefreshTimer()
    }

    /// 检查是否有活跃下载，有则启动定时刷新
    private func updateRefreshTimer() {
        let hasActive = tasks.contains(where: {
            $0.state == DownloadManager.stateDownload || $0.state == DownloadManager.stateWait
        })

        if hasActive && refreshTimer == nil {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.tasks = await DownloadManager.shared.getAllTasks()
                    // 如果没有活跃下载了，停止定时器
                    let stillActive = self.tasks.contains(where: {
                        $0.state == DownloadManager.stateDownload || $0.state == DownloadManager.stateWait
                    })
                    if !stillActive {
                        self.refreshTimer?.invalidate()
                        self.refreshTimer = nil
                    }
                }
            }
        } else if !hasActive {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    func pauseTask(gid: Int64) {
        Task {
            await DownloadManager.shared.pauseDownload(gid: gid)
            await loadTasks()
        }
    }

    func resumeTask(gid: Int64) {
        Task {
            await DownloadManager.shared.resumeDownload(gid: gid)
            await loadTasks()
        }
    }

    func deleteTask(gid: Int64, withFiles: Bool = false) {
        Task {
            await DownloadManager.shared.deleteDownload(gid: gid, deleteFiles: withFiles)
            await loadTasks()
        }
    }

    func pauseAll() {
        Task {
            // 使用 DownloadManager 的批量暂停，避免逐个暂停时 processQueue 不断启动下一个
            await DownloadManager.shared.pauseAllDownloads()
            await loadTasks()
        }
    }

    func resumeAll() {
        Task {
            for task in tasks where task.state == DownloadManager.stateNone || task.state == DownloadManager.stateFailed {
                await DownloadManager.shared.resumeDownload(gid: task.gallery.gid)
            }
            // 强制尝试处理队列 (防止 isRunning 残留为 true 导致队列卡死)
            await DownloadManager.shared.kickQueue()
            await loadTasks()
        }
    }

    /// Fix A-2: 清除已完成下载时同时删除文件，释放磁盘空间
    func clearFinished() {
        Task {
            for task in tasks where task.state == DownloadManager.stateFinish {
                await DownloadManager.shared.deleteDownload(gid: task.gallery.gid, deleteFiles: true)
            }
            await loadTasks()
        }
    }
}

// MARK: - 存储工具 (非 MainActor，可在后台线程安全调用)

enum StorageUtils: Sendable {
    /// 递归计算目录大小
    nonisolated static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { return 0 }
        var totalSize: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  resourceValues.isRegularFile == true,
                  let fileSize = resourceValues.fileSize else { continue }
            totalSize += Int64(fileSize)
        }
        return totalSize
    }

    /// 格式化文件大小
    nonisolated static func formatFileSize(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024.0
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024.0
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        let gb = mb / 1024.0
        return String(format: "%.2f GB", gb)
    }
}

#Preview {
    DownloadsView()
}
