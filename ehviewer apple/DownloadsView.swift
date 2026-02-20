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
    @State private var statusFilter: DownloadStatusFilter = .all

    // MARK: - 批量操作
    @State private var isSelectMode = false
    @State private var selectedGids: Set<Int64> = []
    @State private var showBatchDeleteConfirm = false
    @State private var showMoveLabelSheet = false

    // MARK: - 单项删除确认 (Fix: 从 Row 移至父视图，避免 Timer 刷新销毁 @State)
    @State private var deletingTaskGid: Int64? = nil
    @State private var showSingleDeleteConfirm = false

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
                // 标签选择栏
                labelPicker

                // 存储空间概览
                if !vm.tasks.isEmpty {
                    storageOverview
                }

                // 内容
                if filteredTasks.isEmpty {
                    ContentUnavailableView(
                        emptyTitle,
                        systemImage: "arrow.down.circle",
                        description: Text(emptyDescription)
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    downloadList
                }

                // 批量操作底栏
                if isSelectMode {
                    batchActionBar
                }
            }
            .navigationTitle("下载")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $searchText, prompt: "搜索下载")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    mainToolbarMenu
                }
            }
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

    private var storageOverview: some View {
        HStack(spacing: 12) {
            // 总存储
            HStack(spacing: 4) {
                Image(systemName: "internaldrive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isCalculatingSize {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                } else {
                    Text("总计 \(Self.formatFileSize(totalStorageSize))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // 下载数统计
            let activeCount = vm.tasks.filter { $0.state == DownloadManager.stateDownload || $0.state == DownloadManager.stateWait }.count
            let finishedCount = vm.tasks.filter { $0.state == DownloadManager.stateFinish }.count
            if activeCount > 0 {
                Text("\(activeCount) 进行中")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
            Text("\(finishedCount)/\(vm.tasks.count) 已完成")
                .font(.caption)
                .foregroundStyle(.secondary)

            // 刷新按钮
            Button {
                Task { await calculateStorageSizes() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - 批量操作底栏

    private var batchActionBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                // 全选/取消全选
                Button {
                    let allGids = Set(filteredTasks.map { $0.gallery.gid })
                    if selectedGids == allGids {
                        selectedGids.removeAll()
                    } else {
                        selectedGids = allGids
                    }
                } label: {
                    let allGids = Set(filteredTasks.map { $0.gallery.gid })
                    VStack(spacing: 2) {
                        Image(systemName: selectedGids == allGids ? "checkmark.circle" : "checkmark.circle.fill")
                            .font(.title3)
                        Text(selectedGids == allGids ? "取消全选" : "全选")
                            .font(.caption2)
                    }
                }
                .frame(maxWidth: .infinity)

                // 开始
                Button {
                    batchResume()
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "play.fill")
                            .font(.title3)
                        Text("开始")
                            .font(.caption2)
                    }
                }
                .disabled(selectedGids.isEmpty)
                .frame(maxWidth: .infinity)

                // 暂停
                Button {
                    batchPause()
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "pause.fill")
                            .font(.title3)
                        Text("暂停")
                            .font(.caption2)
                    }
                }
                .disabled(selectedGids.isEmpty)
                .frame(maxWidth: .infinity)

                // 移动标签
                Button {
                    showMoveLabelSheet = true
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "tag")
                            .font(.title3)
                        Text("标签")
                            .font(.caption2)
                    }
                }
                .disabled(selectedGids.isEmpty)
                .frame(maxWidth: .infinity)

                // 删除
                Button {
                    showBatchDeleteConfirm = true
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "trash")
                            .font(.title3)
                        Text("删除")
                            .font(.caption2)
                    }
                    .foregroundColor(selectedGids.isEmpty ? .secondary : .red)
                }
                .disabled(selectedGids.isEmpty)
                .frame(maxWidth: .infinity)

                // 退出选择
                Button {
                    exitSelectMode()
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "xmark.circle")
                            .font(.title3)
                        Text("退出")
                            .font(.caption2)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .background(.bar)

            // 已选计数
            if !selectedGids.isEmpty {
                Text("已选择 \(selectedGids.count) 项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
            }
        }
    }

    // MARK: - 存储计算

    private func calculateStorageSizes() async {
        isCalculatingSize = true
        let tasks = vm.tasks
        let sizes: [Int64: Int64] = await Task.detached {
            var result: [Int64: Int64] = [:]
            for task in tasks {
                let dir = DownloadManager.shared.galleryDirectory(gid: task.gallery.gid, title: task.gallery.bestTitle)
                result[task.gallery.gid] = StorageUtils.directorySize(at: dir)
            }
            return result
        }.value
        gallerySizes = sizes
        recalcTotalSize()
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

        // 搜索过滤
        if !searchText.isEmpty {
            tasks = tasks.filter {
                $0.gallery.bestTitle.localizedCaseInsensitiveContains(searchText)
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

    private var labelPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // 全部
                labelChip(title: "全部", isSelected: selectedLabel == nil) {
                    selectedLabel = nil
                    exitSelectMode()
                }

                // 默认 (无标签)
                labelChip(title: "默认", isSelected: selectedLabel == "") {
                    selectedLabel = ""
                    exitSelectMode()
                }

                // 自定义标签
                ForEach(labels, id: \.id) { label in
                    labelChip(title: label.label, isSelected: selectedLabel == label.label) {
                        selectedLabel = label.label
                        exitSelectMode()
                    }
                    .contextMenu {
                        Button {
                            renamingLabel = label
                            renameText = label.label
                            showRenameLabelAlert = true
                        } label: {
                            Label("重命名", systemImage: "pencil")
                        }

                        Button(role: .destructive) {
                            deletingLabel = label
                            showDeleteLabelConfirm = true
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }

                // 新增标签按钮
                Button {
                    showNewLabelAlert = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private func labelChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : Color(.tertiarySystemFill))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule())
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
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.plain)
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
            .navigationBarTitleDisplayMode(.inline)
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

    var body: some View {
        HStack(spacing: 12) {
            // 封面
            CachedAsyncImage(url: URL(string: task.gallery.thumb ?? "")) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color(.tertiarySystemFill)
            }
            .frame(width: 52, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 5) {
                // 标题
                Text(task.gallery.bestTitle)
                    .font(.subheadline)
                    .lineLimit(2)

                // 状态 + 页数 + 存储
                HStack(spacing: 6) {
                    statusIcon
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    // 占用空间
                    if let size = storageSize, size > 0 {
                        Text(DownloadsView.formatFileSize(size))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }

                    Text("\(task.gallery.pages) 页")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // 阅读进度 (已完成 / 非下载中 状态显示)
                if let page = readingPage, task.gallery.pages > 0,
                   task.state != DownloadManager.stateDownload && task.state != DownloadManager.stateWait {
                    HStack(spacing: 6) {
                        ProgressView(value: Double(page + 1), total: Double(task.gallery.pages))
                            .tint(.green)
                        Text("阅读 \(page + 1)/\(task.gallery.pages)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                // 下载进度条 + 页数详情 (下载中/等待中)
                if task.state == DownloadManager.stateDownload || task.state == DownloadManager.stateWait {
                    VStack(spacing: 2) {
                        ProgressView(value: downloadProgress)
                            .tint(.accentColor)
                        HStack {
                            Text("\(task.downloadedPages)/\(task.gallery.pages)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if task.speed > 0 {
                                Text(Self.formatSpeed(task.speed))
                                    .font(.caption2)
                                    .foregroundStyle(.blue)
                            }
                            Text("\(Int(downloadProgress * 100))%")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
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
            for task in tasks where task.state == DownloadManager.stateDownload || task.state == DownloadManager.stateWait {
                await DownloadManager.shared.pauseDownload(gid: task.gallery.gid)
            }
            await loadTasks()
        }
    }

    func resumeAll() {
        Task {
            for task in tasks where task.state == DownloadManager.stateNone || task.state == DownloadManager.stateFailed {
                await DownloadManager.shared.resumeDownload(gid: task.gallery.gid)
            }
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

enum StorageUtils {
    /// 递归计算目录大小
    static func directorySize(at url: URL) -> Int64 {
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
    static func formatFileSize(_ bytes: Int64) -> String {
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
