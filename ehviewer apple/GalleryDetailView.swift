//
//  GalleryDetailView.swift
//  ehviewer apple
//
//  画廊详情视图
//

import SwiftUI
import EhModels
import EhDownload
import EhAPI
import EhSettings
import EhDatabase

// MARK: - 标签导航支持 (对齐 Android: onTagClick → 推入新画廊列表到左侧导航栈)

/// 标签搜索导航目标 — 用于 NavigationStack 的 path
struct TagSearchDestination: Hashable {
    let tag: String
}

/// 标签导航动作 — 从 Detail 列传递到 Content/Sidebar 列的 NavigationStack
struct TagNavigationAction {
    let navigate: (String) -> Void
}

private struct TagNavigationActionKey: EnvironmentKey {
    static let defaultValue: TagNavigationAction? = nil
}

extension EnvironmentValues {
    var tagNavigationAction: TagNavigationAction? {
        get { self[TagNavigationActionKey.self] }
        set { self[TagNavigationActionKey.self] = newValue }
    }
}

struct GalleryDetailView: View {
    let gallery: GalleryInfo

    @State private var vm = GalleryDetailViewModel()
    @State private var showAllTags = false
    @State private var showRatingSheet = false
    @State private var showAllPreviews = false
    @State private var showFavoritePicker = false

    /// 标签点击导航动作 — 在 Split/三栏布局中将标签列表推入左侧栏
    @Environment(\.tagNavigationAction) private var tagNavigationAction
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerSection
                Divider()
                actionBar
                Divider()

                if vm.isLoading {
                    ProgressView("加载详情...")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else if let error = vm.errorMessage {
                    errorSection(error)
                } else {
                    if !vm.tags.isEmpty {
                        tagSection
                        Divider()
                    }
                    // 评论在预览图之前（对齐 Android 布局）
                    // 对齐 Android GalleryDetailScene: Settings.getShowGalleryComment() 控制显示
                    if AppSettings.shared.showGalleryComment {
                        commentSection
                    }
                    if let previewSet = vm.previewSet, !previewSet.isEmpty {
                        previewSection(previewSet)
                    }
                }
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(horizontalSizeClass == .compact ? .hidden : .automatic, for: .navigationBar)
        .overlay(alignment: .topLeading) {
            // iPhone: 自定义返回按钮 (导航栏隐藏后)
            if horizontalSizeClass == .compact {
                AppBackButton(action: { dismiss() }, style: .dark)
                .padding(.top, 4)
                .padding(.leading, 12)
            }
        }
        .enableEdgeSwipeBack()
        #endif
        #if os(iOS)
        .fullScreenCover(isPresented: $vm.startReading) {
            // 全屏呈现阅读器，完全隐藏导航栏
            // 对齐 Android: intent.putExtra(GalleryActivity.KEY_PAGE, index)
            ImageReaderView(
                gid: gallery.gid,
                token: gallery.token,
                pages: vm.detail?.info.pages ?? gallery.pages,
                previewSet: vm.detail?.previewSet,
                initialPage: vm.readerInitialPage
            )
        }
        #else
        .navigationDestination(isPresented: $vm.startReading) {
            // macOS: 在导航栈中推入阅读器，支持窗口自由调整大小
            ImageReaderView(
                gid: gallery.gid,
                token: gallery.token,
                pages: vm.detail?.info.pages ?? gallery.pages,
                previewSet: vm.detail?.previewSet,
                initialPage: vm.readerInitialPage
            )
        }
        #endif
        .task {
            await vm.loadDetail(gid: gallery.gid, token: gallery.token)
        }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: .downloadGallery)) { _ in
            Task { await vm.startDownload(gallery: gallery) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .favoriteGallery)) { _ in
            if vm.isFavorited {
                Task { await vm.removeFavorite(gid: gallery.gid, token: gallery.token) }
            } else {
                let defaultSlot = AppSettings.shared.defaultFavSlot
                if defaultSlot >= 0 && defaultSlot <= 9 {
                    Task { await vm.addFavorite(gid: gallery.gid, token: gallery.token, slot: defaultSlot) }
                } else {
                    showFavoritePicker = true
                }
            }
        }
        #endif
        .sheet(isPresented: $showRatingSheet) {
            RatingSheet(
                currentRating: vm.displayRating ?? gallery.rating,
                onRate: { rating in
                    Task { await vm.rateGallery(gid: gallery.gid, token: gallery.token, rating: rating) }
                }
            )
            .presentationDetents([.height(200)])
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 14) {
            // 封面
            CachedAsyncImage(url: URL(string: gallery.thumb ?? "")) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color(.secondarySystemBackground)
            }
            .frame(width: 120, height: 168)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 6) {
                // 根据设置显示日文/中文或英文标题 (对齐 Android EhUtils.getSuitableTitle)
                Text(gallery.suitableTitle(preferJpn: AppSettings.shared.showJpnTitle))
                    .font(.headline)
                    .lineLimit(4)

                if let uploader = gallery.uploader {
                    Text(uploader)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                // 分类标签
                Text(gallery.category.name)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(gallery.category.color)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                // 评分 (可点击)
                HStack(spacing: 4) {
                    ForEach(0..<5) { i in
                        Image(systemName: ratingIcon(index: i, rating: vm.displayRating ?? gallery.rating))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Text(String(format: "%.2f", vm.displayRating ?? gallery.rating))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .onTapGesture {
                    if vm.canRate {
                        showRatingSheet = true
                    }
                }

                // 详情信息
                if let lang = vm.language {
                    Label(lang, systemImage: "globe")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Label("\(gallery.pages) 页", systemImage: "doc")
                    if let size = vm.size {
                        Label(size, systemImage: "internaldrive")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: 0) {
            let readTitle = hasReadingProgress ? "继续阅读" : "阅读"
            actionButton(icon: "book", title: readTitle) {
                // 对齐 Android: 阅读按钮不传 KEY_PAGE，让阅读器自行恢复进度
                vm.readerInitialPage = nil
                vm.startReading = true
            }
            Divider().frame(height: 32)
            actionButton(icon: vm.isFavorited ? "heart.fill" : "heart",
                         title: vm.isFavorited ? "已收藏" : "收藏",
                         action: {
                if vm.isFavorited {
                    Task { await vm.removeFavorite(gid: gallery.gid, token: gallery.token) }
                } else {
                    let defaultSlot = AppSettings.shared.defaultFavSlot
                    if defaultSlot == -1 {
                        vm.addLocalFavorite(gallery: gallery)
                    } else if defaultSlot >= 0 && defaultSlot <= 9 {
                        Task { await vm.addFavorite(gid: gallery.gid, token: gallery.token, slot: defaultSlot) }
                    } else {
                        showFavoritePicker = true
                    }
                }
            },
            // 对齐 Android: 长按收藏按钮始终弹出收藏夹选择，即使已设置默认
            longPressAction: {
                showFavoritePicker = true
            })
            Divider().frame(height: 32)
            actionButton(icon: vm.downloadIcon,
                         title: vm.downloadTitle) {
                Task { await vm.startDownload(gallery: gallery) }
            }
            Divider().frame(height: 32)
            actionButton(icon: "square.and.arrow.up", title: "分享") {
                let site = GalleryActionService.siteBaseURL
                let urlStr = "\(site)g/\(gallery.gid)/\(gallery.token)/"
                #if os(iOS)
                guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                      let window = windowScene.windows.first,
                      let rootVC = window.rootViewController else { return }
                let activityVC = UIActivityViewController(activityItems: [urlStr], applicationActivities: nil)
                // iPad 需要 popover
                if let popover = activityVC.popoverPresentationController {
                    popover.sourceView = window
                    popover.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 0, height: 0)
                    popover.permittedArrowDirections = []
                }
                rootVC.present(activityVC, animated: true)
                #else
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(urlStr, forType: .string)
                #endif
            }
        }
        .padding(.vertical, 8)
        .sheet(isPresented: $showFavoritePicker) {
            FavoriteSlotPicker(
                onSelect: { slot in
                    showFavoritePicker = false
                    if slot == -1 {
                        // 本地收藏 (对齐 Android FAV_CAT_LOCAL)
                        vm.addLocalFavorite(gallery: gallery)
                    } else {
                        Task { await vm.addFavorite(gid: gallery.gid, token: gallery.token, slot: slot) }
                    }
                },
                onCancel: { showFavoritePicker = false }
            )
            .presentationDetents([.medium])
        }
    }

    private func actionButton(icon: String, title: String, action: @escaping () -> Void, longPressAction: (() -> Void)? = nil) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                Text(title)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if os(iOS)
        .hoverEffect(.highlight)
        #endif
        // 对齐 Android: 长按手势支持 (收藏按钮长按弹出选择器)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in longPressAction?() }
        )
    }

    private var hasReadingProgress: Bool {
        let key = "reading_progress_\(gallery.gid)"
        return UserDefaults.standard.object(forKey: key) != nil
    }

    // MARK: - Tags

    private var tagSection: some View {
        let showTranslations = AppSettings.shared.showTagTranslations
        let tagDb = EhTagDatabase.shared

        return VStack(alignment: .leading, spacing: 8) {
            Text("标签")
                .font(.headline)
                .padding(.horizontal)
                .padding(.top, 12)

            ForEach(vm.tags, id: \.groupName) { group in
                HStack(alignment: .top, spacing: 8) {
                    // 翻译 namespace (对齐 Android: ehTags.getTranslation("n:" + groupName))
                    // 注意：Android使用 "n:" 前缀表示rows命名空间的翻译
                    let nsKey = "rows:\(group.groupName)"
                    let nsTranslation = showTranslations ? tagDb.getTranslation(nsKey) : nil
                    Text(nsTranslation ?? group.groupName)
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .trailing)

                    FlowLayout(spacing: 4) {
                        ForEach(group.tags, id: \.self) { tag in
                            // 翻译 tag (对齐 Android: ehTags.getTranslation(namespace:tag))
                            let fullTag = "\(group.groupName):\(tag)"
                            let tagTranslation = showTranslations ? tagDb.getTranslation(fullTag) : nil
                            // 对齐 Android: onTagClick → 推入新画廊列表到左侧导航栈
                            tagButton(label: tagTranslation ?? tag, fullTag: fullTag)
                        }
                    }
                }
                .padding(.horizontal)
            }
            
            // 调试信息：提示用户下载标签数据库
            if showTranslations && !tagDb.isLoaded {
                Text("请在设置中更新标签翻译数据库")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
            }
        }
        .padding(.bottom, 12)
    }

    /// 标签按钮 — Split/三栏布局: 推入左侧导航栈; iPhone compact: NavigationLink 推入当前栈
    @ViewBuilder
    private func tagButton(label: String, fullTag: String) -> some View {
        if let tagNav = tagNavigationAction {
            // iPad/macOS Split 布局: 用 Button 推入左侧 content/sidebar 列的 NavigationStack
            Button {
                tagNav.navigate(fullTag)
            } label: {
                tagLabel(label)
            }
            .buttonStyle(.plain)
        } else {
            // iPhone compact: NavigationLink 推入同一 NavigationStack
            NavigationLink {
                GalleryListView(mode: .tag(keyword: fullTag), isPushed: true)
            } label: {
                tagLabel(label)
            }
            .buttonStyle(.plain)
        }
    }

    private func tagLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color(.tertiarySystemFill))
            .clipShape(Capsule())
    }

    // MARK: - Previews (对齐 Android: 使用网格布局显示预览)

    private func previewSection(_ previewSet: PreviewSet) -> some View {
        // 预览图尺寸 (对齐 Android gallery_grid_column_width_middle = 120dp, aspect=0.667)
        let previewWidth: CGFloat = 100
        let previewHeight: CGFloat = 142  // 100 / 0.667 ≈ 150, 稍小一点
        let columns = [GridItem(.adaptive(minimum: previewWidth, maximum: previewWidth + 20), spacing: 8)]
        
        return VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Text("预览")
                    .font(.headline)
                Spacer()
                // 查看全部预览按钮
                if vm.previewPages > 1 {
                    NavigationLink {
                        GalleryPreviewsView(
                            gid: gallery.gid,
                            token: gallery.token,
                            totalPages: vm.previewPages,
                            galleryPages: vm.detail?.info.pages ?? gallery.pages,
                            initialPreviewSet: previewSet
                        )
                    } label: {
                        Text("查看全部 (\(vm.detail?.info.pages ?? gallery.pages)张)")
                            .font(.subheadline)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)

            // 网格布局预览 (对齐 Android: AutoGridLayoutManager 网格布局)
            LazyVGrid(columns: columns, spacing: 12) {
                switch previewSet {
                case .large(let items):
                    ForEach(items.sorted(by: { $0.position < $1.position }), id: \.position) { preview in
                        VStack(spacing: 4) {
                            CachedAsyncImage(url: URL(string: preview.imageUrl)) { img in
                                img.resizable().aspectRatio(contentMode: .fill)
                            } placeholder: {
                                Color(.tertiarySystemFill)
                                    .overlay { ProgressView() }
                            }
                            .frame(width: previewWidth, height: previewHeight)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .onTapGesture {
                                // 对齐 Android: intent.putExtra(GalleryActivity.KEY_PAGE, index)
                                vm.readerInitialPage = preview.position
                                vm.startReading = true
                            }
                            
                            // 页码标签 (对齐 Android: position + 1)
                            Text("\(preview.position + 1)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                case .normal(let items):
                    ForEach(items.sorted(by: { $0.position < $1.position }), id: \.position) { preview in
                        VStack(spacing: 4) {
                            SpritePreviewView(preview: preview)
                                .frame(width: previewWidth, height: previewHeight)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .onTapGesture {
                                    // 对齐 Android: intent.putExtra(GalleryActivity.KEY_PAGE, index)
                                    vm.readerInitialPage = preview.position
                                    vm.startReading = true
                                }
                            
                            // 页码标签
                            Text("\(preview.position + 1)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal)
        }
        .padding(.bottom, 12)
    }

    // MARK: - Comments (对齐 Android: 默认显示前2条评论，每条最多5行)

    private var commentSection: some View {
        let maxShowCount = 2 // Android: maxShowCount = 2
        let displayComments = Array(vm.comments.prefix(maxShowCount))
        let hasMore = vm.comments.count > maxShowCount || vm.hasMoreComments
        
        return VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Text("评论")
                    .font(.headline)
                Spacer()
                // 超过2条时显示"更多评论"
                if hasMore {
                    NavigationLink {
                        GalleryCommentsView(
                            gid: gallery.gid,
                            token: gallery.token,
                            apiUid: vm.detail?.apiUid ?? -1,
                            apiKey: vm.detail?.apiKey ?? "",
                            initialComments: vm.comments,
                            hasMore: vm.hasMoreComments
                        )
                    } label: {
                        Text("更多评论")
                            .font(.subheadline)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)

            if displayComments.isEmpty {
                Text("暂无评论")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                ForEach(Array(displayComments.enumerated()), id: \.offset) { idx, comment in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(comment.user)
                                .font(.subheadline.bold())
                            Spacer()
                            Text(comment.time, style: .date)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if comment.score != 0 {
                                Text(comment.score > 0 ? "+\(comment.score)" : "\(comment.score)")
                                    .font(.caption2)
                                    .foregroundStyle(comment.score > 0 ? .green : .red)
                            }
                        }
                        // 评论内容是 HTML，简单显示纯文本，限制5行
                        Text(comment.comment.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(5) // Android: setMaxLines(5)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                    if idx < displayComments.count - 1 {
                        Divider().padding(.leading)
                    }
                }
            }
        }
        .padding(.bottom, 16)
    }

    // MARK: - Error

    private func errorSection(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .foregroundStyle(.secondary)
            Button("重试") {
                Task { await vm.loadDetail(gid: gallery.gid, token: gallery.token) }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Helpers

    private func ratingIcon(index: Int, rating: Float) -> String {
        let fill = rating - Float(index)
        if fill >= 1.0 { return "star.fill" }
        if fill >= 0.5 { return "star.leadinghalf.filled" }
        return "star"
    }
}

// MARK: - ViewModel

@MainActor
@Observable
class GalleryDetailViewModel {
    var isLoading = false
    var errorMessage: String?
    var detail: GalleryDetail?
    var isFavorited = false
    var downloadState: Int = -1 // DownloadManager.stateInvalid
    var startReading = false
    var readerInitialPage: Int? = nil  // 对齐 Android GalleryActivity.KEY_PAGE
    var displayRating: Float?
    var isLoadingComments = false

    // 从 GalleryDetail 导出的便捷属性
    var tags: [GalleryTagGroup] { detail?.tags ?? [] }
    var previewSet: PreviewSet? { detail?.previewSet }
    var previewPages: Int { detail?.previewPages ?? 0 }
    var comments: [GalleryComment] { detail?.comments.comments ?? [] }
    var hasMoreComments: Bool { detail?.comments.hasMore ?? false }
    var totalCommentsText: String {
        let count = comments.count
        if hasMoreComments {
            return "\(count)+"
        }
        return "\(count)"
    }
    var language: String? { detail?.language }
    var size: String? { detail?.size }
    var canRate: Bool { detail?.apiUid ?? -1 > 0 && !(detail?.apiKey.isEmpty ?? true) }

    func loadDetail(gid: Int64, token: String) async {
        guard !isLoading else { return }

        // 1) 先查内存缓存 (对标 Android: EhApplication.getGalleryDetailCache().get(gid))
        if let cached = GalleryCache.shared.getDetail(gid: gid) {
            // 查询下载状态 (对齐 Android: DownloadManager 状态查询)
            let dlState = await DownloadManager.shared.getTaskState(gid: gid)
            await MainActor.run {
                self.detail = cached
                self.isFavorited = cached.isFavorited
                self.displayRating = cached.info.rating
                self.downloadState = dlState
                self.isLoading = false
            }
            // DEBUG: Print cached data
            print("[DEBUG] Loaded from cache - Comments: \(cached.comments.comments.count), HasMore: \(cached.comments.hasMore)")
            print("[DEBUG] PreviewSet: \(String(describing: cached.previewSet))")
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            let site = GalleryActionService.siteBaseURL
            let urlStr = "\(site)g/\(gid)/\(token)/"
            print("[DEBUG] Fetching detail from: \(urlStr)")
            let result = try await EhAPI.shared.getGalleryDetail(url: urlStr)

            // DEBUG: Print parsed data
            print("[DEBUG] Parsed - Comments: \(result.comments.comments.count), HasMore: \(result.comments.hasMore)")
            print("[DEBUG] PreviewSet: \(String(describing: result.previewSet))")

            // 2) 存入缓存 (对标 Android: EhApplication.getGalleryDetailCache().put(result.gid, result))
            GalleryCache.shared.putDetail(result)

            // 查询下载状态
            let dlState = await DownloadManager.shared.getTaskState(gid: gid)

            await MainActor.run {
                self.detail = result
                self.isFavorited = result.isFavorited
                self.displayRating = result.info.rating
                self.downloadState = dlState
                self.isLoading = false
            }

            // 3) 自动记录浏览历史 (对齐 Android GalleryDetailScene.onGetGalleryDetailSuccess)
            recordHistory(info: result.info)
        } catch {
            print("[DEBUG] Error loading detail: \(error)")
            await MainActor.run {
                self.errorMessage = EhError.localizedMessage(for: error)
                self.isLoading = false
            }
        }
    }

    func addFavorite(gid: Int64, token: String, slot: Int) async {
        await GalleryActionService.shared.addFavorite(gid: gid, token: token, slot: slot)
        await MainActor.run { self.isFavorited = true }
    }

    /// 添加到本地收藏 (对齐 Android FAV_CAT_LOCAL = -1, EhDB.putLocalFavorite)
    func addLocalFavorite(gallery: GalleryInfo) {
        GalleryActionService.shared.addLocalFavorite(gallery: gallery)
        self.isFavorited = true
    }

    func removeFavorite(gid: Int64, token: String) async {
        await GalleryActionService.shared.removeFavorite(gid: gid, token: token)
        await MainActor.run { self.isFavorited = false }
    }

    /// 自动记录浏览历史 (对齐 Android EhDB.putHistoryInfo)
    private func recordHistory(info: GalleryInfo) {
        var record = HistoryRecord(
            gid: info.gid, token: info.token,
            title: info.bestTitle, category: info.category.rawValue,
            pages: info.pages, mode: 0, date: Date()
        )
        record.titleJpn = info.titleJpn
        record.thumb = info.thumb
        record.posted = info.posted
        record.uploader = info.uploader
        record.rating = info.rating
        do {
            try EhDatabase.shared.insertHistory(record)
            // 限制历史记录数量 (对齐 Android Settings.getHistoryInfoSize())
            try EhDatabase.shared.trimHistory(maxCount: AppSettings.shared.historyInfoSize)
        } catch {
            print("Failed to record history: \(error)")
        }
    }

    func startDownload(gallery: GalleryInfo) async {
        await GalleryActionService.shared.startDownload(gallery: gallery)
        let state = await DownloadManager.shared.getTaskState(gid: gallery.gid)
        await MainActor.run { self.downloadState = state }
    }

    /// 根据 downloadState 返回按钮图标 (对齐 Android 下载状态)
    var downloadIcon: String {
        switch downloadState {
        case DownloadManager.stateDownload, DownloadManager.stateWait:
            return "arrow.down.circle.fill"
        case DownloadManager.stateFinish:
            return "checkmark.circle.fill"
        case DownloadManager.stateFailed:
            return "exclamationmark.circle"
        default:
            return "arrow.down.circle"
        }
    }

    /// 根据 downloadState 返回按钮标题
    var downloadTitle: String {
        switch downloadState {
        case DownloadManager.stateDownload:
            return "下载中"
        case DownloadManager.stateWait:
            return "等待中"
        case DownloadManager.stateFinish:
            return "已下载"
        case DownloadManager.stateFailed:
            return "失败"
        default:
            return "下载"
        }
    }

    func rateGallery(gid: Int64, token: String, rating: Float) async {
        guard let detail = detail, detail.apiUid > 0, !detail.apiKey.isEmpty else { return }

        do {
            let result = try await EhAPI.shared.rateGallery(
                apiUid: detail.apiUid,
                apiKey: detail.apiKey,
                gid: gid,
                token: token,
                rating: rating
            )
            await MainActor.run {
                // 如果返回有效评分则使用，否则使用用户选择的评分
                self.displayRating = result.rating > 0 ? Float(result.rating) : rating
            }
        } catch {
            print("Rate gallery failed: \(error)")
        }
    }

    /// 加载全部评论 (带 ?hc=1 参数获取所有评论)
    func loadAllComments(gid: Int64, token: String) async {
        guard !isLoadingComments else { return }

        await MainActor.run { isLoadingComments = true }

        do {
            let site = GalleryActionService.siteBaseURL
            // 添加 hc=1 参数来获取全部评论
            let urlStr = "\(site)g/\(gid)/\(token)/?hc=1"
            let result = try await EhAPI.shared.getGalleryDetail(url: urlStr)

            // 更新详情（主要是评论列表）
            await MainActor.run {
                // 保留原有详情，只更新评论部分
                if var currentDetail = self.detail {
                    currentDetail.comments = result.comments
                    self.detail = currentDetail
                    // 更新缓存
                    GalleryCache.shared.putDetail(currentDetail)
                }
                self.isLoadingComments = false
            }
        } catch {
            await MainActor.run {
                self.isLoadingComments = false
            }
            print("Load all comments failed: \(error)")
        }
    }


}

// MARK: - FlowLayout (Tags)

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(in: proposal.width ?? 300, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(in: bounds.width, subviews: subviews)
        for (index, offset) in result.offsets.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + offset.x, y: bounds.minY + offset.y), proposal: .unspecified)
        }
    }

    private func layout(in width: CGFloat, subviews: Subviews) -> (offsets: [CGPoint], size: CGSize) {
        var offsets: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            offsets.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxWidth = max(maxWidth, x)
        }

        return (offsets, CGSize(width: maxWidth, height: y + rowHeight))
    }
}

// MARK: - RatingSheet

struct RatingSheet: View {
    let currentRating: Float
    let onRate: (Float) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedRating: Float = 2.5

    var body: some View {
        VStack(spacing: 20) {
            Text("评分")
                .font(.headline)

            HStack(spacing: 8) {
                ForEach(0..<5) { i in
                    Image(systemName: starIcon(index: i))
                        .font(.title)
                        .foregroundStyle(.orange)
                        .onTapGesture {
                            selectedRating = Float(i) + 1.0
                        }
                }
            }

            Text(String(format: "%.1f", selectedRating))
                .font(.title2.bold())
                .monospacedDigit()

            HStack(spacing: 16) {
                Button("取消") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button("确定") {
                    onRate(selectedRating)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .onAppear {
            selectedRating = max(0.5, currentRating)
        }
    }

    private func starIcon(index: Int) -> String {
        let fill = selectedRating - Float(index)
        if fill >= 1.0 { return "star.fill" }
        if fill >= 0.5 { return "star.leadinghalf.filled" }
        return "star"
    }
}

// MARK: - 精灵图预览视图

/// 处理精灵图（sprite sheet）预览的视图
/// 多个预览图片共用一张大图，通过 offsetX 裁剪显示不同部分
struct SpritePreviewView: View {
    let preview: NormalPreview
    @State private var spriteImage: PlatformImage?
    
    var body: some View {
        Group {
            if let spriteImage = spriteImage {
                // 从精灵图中裁剪出对应的部分
                if let croppedImage = cropSprite(from: spriteImage) {
                    #if os(iOS)
                    Image(uiImage: croppedImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                    #else
                    Image(nsImage: croppedImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                    #endif
                } else {
                    placeholderView
                }
            } else {
                placeholderView
                    .onAppear {
                        loadSpriteImage()
                    }
            }
        }
    }
    
    private var placeholderView: some View {
        Color(.tertiarySystemFill)
            .overlay {
                ProgressView()
            }
    }
    
    private func loadSpriteImage() {
        guard let url = URL(string: preview.imageUrl) else { return }
        
        // 检查缓存
        var request = URLRequest(url: url)
        request.timeoutInterval = 30  // 增加超时时间
        if let cachedResponse = URLCache.shared.cachedResponse(for: request),
           let image = PlatformImage(data: cachedResponse.data) {
            self.spriteImage = image
            return
        }
        
        // 下载图片
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                // 缓存响应
                let cachedResponse = CachedURLResponse(response: response, data: data)
                URLCache.shared.storeCachedResponse(cachedResponse, for: request)
                
                if let image = PlatformImage(data: data) {
                    await MainActor.run {
                        self.spriteImage = image
                    }
                }
            } catch {
                print("Failed to load sprite image: \(error)")
            }
        }
    }
    
    /// 从精灵图中裁剪出对应的预览部分
    private func cropSprite(from image: PlatformImage) -> PlatformImage? {
        #if os(iOS)
        let scale = image.scale
        let cropRect = CGRect(
            x: CGFloat(preview.offsetX) * scale,
            y: CGFloat(preview.offsetY) * scale,
            width: CGFloat(preview.clipWidth) * scale,
            height: CGFloat(preview.clipHeight) * scale
        )
        guard let cgImage = image.cgImage,
              let croppedCGImage = cgImage.cropping(to: cropRect) else {
            return nil
        }
        return UIImage(cgImage: croppedCGImage, scale: scale, orientation: image.imageOrientation)
        #else
        // macOS: NSImage 没有 scale 属性，直接使用像素坐标
        let cropRect = CGRect(
            x: CGFloat(preview.offsetX),
            y: CGFloat(preview.offsetY),
            width: CGFloat(preview.clipWidth),
            height: CGFloat(preview.clipHeight)
        )
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let croppedCGImage = cgImage.cropping(to: cropRect) else {
            return nil
        }
        return NSImage(cgImage: croppedCGImage, size: NSSize(width: preview.clipWidth, height: preview.clipHeight))
        #endif
    }
}

// MARK: - FavoriteSlotPicker (对齐 Android FavoritesActivity 收藏夹选择器)

struct FavoriteSlotPicker: View {
    let onSelect: (Int) -> Void
    let onCancel: () -> Void
    /// 是否显示本地收藏选项 (对齐 Android: slot -1 = 本地收藏)
    var showLocalOption: Bool = true

    var body: some View {
        NavigationStack {
            List {
                // 本地收藏 (对齐 Android FAV_CAT_LOCAL = -1)
                if showLocalOption {
                    Button {
                        onSelect(-1)
                    } label: {
                        HStack {
                            Image(systemName: "internaldrive")
                                .foregroundStyle(.secondary)
                            Text("本地收藏")
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                    }
                }

                // 云端收藏 0-9 (对齐 Android favCatArray)
                ForEach(0..<10) { slot in
                    Button {
                        onSelect(slot)
                    } label: {
                        HStack {
                            Image(systemName: "heart.fill")
                                .foregroundStyle(favSlotColor(slot))
                            Text(AppSettings.shared.favCatName(slot))
                                .foregroundStyle(.primary)
                            Spacer()
                            let count = AppSettings.shared.favCount(slot)
                            if count > 0 {
                                Text("\(count)")
                                    .foregroundStyle(.secondary)
                                    .font(.subheadline)
                            }
                        }
                    }
                }
            }
            .navigationTitle("选择收藏夹")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onCancel() }
                }
            }
        }
    }

    static func favSlotColor(_ slot: Int) -> Color {
        let colors: [Color] = [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .brown, .gray]
        return slot >= 0 && slot < colors.count ? colors[slot] : .secondary
    }

    private func favSlotColor(_ slot: Int) -> Color {
        Self.favSlotColor(slot)
    }
}
