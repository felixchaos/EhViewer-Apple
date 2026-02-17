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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 标签选择栏
                labelPicker

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
        }
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

                            DownloadTaskRow(task: task) {
                                vm.pauseTask(gid: task.gallery.gid)
                            } onResume: {
                                vm.resumeTask(gid: task.gallery.gid)
                            } onDelete: { withFiles in
                                vm.deleteTask(gid: task.gallery.gid, withFiles: withFiles)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    // 点击打开阅读器 (使用 fullScreenCover 避免导航栏残留)
                    Button {
                        readerGallery = task.gallery
                    } label: {
                        DownloadTaskRow(task: task) {
                            vm.pauseTask(gid: task.gallery.gid)
                        } onResume: {
                            vm.resumeTask(gid: task.gallery.gid)
                        } onDelete: { withFiles in
                            vm.deleteTask(gid: task.gallery.gid, withFiles: withFiles)
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
    let onPause: () -> Void
    let onResume: () -> Void
    let onDelete: (_ withFiles: Bool) -> Void

    @State private var showDeleteConfirm = false

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

            VStack(alignment: .leading, spacing: 6) {
                // 标题
                Text(task.gallery.bestTitle)
                    .font(.subheadline)
                    .lineLimit(2)

                // 状态
                HStack(spacing: 8) {
                    statusIcon
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text("\(task.gallery.pages) 页")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // 进度条 + 页数详情
                if task.state == DownloadManager.stateDownload || task.state == DownloadManager.stateWait {
                    VStack(spacing: 2) {
                        ProgressView(value: progress)
                            .tint(.accentColor)
                        HStack {
                            Text("\(task.downloadedPages)/\(task.gallery.pages)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(progress * 100))%")
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

            // 删除
            Button(role: .destructive) {
                showDeleteConfirm = true
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
                showDeleteConfirm = true
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
        .confirmationDialog("确认删除下载？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("仅删除记录", role: .destructive) {
                onDelete(false)
            }
            Button("删除记录和文件", role: .destructive) {
                onDelete(true)
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

    private var progress: Double {
        guard task.gallery.pages > 0 else { return 0 }
        return Double(task.downloadedPages) / Double(task.gallery.pages)
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

#Preview {
    DownloadsView()
}
