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
    @State private var showArchive = false
    /// 归档与种子合并后的资源入口 sheet
    @State private var showResourceSheet = false
    @State private var showTorrents = false
    @State private var showCellularWarning = false

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
                    // iPhone 上返回按钮是浮在内容之上的 overlay（导航栏被隐藏了），
                    // 不让开就正好压在封面左上角：按钮本身 33pt 高，加上 4pt 顶距。
                    .padding(.top, backButtonClearance)
                Divider()
                actionBar
                    .padding(.vertical, 10)
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
        // 详情是沉浸式页面：底部浮条会盖住预览网格，且这一屏没有平级切换的需要
        .ehHidesTabBar()
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
        .overlay(alignment: .topTrailing) {
            // 详情页此前没有任何菜单入口：导航栏在 iPhone 上是隐藏的，
            // 只留了个返回按钮，于是 Android 菜单里的「刷新」和
            // 「用其他应用打开」在这边一个都没有。
            if horizontalSizeClass == .compact {
                detailMenu
                    .padding(.top, 4)
                    .padding(.trailing, 12)
            }
        }
        .enableEdgeSwipeBack()
        #endif
        #if os(iOS)
        .fullScreenCover(item: $vm.readerLaunchItem) { item in
            // 全屏呈现阅读器，完全隐藏导航栏
            // item: 绑定保证每次打开都创建全新 ImageReaderView + ReaderViewModel
            ImageReaderView(
                gid: item.gid,
                token: item.token,
                pages: item.pages,
                previewSet: item.previewSet,
                initialPage: item.initialPage
            )
        }
        #else
        .navigationDestination(isPresented: Binding(
            get: { vm.readerLaunchItem != nil },
            set: { if !$0 { vm.readerLaunchItem = nil } }
        )) {
            // macOS: 在导航栈中推入阅读器，支持窗口自由调整大小
            if let item = vm.readerLaunchItem {
                ImageReaderView(
                    gid: item.gid,
                    token: item.token,
                    pages: item.pages,
                    previewSet: item.previewSet,
                    initialPage: item.initialPage
                )
                .id(item.id) // 保证每次 launch 创建新视图
            }
        }
        #endif
        .task(id: gallery.gid) {
            // 画廊 ID 变更时重置 VM 状态并重新加载 (修复 SwiftUI 视图复用 bug)
            vm.reset()
            await vm.loadDetail(gid: gallery.gid, token: gallery.token)
        }
        // Fix F3-2: 每次详情页出现时重新查询下载状态 (解决导航栈返回时状态不同步)
        .onAppear {
            Task {
                let dlState = await DownloadManager.shared.getTaskState(gid: gallery.gid)
                vm.downloadState = dlState
            }
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
        .confirmationDialog(
            "当前是移动网络",
            isPresented: $showCellularWarning,
            titleVisibility: .visible
        ) {
            Button("仍然下载") {
                Haptics.impact()
                Task { await vm.startDownload(gallery: gallery) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这本共 \(vm.detail?.info.pages ?? gallery.pages) 页，下载会消耗蜂窝数据。可以在设置里关掉这个提醒。")
        }
        .sheet(isPresented: $showResourceSheet) { resourceSheet }
        .sheet(isPresented: $showArchive) {
            if let archiveUrl = vm.detail?.archiveUrl, !archiveUrl.isEmpty {
                ArchiveDownloadView(gid: gallery.gid, token: gallery.token, archiveUrl: archiveUrl)
            }
        }
        .sheet(isPresented: $showTorrents) {
            if let torrentUrl = vm.detail?.torrentUrl, !torrentUrl.isEmpty {
                TorrentListView(gid: gallery.gid, token: gallery.token, torrentUrl: torrentUrl)
            }
        }
    }

    /// 详情页菜单（对齐 Android scene_gallery_detail.xml）
    private var detailMenu: some View {
        Menu {
            Button {
                Task { await vm.loadDetail(gid: gallery.gid, token: gallery.token) }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }

            Button {
                GalleryActionService.shared.copyLink(gid: gallery.gid, token: gallery.token)
            } label: {
                Label("复制链接", systemImage: "doc.on.doc")
            }

            // 用浏览器打开：Cookie 失效、遇到验证码、或者想看网页版的
            // 某些内容时，这是唯一的出路
            Button {
                let url = GalleryActionService.shared.galleryURL(
                    gid: gallery.gid, token: gallery.token)
                #if os(iOS)
                if let u = URL(string: url) { UIApplication.shared.open(u) }
                #else
                if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                #endif
            } label: {
                Label("在浏览器中打开", systemImage: "safari")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(8)
                .background(.black.opacity(0.5))
                .clipShape(Circle())
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 14) {
            EhCoverThumbnail(
                url: gallery.thumb,
                size: coverSize,
                category: gallery.category,
                cornerRadius: 8
            )

            VStack(alignment: .leading, spacing: 5) {
                // 分类只在封面角标上出现一次。
                //
                // 这里原本还有一行分类名小字，注释写的是「封面带的是分类色条，
                // 所以文字不重复」——但对齐 Android 那一版之后 EhCoverThumbnail
                // 画的已经是分类角标（右上角那块 Western），文字于是成了
                // 同一个词并排出现两遍。
                Text(gallery.suitableTitle(preferJpn: AppSettings.shared.showJpnTitle))
                    .font(EhFont.title)
                    .foregroundStyle(EhColor.label)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)

                if let uploader = gallery.uploader, !uploader.isEmpty {
                    Text(uploader + (gallery.posted.map { " · " + $0 } ?? ""))
                        .font(EhFont.meta)
                        .foregroundStyle(EhColor.secondaryLabel)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                // 评分放大成主要信息：这是详情页最常被扫的一个数字
                Button {
                    if vm.canRate { showRatingSheet = true }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(String(format: "%.2f", vm.displayRating ?? gallery.rating))
                            .font(EhFont.rating)
                            .foregroundStyle(EhColor.accent)
                        Text(ratingSuffix)
                            .font(EhFont.meta)
                            .foregroundStyle(EhColor.tertiaryLabel)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!vm.canRate)

                HStack(spacing: EhSpacing.row) {
                    Text("\(gallery.pages) 页")
                    if let size = vm.size { Text(size) }
                    if let lang = vm.language { Text(lang) }
                }
                .font(EhFont.mono(12))
                .foregroundStyle(EhColor.secondaryLabel)
            }
        }
        .padding(EhSpacing.page)
    }

    private var ratingSuffix: String {
        if let count = vm.detail?.ratingCount, count > 0 {
            return "/ 5 · \(count) 评分"
        }
        return "/ 5"
    }

    /// 详情页封面尺寸 (对齐 Android Settings.KEY_DETAIL_SIZE)
    /// 浮起返回按钮占掉的高度。iPhone 才有（iPad/Mac 用系统导航栏）。
    private var backButtonClearance: CGFloat {
        #if os(iOS)
        // 17pt 图标 + 上下各 8pt 内边距 = 33pt，再加 overlay 自己的 4pt 顶距
        horizontalSizeClass == .compact ? 41 : 0
        #else
        0
        #endif
    }

    private var coverSize: CGSize {
        AppSettings.shared.detailSize == 1
            ? CGSize(width: 160, height: 224)
            : CGSize(width: 120, height: 168)
    }

    // MARK: - 资源入口 (归档 / 种子)

    /// 归档与种子放主操作栏下面单独一行 —— 它们不是每本都有，
    /// 塞进上面那排会让四个常用操作被挤窄
    @ViewBuilder
    private var resourceSheet: some View {
        let torrentCount = vm.detail?.torrentCount ?? 0
        let hasArchive = !(vm.detail?.archiveUrl ?? "").isEmpty
        let hasTorrent = !(vm.detail?.torrentUrl ?? "").isEmpty && torrentCount > 0

        return NavigationStack {
            VStack(alignment: .leading, spacing: EhSpacing.section) {
                if hasTorrent {
                    resourceEntry(
                        symbol: "arrow.down.doc",
                        title: "种子",
                        subtitle: "\(torrentCount) 个 · 不消耗配额",
                        tint: EhColor.success
                    ) {
                        showResourceSheet = false
                        showTorrents = true
                    }
                }
                if hasArchive {
                    resourceEntry(
                        symbol: "archivebox",
                        title: "归档 / H@H",
                        subtitle: "消耗图片配额",
                        tint: EhColor.warning
                    ) {
                        showResourceSheet = false
                        showArchive = true
                    }
                }

                Text("种子由其他用户做种，不消耗你的图片配额，但可用性取决于是否有人在线；归档与 H@H 派发由官方提供，稳定但会按图片数量扣除配额。")
                    .font(EhFont.caption)
                    .foregroundStyle(EhColor.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(EhSpacing.page)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(EhColor.sheetBackground)
            .navigationTitle("资源下载")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showResourceSheet = false }
                }
            }
        }
        .presentationDetents([.height(320)])
        .presentationCornerRadius(EhRadius.sheet)
    }

    private func resourceEntry(
        symbol: String, title: String, subtitle: String, tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: EhSpacing.row) {
                Image(systemName: symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(tint)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(EhFont.body).foregroundStyle(EhColor.label)
                    Text(subtitle).font(EhFont.meta).foregroundStyle(EhColor.secondaryLabel)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(EhColor.tertiaryLabel)
            }
            .padding(EhSpacing.page)
            .ehCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Action Bar

    private var readButtonTitle: String {
        guard vm.hasReadingProgress else { return "阅读" }
        // 与列表行读同一个键：存的是 0-based 页索引，展示时 +1
        let index = UserDefaults.standard.integer(forKey: "reading_progress_\(gallery.gid)")
        guard index > 0 else { return "继续阅读" }
        return "继续读 · \(index + 1) 页"
    }

    private var hasAnyResource: Bool {
        let hasArchive = !(vm.detail?.archiveUrl ?? "").isEmpty
        let hasTorrent = !(vm.detail?.torrentUrl ?? "").isEmpty && (vm.detail?.torrentCount ?? 0) > 0
        return hasArchive || hasTorrent
    }

    private var actionBar: some View {
        // 四等分的操作栏里，四个动作在视觉上完全等重，但「阅读」的使用频率
        // 远高于其余三个。改成一个占主导的主按钮加三个方钮，主次一眼可辨。
        HStack(spacing: 10) {
            Button {
                Haptics.tap()
                // 对齐 Android: 阅读按钮不传 KEY_PAGE，让阅读器自行恢复进度
                vm.readerLaunchItem = ReaderLaunchItem(
                    gid: gallery.gid,
                    token: gallery.token,
                    pages: vm.detail?.info.pages ?? gallery.pages,
                    previewSet: vm.detail?.previewSet,
                    initialPage: nil
                )
            } label: {
                Label(readButtonTitle, systemImage: "book")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(EhFilledButtonStyle(height: EhSize.actionButtonHeight))
            .layoutPriority(1)

            EhSquareIconButton(
                symbol: vm.isFavorited ? "heart.fill" : "heart",
                tint: vm.isFavorited ? EhColor.danger : EhColor.label
            ) {
                Haptics.impact()
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
            }
            // 对齐 Android: 长按收藏始终弹出收藏夹选择，即使已设默认
            .onLongPressGesture { showFavoritePicker = true }

            EhSquareIconButton(symbol: vm.downloadIcon) {
                if vm.downloadState == DownloadManager.stateFinish {
                    Haptics.tap()
                    vm.readerLaunchItem = ReaderLaunchItem(
                        gid: gallery.gid,
                        token: gallery.token,
                        pages: vm.detail?.info.pages ?? gallery.pages,
                        previewSet: vm.detail?.previewSet,
                        initialPage: nil
                    )
                } else if GalleryActionService.shared.shouldWarnAboutCellular {
                    // 移动网络下先问一句，整本下载很容易吃掉几百 MB
                    showCellularWarning = true
                } else {
                    Haptics.impact()
                    Task { await vm.startDownload(gallery: gallery) }
                }
            }

            // 归档与种子并进一个「资源下载」sheet：两者都不是每本都有，
            // 各占一个入口会让常用操作被挤窄，而它们的选择又需要成本对比
            if hasAnyResource {
                EhSquareIconButton(symbol: "archivebox") {
                    Haptics.tap()
                    showResourceSheet = true
                }
            }
        }
        .padding(.horizontal, EhSpacing.page)
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
        Group {
            if let tagNav = tagNavigationAction {
                // iPad/macOS Split 布局: 用 Button 推入左侧 content/sidebar 列的 NavigationStack
                Button {
                    tagNav.navigate(fullTag)
                } label: {
                    tagLabel(label)
                }
                .buttonStyle(.plain)
            } else {
                // iPhone compact: value-based NavigationLink 推入同一 NavigationStack
                // ★ 必须使用 value-based 而非 destination-based，避免与 galleryList 的
                //   NavigationLink(value: GalleryInfo) 混用导致路径混乱
                NavigationLink(value: TagSearchDestination(tag: fullTag)) {
                    tagLabel(label)
                }
                .buttonStyle(.plain)
            }
        }
        // 短按搜索，长按给出「订阅 / 屏蔽」——这两件事此前只能到「我的」页
        // 分别进两个二级页手动填标签名，而用户产生这个念头的时刻就是在这里
        // 看到某个标签的时候。
        .contextMenu {
            Button {
                Task { await subscribeTag(fullTag) }
            } label: {
                Label("订阅这个标签", systemImage: "bell")
            }
            Button(role: .destructive) {
                blockTag(fullTag)
            } label: {
                Label("屏蔽这个标签", systemImage: "eye.slash")
            }
            Divider()
            Button {
                #if os(iOS)
                UIPasteboard.general.string = fullTag
                #else
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(fullTag, forType: .string)
                #endif
                EhToast.success("已复制标签")
            } label: {
                Label("复制标签", systemImage: "doc.on.doc")
            }
        }
    }

    /// 订阅标签（加入「我的标签」，出现在订阅列表里）
    private func subscribeTag(_ fullTag: String) async {
        let name = MyTagsView.plainTagName(from: fullTag)
        guard !name.isEmpty else { return }
        do {
            var tag = UserTag()
            tag.tagName = name
            tag.watched = true
            _ = try await EhAPI.shared.addTag(
                url: EhURL.myTagsUrl(for: AppSettings.shared.gallerySite), tag: tag
            )
            EhToast.success("已订阅「\(name)」")
        } catch {
            // 只发触感 + print 等于没反馈：离线时用户完全不知道订阅没成
            EhToast.failure("订阅标签失败")
            debugLog("[GalleryDetail] 订阅标签失败: \(error)")
        }
    }

    /// 屏蔽标签（写入本地过滤器，列表里带此标签的画廊会被挡掉）
    private func blockTag(_ fullTag: String) {
        let name = MyTagsView.plainTagName(from: fullTag)
        guard !name.isEmpty else { return }
        do {
            try EhDatabase.shared.insertFilter(
                FilterRecord(mode: 2, text: name, enable: true)
            )
            EhToast.success("已屏蔽「\(name)」")
        } catch {
            EhToast.failure("屏蔽标签失败")
            debugLog("[GalleryDetail] 屏蔽标签失败: \(error)")
        }
    }

    /// 标签 chip。形状与配色跟列表行里的 EhGalleryRow.tagChip 保持一致：
    /// 同一个东西（标签）此前在详情页是胶囊 + tertiarySystemFill、
    /// 在列表行是 4pt 圆角 + EhColor.fill，看着像两种控件。
    private func tagLabel(_ text: String) -> some View {
        Text(text)
            .font(EhFont.caption)
            .foregroundStyle(EhColor.label)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(EhColor.fill)
            }
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
                                vm.readerLaunchItem = ReaderLaunchItem(
                                    gid: gallery.gid,
                                    token: gallery.token,
                                    pages: vm.detail?.info.pages ?? gallery.pages,
                                    previewSet: vm.detail?.previewSet,
                                    initialPage: preview.position
                                )
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
                                    vm.readerLaunchItem = ReaderLaunchItem(
                                        gid: gallery.gid,
                                        token: gallery.token,
                                        pages: vm.detail?.info.pages ?? gallery.pages,
                                        previewSet: vm.detail?.previewSet,
                                        initialPage: preview.position
                                    )
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

            // ★ 底部额外的「查看全部」按钮 — 方便用户滚动到底部后直接点击
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
                    Text("查看全部预览 (\(vm.detail?.info.pages ?? gallery.pages)张)")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(.tertiarySystemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .padding(.horizontal)
            }
        }
        .padding(.bottom, 12)
    }

    // MARK: - Comments (对齐 Android: 默认显示前2条评论，每条最多5行)

    private var commentSection: some View {
        let maxShowCount = 2 // Android: maxShowCount = 2
        let displayComments = Array(vm.processedComments.prefix(maxShowCount))
        let hasMore = vm.processedComments.count > maxShowCount || vm.hasMoreComments
        
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
                ForEach(displayComments) { comment in
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
                        // Perf P0-4: 使用预处理的纯文本，避免 body 内正则计算
                        Text(comment.strippedBody)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(5) // Android: setMaxLines(5)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(.bottom, 16)
    }

    // MARK: - Error

    /// 失败态与所有列表页共用 EhStateView。此前详情页是自己画的一套
    /// （largeTitle 图标 + .bordered 按钮），和列表页的失败界面长得不一样。
    private func errorSection(_ message: String) -> some View {
        EhStateView(
            kind: .error(title: "加载失败", message: message),
            primaryAction: ("重试", {
                Task { await vm.loadDetail(gid: gallery.gid, token: gallery.token) }
            })
        )
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
/// 阅读器启动参数 — 使用 item: 绑定确保每次打开阅读器都创建全新视图
struct ReaderLaunchItem: Identifiable {
    let id = UUID()  // 每次启动生成新 ID，保证 SwiftUI 创建新视图
    let gid: Int64
    let token: String
    let pages: Int
    let previewSet: PreviewSet?
    let initialPage: Int?
}

@MainActor @Observable
class GalleryDetailViewModel {
    var isLoading = false
    var errorMessage: String?
    var detail: GalleryDetail?
    var isFavorited = false
    var downloadState: Int = DownloadManager.stateInvalid
    /// 阅读器启动项 — 非 nil 时弹出阅读器 (item: 绑定确保视图完全重建)
    var readerLaunchItem: ReaderLaunchItem? = nil
    var displayRating: Float?
    var isLoadingComments = false
    /// Perf P0-5: 一次性读取阅读进度，避免 body 中读 UserDefaults
    var hasReadingProgress = false
    /// Perf P0-4: 预处理后的评论 (HTML 已剥离，避免 body 中执行 regex)
    var processedComments: [ProcessedComment] = []
    /// Fix F3-4: 下载状态轮询任务
    @ObservationIgnored
    var downloadPollingTask: Task<Void, Never>?

    // MARK: - Processed Comment (Perf P0-4)

    /// 预处理后的评论结构体 — 在 loadDetail 成功后后台计算
    struct ProcessedComment: Identifiable {
        let id: Int64
        let user: String
        let time: Date
        let score: Int
        let strippedBody: String  // HTML 已剥离的纯文本
    }

    /// 预编译正则 (避免每次调用都重新编译)
    private static let htmlTagRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "<[^>]+>", options: [])
    }()

    /// 从 HTML 中剥离标签 — 使用预编译正则
    private static func stripHTML(_ html: String) -> String {
        guard let regex = htmlTagRegex else {
            return html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        }
        let range = NSRange(html.startIndex..., in: html)
        return regex.stringByReplacingMatches(in: html, options: [], range: range, withTemplate: "")
    }

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

    deinit {
        downloadPollingTask?.cancel()
    }

    /// 重置所有状态，准备加载新画廊 (修复 SwiftUI 视图复用导致显示旧数据的问题)
    func reset() {
        downloadPollingTask?.cancel()
        downloadPollingTask = nil
        isLoading = false
        errorMessage = nil
        detail = nil
        isFavorited = false
        downloadState = DownloadManager.stateInvalid
        readerLaunchItem = nil
        displayRating = nil
        isLoadingComments = false
        hasReadingProgress = false
        processedComments = []
    }

    func loadDetail(gid: Int64, token: String) async {
        guard !isLoading else { return }

        // 1) 先查内存缓存 (对标 Android: EhApplication.getGalleryDetailCache().get(gid))
        if let cached = GalleryCache.shared.getDetail(gid: gid) {
            // 查询下载状态 (对齐 Android: DownloadManager 状态查询)
            let dlState = await DownloadManager.shared.getTaskState(gid: gid)
            self.detail = cached
            self.isFavorited = cached.isFavorited
            self.displayRating = cached.info.rating
            self.downloadState = dlState
            self.isLoading = false
            // Perf P0-4: 预处理评论 HTML
            preprocessComments(cached.comments.comments)
            // Perf P0-5: 一次性检查阅读进度
            checkReadingProgress(gid: gid)
            debugLog("Loaded from cache - Comments: \(cached.comments.comments.count), HasMore: \(cached.comments.hasMore)")
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            let site = GalleryActionService.siteBaseURL
            let urlStr = "\(site)g/\(gid)/\(token)/"
            debugLog("Fetching detail from: \(urlStr)")
            let result = try await EhAPI.shared.getGalleryDetail(url: urlStr)

            // 2) 存入缓存 (对标 Android: EhApplication.getGalleryDetailCache().put(result.gid, result))
            GalleryCache.shared.putDetail(result)

            // 3) 标签落库 —— 下载列表的"按标签搜索"靠这张表
            //    (对齐 Android: 详情加载后写 GalleryTagsDao)
            if !result.tags.isEmpty {
                try? EhDatabase.shared.saveGalleryTags(gid: gid, groups: result.tags)
            }

            // 查询下载状态
            let dlState = await DownloadManager.shared.getTaskState(gid: gid)
            // Fix B-2: 同时检查服务器收藏和本地收藏
            let hasLocalFav = (try? EhDatabase.shared.containsLocalFavorite(gid: gid)) ?? false

            self.detail = result
            self.isFavorited = result.isFavorited || hasLocalFav
            self.displayRating = result.info.rating
            self.downloadState = dlState
            self.isLoading = false

            // Perf P0-4: 预处理评论 HTML
            preprocessComments(result.comments.comments)
            // Perf P0-5: 一次性检查阅读进度
            checkReadingProgress(gid: gid)

            // Fix F3-4: 如果当前正在下载，启动轮询任务监听状态变化
            startDownloadPollingIfNeeded(gid: gid)
        } catch {
            debugLog("Error loading detail: \(error)")
            self.errorMessage = EhError.localizedMessage(for: error)
            self.isLoading = false
        }
    }

    /// Fix B-3: 乐观更新 + API 失败回滚
    func addFavorite(gid: Int64, token: String, slot: Int) async {
        self.isFavorited = true  // 乐观更新
        do {
            try await GalleryActionService.shared.addFavorite(gid: gid, token: token, slot: slot)
            Haptics.success()
        } catch {
            self.isFavorited = false  // 回滚
            self.errorMessage = "收藏失败: \(error.localizedDescription)"
        }
    }

    /// 添加到本地收藏 (对齐 Android FAV_CAT_LOCAL = -1, EhDB.putLocalFavorite)
    func addLocalFavorite(gallery: GalleryInfo) {
        GalleryActionService.shared.addLocalFavorite(gallery: gallery)
        self.isFavorited = true
    }

    /// Fix B-3: 乐观更新 + API 失败回滚
    func removeFavorite(gid: Int64, token: String) async {
        self.isFavorited = false  // 乐观更新
        do {
            try await GalleryActionService.shared.removeFavorite(gid: gid, token: token)
            Haptics.impact()
        } catch {
            self.isFavorited = true  // 回滚
            self.errorMessage = "取消收藏失败: \(error.localizedDescription)"
        }
    }

    // MARK: - Perf P0-4: 预处理评论 HTML

    /// 在 loadDetail 成功后调用 — 后台剥离 HTML 标签，View body 直接读取纯文本
    func preprocessComments(_ rawComments: [GalleryComment]) {
        processedComments = rawComments.map { comment in
            ProcessedComment(
                id: comment.id,
                user: comment.user,
                time: comment.time,
                score: comment.score,
                strippedBody: Self.stripHTML(comment.comment)
            )
        }
    }

    // MARK: - Perf P0-5: 一次性检查阅读进度

    /// 在 loadDetail 成功后调用 — 避免 body 每次重算时读 UserDefaults
    func checkReadingProgress(gid: Int64) {
        let key = "reading_progress_\(gid)"
        hasReadingProgress = UserDefaults.standard.object(forKey: key) != nil
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
        record.simpleTags = info.simpleTags
        record.simpleLanguage = info.simpleLanguage
        do {
            try EhDatabase.shared.insertHistory(record)
            // 限制历史记录数量 (对齐 Android Settings.getHistoryInfoSize())
            try EhDatabase.shared.trimHistory(maxCount: AppSettings.shared.historyInfoSize)
            NotificationCenter.default.post(name: .galleryHistoryChanged, object: nil)
        } catch {
            debugLog("Failed to record history: \(error)")
        }
    }

    func startDownload(gallery: GalleryInfo) async {
        await GalleryActionService.shared.startDownload(gallery: gallery)
        let state = await DownloadManager.shared.getTaskState(gid: gallery.gid)
        self.downloadState = state
        // Fix F3-4: 开始下载后启动轮询
        startDownloadPollingIfNeeded(gid: gallery.gid)
    }

    /// Fix F3-4: 当下载状态为进行中/等待时，每 2 秒轮询状态更新
    func startDownloadPollingIfNeeded(gid: Int64) {
        // 只在下载中/等待中状态才轮询
        guard downloadState == DownloadManager.stateDownload || downloadState == DownloadManager.stateWait else {
            downloadPollingTask?.cancel()
            downloadPollingTask = nil
            return
        }
        // 避免重复启动
        guard downloadPollingTask == nil else { return }

        downloadPollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self = self else { break }
                let newState = await DownloadManager.shared.getTaskState(gid: gid)
                self.downloadState = newState
                // 状态不再是“进行中”时停止轮询
                if newState != DownloadManager.stateDownload && newState != DownloadManager.stateWait {
                    break
                }
            }
            self?.downloadPollingTask = nil
        }
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
            // 如果返回有效评分则使用，否则使用用户选择的评分
            self.displayRating = result.rating > 0 ? Float(result.rating) : rating
            EhToast.success("已评分")
        } catch {
            // 此前只 debugLog：打完分请求失败，界面纹丝不动，用户以为打上了
            EhToast.failure("评分失败")
            debugLog("Rate gallery failed: \(error)")
        }
    }

    /// 加载全部评论 (带 ?hc=1 参数获取所有评论)
    func loadAllComments(gid: Int64, token: String) async {
        guard !isLoadingComments else { return }

        isLoadingComments = true

        do {
            let site = GalleryActionService.siteBaseURL
            // 添加 hc=1 参数来获取全部评论
            let urlStr = "\(site)g/\(gid)/\(token)/?hc=1"
            let result = try await EhAPI.shared.getGalleryDetail(url: urlStr)

            // 更新详情（主要是评论列表）
            // 保留原有详情，只更新评论部分
            if var currentDetail = self.detail {
                currentDetail.comments = result.comments
                self.detail = currentDetail
                // 更新缓存
                GalleryCache.shared.putDetail(currentDetail)
            }
            self.isLoadingComments = false
        } catch {
            self.isLoadingComments = false
            debugLog("Load all comments failed: \(error)")
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
                            Haptics.select()
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
                    Haptics.success()
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

    /// 只保存**裁剪好**的那一小块，不再持有整张精灵图
    @State private var thumbnail: PlatformImage?
    @State private var didFail = false

    var body: some View {
        Group {
            if let thumbnail {
                #if os(iOS)
                Image(uiImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                #else
                Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                #endif
            } else {
                placeholderView
            }
        }
        // 用 .task 而不是 .onAppear: 视图消失时自动取消，滚动飞快时不会堆积任务
        .task(id: cacheIdentity) {
            guard thumbnail == nil, !didFail else { return }
            let image = await SpriteSheetCache.shared.thumbnail(
                urlString: preview.imageUrl,
                offsetX: preview.offsetX,
                offsetY: preview.offsetY,
                clipWidth: preview.clipWidth,
                clipHeight: preview.clipHeight
            )
            guard !Task.isCancelled else { return }
            if let image {
                thumbnail = image
            } else {
                didFail = true
            }
        }
    }

    /// 同一张精灵图的不同区域要各自缓存，身份要带上裁剪参数
    private var cacheIdentity: String {
        "\(preview.imageUrl)|\(preview.offsetX),\(preview.offsetY),\(preview.clipWidth),\(preview.clipHeight)"
    }

    private var placeholderView: some View {
        Color(.tertiarySystemFill)
            .overlay {
                if didFail {
                    Image(systemName: "photo")
                        .foregroundStyle(.tertiary)
                } else {
                    ProgressView()
                }
            }
    }
}

// MARK: - FavoriteSlotPicker (对齐 Android FavoritesActivity 收藏夹选择器)

struct FavoriteSlotPicker: View {
    let onSelect: (Int) -> Void
    let onCancel: () -> Void
    /// 是否显示本地收藏选项 (对齐 Android: slot -1 = 本地收藏)
    var showLocalOption: Bool = true

    /// 「记住这个收藏夹，下次不再询问」。
    ///
    /// 对齐 Android CommonOperations.addToFavorites：它用的是
    /// ListCheckBoxDialogBuilder，勾选后把所选 slot 存进 defaultFavSlot，
    /// 之后收藏直接落到那个夹子不再弹窗；不勾则把默认清成 INVALID。
    /// 我们此前完全没有这个开关，用户每次收藏都要选一遍。
    @State private var remember = false

    private func pick(_ slot: Int) {
        AppSettings.shared.defaultFavSlot = remember ? slot : -2
        onSelect(slot)
    }

    var body: some View {
        NavigationStack {
            List {
                // 本地收藏 (对齐 Android FAV_CAT_LOCAL = -1)
                if showLocalOption {
                    Button {
                        pick(-1)
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
                        pick(slot)
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

                Section {
                    Toggle("记住这个收藏夹，下次不再询问", isOn: $remember)
                        .tint(EhColor.accentFill)
                } footer: {
                    Text("之后收藏会直接放进所选收藏夹。可在「我的 → 下载」设置里改回每次询问。")
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
