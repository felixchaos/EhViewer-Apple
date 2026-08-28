//
//  ImageReaderView.swift
//  ehviewer apple
//
//  Reader 2.0 — 沉浸式阅读体验
//  支持: 翻页/滚动模式、双页排版 (iPad/Mac)、模糊氛围背景、沉浸式工具栏
//  手势: 边缘侧滑返回、点击翻页、双击缩放、键盘/滚轮导航
//

import SwiftUI
import EhModels
import EhSpider
import EhSettings
import EhDatabase
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 跨平台图片 → Image 辅助

#if os(iOS)
private func nativeImage(_ img: UIImage) -> Image { Image(uiImage: img) }
#else
import AppKit
private func nativeImage(_ img: NSImage) -> Image { Image(nsImage: img) }
#endif

// MARK: - ImageReaderView

struct ImageReaderView: View {
    let gid: Int64
    let token: String
    let pages: Int
    let previewSet: PreviewSet?
    /// 初始页面 (0-based, 对齐 Android GalleryActivityEvent.page)
    let initialPage: Int?

    @State private var vm: ReaderViewModel
    @State private var showOverlay = true
    @State private var showSettings = false
    @State private var hasAppliedInitialPage = false
    @State private var isZoomed = false
    @State private var showTutorial = false

    // 跳页输入
    @State private var showJumpPageAlert = false
    @State private var jumpPageText = ""
    /// 进度条拖动中的本地值 —— 松手才提交给 ViewModel
    @State private var isSeeking = false
    @State private var seekValue: Double = 0

    // 从设置读取
    @State private var readingDirection: ReadingDirection = .topToBottom
    @State private var scaleMode: ScaleMode = .fit
    @State private var startPosition: StartPosition = .topRight

    // 自动翻页
    @State private var autoPageEnabled = false
    @State private var autoPageTask: Task<Void, Never>?

    // 时间显示
    @State private var currentTime = Date()
    @State private var timeTimer: Timer?

    // 垂直滚动模式
    @State private var isUpdatingFromScroll = false
    @State private var hasAppliedInitialScroll = false
    @State private var lastScrollChangeTime: Date = .distantPast
    /// Perf P0-2: 一次性缓存 showPageInterval 设置，避免滚动路径上读 UserDefaults
    @State private var verticalPageInterval: Bool = false

    // Perf: 翻页去抖 — 快速滑动时取消上一次预加载，仅处理最终落地页
    @State private var pageChangeTask: Task<Void, Never>?

    @Environment(\.dismiss) private var dismiss

    #if os(macOS)
    /// macOS 键盘焦点 — `.onKeyPress` 需要视图先获得焦点
    /// (iOS 不能这么做: 程序化聚焦会弹出软键盘，见 KeyCommandCatcher)
    @FocusState private var isReaderFocused: Bool
    #endif

    #if os(iOS)
    /// 音量键 / 媒体模式翻页器
    @State private var volumePageTurner = VolumeKeyPageTurner()
    #endif

    // 点击区域比例 (左右各 30%，中间 40% 用于工具栏)
    private let tapZoneRatio: CGFloat = 0.30
    /// 纵向边缘死区比例 (上下各 20%，防止误触)
    private let tapZoneVerticalDeadZone: CGFloat = 0.20

    /// 显式初始化器 (Fix D-2: 移除 isDownloaded 参数，由 ReaderViewModel 自行检查)
    init(
        gid: Int64,
        token: String,
        pages: Int,
        previewSet: PreviewSet? = nil,
        initialPage: Int? = nil
    ) {
        self.gid = gid
        self.token = token
        self.pages = pages
        self.previewSet = previewSet
        self.initialPage = initialPage

        let viewModel = ReaderViewModel()
        viewModel.gid = gid
        viewModel.token = token
        // Fix Race: 不在 init 中设置 totalPages — 延迟到 initializeReader()
        // 中 setupLocalGallery() 完成后再设置，防止页面 .task 在 isDownloaded
        // 确定前就触发 loadPage → 已下载画廊首页无意义走网络

        self._vm = State(initialValue: viewModel)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 模糊氛围背景 (双页/宽屏模式下，画面未覆盖区域显示主色调渐变)
                ambientBackground

                // 主内容
                if vm.totalPages == 0 {
                    ProgressView()
                        .tint(.white)
                } else if readingDirection == .topToBottom {
                    verticalScrollReader(geometry: geometry)
                } else {
                    #if os(macOS)
                    macOSPageReader(geometry: geometry)
                    #else
                    horizontalPageReader(geometry: geometry)
                    #endif
                }

                // 沉浸式覆盖层 (顶部/底部滑入动画)
                immersiveOverlay(geometry: geometry)

                // HUD 显示 (时钟/电量/进度)
                if !showOverlay {
                    hudOverlay(geometry: geometry)
                }

                // 浮动导航按钮 (工具栏隐藏时显示，提供翻页+工具栏切换)
                floatingNavigationOverlay(geometry: geometry)

                // 新手教程
                if showTutorial {
                    readerTutorialOverlay(geometry: geometry)
                }
            }
            .onAppear {
                // 检测宽屏+横屏 → 双页模式 (iPad 竖屏不触发)
                vm.updateLayout(screenWidth: geometry.size.width, screenHeight: geometry.size.height)
                vm.computeSpreads()
            }
            .onChange(of: geometry.size) { _, newSize in
                vm.updateLayout(screenWidth: newSize.width, screenHeight: newSize.height)
            }
        }
        #if os(iOS)
        .statusBarHidden(AppSettings.shared.readingFullscreen)
        .persistentSystemOverlays(AppSettings.shared.readingFullscreen ? .hidden : .automatic)
        #endif
        .ignoresSafeArea()
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #else
        .toolbar(.hidden)
        #endif
        .onAppear(perform: setupReader)
        .onDisappear(perform: cleanupReader)
        .task {
            await initializeReader()
            // Fix F2-2: 只有真正打开阅读器才记录历史 (从详情页 loadDetail 迁移到这里)
            recordReadingHistory()
        }
        .sheet(isPresented: $showSettings) {
            ReaderSettingsSheet(
                readingDirection: $readingDirection,
                scaleMode: $scaleMode,
                startPosition: $startPosition,
                autoPageEnabled: $autoPageEnabled
            )
        }
        // 跳页输入弹窗
        .alert("跳转到页码", isPresented: $showJumpPageAlert) {
            TextField("页码 (1-\(vm.totalPages))", text: $jumpPageText)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            Button("跳转") {
                if let page = Int(jumpPageText), page >= 1, page <= vm.totalPages {
                    goToPage(page - 1) // 0-based
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("输入 1 ~ \(vm.totalPages) 之间的页码")
        }
        // 切换阅读模式时从 NSCache 恢复已加载图片，避免重新下载
        .onChange(of: readingDirection) { _, _ in
            vm.restoreCachedImages(around: vm.currentPage)
        }
        // 键盘 / 外置翻页器
        //
        // iOS 走 UIKit responder chain (KeyCommandCatcher):
        //   之前用的是 SwiftUI `.focusable()` + `@FocusState`，但在 iOS 上程序化聚焦
        //   一个普通视图会被系统当成文本输入，切换阅读方向时直接弹出软键盘，
        //   而且 SwiftUI 的焦点手势会和阅读器内部的点击手势抢事件。
        // macOS 上 `.focusable()` 没有这些副作用，继续用 onKeyPress。
        #if os(iOS)
        .background {
            KeyCommandCatcher { action in
                handleReaderKey(action)
            }
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        }
        #else
        .focusable()
        .focused($isReaderFocused)
        .onAppear { isReaderFocused = true }
        .onChange(of: showSettings) { _, isShowing in
            if !isShowing { isReaderFocused = true }
        }
        .onChange(of: showJumpPageAlert) { _, isShowing in
            if !isShowing { isReaderFocused = true }
        }
        // ⚠️ 方向键的含义要和点击区域一致: 左键 = 左侧点击区
        //    (RTL 下左边是"下一页")。原来这里是反的，和 handleTapZone / Android 都对不上
        .onKeyPress(.leftArrow) {
            handleKeyNavigation(forward: readingDirection == .rightToLeft)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            handleKeyNavigation(forward: readingDirection != .rightToLeft)
            return .handled
        }
        .onKeyPress(.space) {
            goToNextPage()
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .onKeyPress(.upArrow) {
            // 竖向滚动模式交给 ScrollView 自己滚动
            if readingDirection == .topToBottom { return .ignored }
            goToPreviousPage()
            return .handled
        }
        .onKeyPress(.downArrow) {
            if readingDirection == .topToBottom { return .ignored }
            goToNextPage()
            return .handled
        }
        .onKeyPress(.pageUp) {
            goToPreviousPage()
            return .handled
        }
        .onKeyPress(.pageDown) {
            goToNextPage()
            return .handled
        }
        .onKeyPress(.home) {
            goToPage(0)
            return .handled
        }
        .onKeyPress(.end) {
            goToPage(vm.totalPages - 1)
            return .handled
        }
        .onKeyPress(.return) {
            goToNextPage()
            return .handled
        }
        #endif
        // 色彩滤镜 (对齐 Android GalleryActivity 的 colorFilter 叠加层)
        // 盖在所有内容之上、不吃手势；关掉时完全不参与渲染
        .overlay {
            if colorFilterOverlay != nil {
                colorFilterOverlay
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        #if os(iOS)
        // 边缘侧滑返回 — 仅在工具栏可见时启用，避免与翻页手势冲突
        .overlay {
            if showOverlay {
                EdgeSwipeDismissView { dismiss() }
                    .allowsHitTesting(true)
            }
        }
        #endif
    }

    /// 页码标签用的页号 —— 拖进度条时显示拖到的目标页，
    /// 否则松手前数字一直不动，会让人以为拖动没生效
    private var displayedPage: Int {
        guard isSeeking else { return vm.currentPage }
        return min(max(0, Int(seekValue.rounded())), max(0, vm.totalPages - 1))
    }

    /// 护眼滤镜色 —— 设置里存的是 ARGB 整数 (对齐 Android colorFilterColor)
    private var colorFilterOverlay: Color? {
        guard AppSettings.shared.colorFilter else { return nil }
        let argb = AppSettings.shared.colorFilterColor
        let a = Double((argb >> 24) & 0xFF) / 255.0
        let r = Double((argb >> 16) & 0xFF) / 255.0
        let g = Double((argb >> 8) & 0xFF) / 255.0
        let b = Double(argb & 0xFF) / 255.0
        guard a > 0 else { return nil }
        // 默认值 0x20000000 是半透明黑，直接压暗屏幕
        return Color(red: r, green: g, blue: b).opacity(a)
    }

    // MARK: - Reader Background

    /// 纯黑背景 — 节省 OLED 屏幕电量，移除 CIAreaAverage 计算
    @ViewBuilder
    private var ambientBackground: some View {
        Color.black.ignoresSafeArea()
    }

    // MARK: - Setup

    private func setupReader() {
        readingDirection = ReadingDirection(rawValue: AppSettings.shared.readingDirection) ?? .topToBottom
        scaleMode = ScaleMode(rawValue: AppSettings.shared.pageScaling) ?? .fit
        startPosition = StartPosition(rawValue: AppSettings.shared.startPosition) ?? .topRight
        verticalPageInterval = AppSettings.shared.showPageInterval

        #if os(iOS)
        if AppSettings.shared.keepScreenOn {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        UIDevice.current.isBatteryMonitoringEnabled = true
        if AppSettings.shared.customScreenLightness {
            setScreenBrightness(CGFloat(AppSettings.shared.screenLightness) / 100.0)
        }
        // 音量键翻页 (媒体模式的外置翻页器) — 对齐 Android volume_page 设置
        if AppSettings.shared.volumePage {
            volumePageTurner.start(
                onNext: { goToNextPage() },
                onPrevious: { goToPreviousPage() }
            )
        }
        #endif

        timeTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            currentTime = Date()
        }

        if readingDirection != .topToBottom && !hasAppliedInitialPage {
            let targetPage = vm.currentPage
            if targetPage > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self.vm.currentPage = targetPage
                }
            }
            hasAppliedInitialPage = true
        }

        let tutorialKey = "reader_tutorial_shown"
        if !UserDefaults.standard.bool(forKey: tutorialKey) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    showTutorial = true
                }
            }
        }
    }

    private func cleanupReader() {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
        UIDevice.current.isBatteryMonitoringEnabled = false
        volumePageTurner.stop()
        #endif
        timeTimer?.invalidate()
        autoPageTask?.cancel()
        pageChangeTask?.cancel()
        saveReadingProgress()
    }

    /// Fix F2-2: 只有真正打开阅读器才计入历史 (从 GalleryDetailViewModel.loadDetail 迁移至此)
    private func recordReadingHistory() {
        // 从缓存中获取画廊信息
        if let detail = GalleryCache.shared.getDetail(gid: gid) {
            let info = detail.info
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
                try EhDatabase.shared.trimHistory(maxCount: AppSettings.shared.historyInfoSize)
            } catch {
                debugLog("Failed to record reading history: \(error)")
            }
        } else {
            // 没有缓存时使用最少的信息 (从下载列表直接打开的情况)
            let record = HistoryRecord(
                gid: gid, token: token,
                title: "", category: 0,
                pages: pages, mode: 0, date: Date()
            )
            do {
                try EhDatabase.shared.insertHistory(record)
                try EhDatabase.shared.trimHistory(maxCount: AppSettings.shared.historyInfoSize)
            } catch {
                debugLog("Failed to record reading history: \(error)")
            }
        }

        // 记录最后阅读的画廊 GID (给"继续阅读"功能使用)
        UserDefaults.standard.set(gid, forKey: "eh_last_reading_gid")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "eh_last_reading_time")
    }

    private func initializeReader() async {
        // 🛡️ 身份守卫: 将 View 持有的 gid 显式传给 ViewModel
        // Context Switch → resetState() → UI 立即转 Loading
        // Hit Cache → 跳过初始化但仍应用 initialPage
        let needsLoad = vm.prepareForGallery(targetGid: gid, targetToken: token)

        if needsLoad {
            // Fix D-1, B-1: 从 DownloadManager 查询真实下载状态，替代硬编码 isDownloaded
            await vm.setupLocalGallery()

            // Fix Race: setupLocalGallery 完成后再设置 totalPages
            if pages > 0 {
                vm.totalPages = pages
            }

            if let ps = previewSet {
                vm.extractPTokens(from: ps)
            }

            if vm.totalPages == 0 {
                await vm.fetchGalleryInfo()
            }

            // 获取页数后重算 spreads
            vm.computeSpreads()
        }

        // Fix: 无论是否缓存命中，都应用目标页面
        // 用户可能从不同缩略图进入同一画廊 → initialPage 必须被尊重
        if let initial = initialPage, initial >= 0, initial < vm.totalPages {
            vm.currentPage = initial
        } else if needsLoad && initialPage == nil {
            // 仅首次加载时恢复保存的阅读进度 (缓存命中时保持当前页)
            let key = "reading_progress_\(gid)"
            if let saved = UserDefaults.standard.object(forKey: key) as? Int, vm.totalPages > 0 {
                vm.currentPage = min(saved, max(0, vm.totalPages - 1))
            }
        }

        // 🔑 同步所有滚动位置绑定 — onChange 不触发初始值，必须显式设置
        // lazyCurrentPage 驱动 .scrollPosition(id:)，不同步会导致 ScrollView 停留在第 0 页
        vm.lazyCurrentPage = vm.currentPage
        vm.verticalScrollPage = vm.currentPage
        if vm.isDoublePageEnabled {
            vm.syncSpreadIndex()
        }

        if needsLoad {
            await vm.loadCurrentPage()
        } else {
            // 缓存命中: 仍然触发目标页的加载/预加载
            await vm.onPageChange(vm.currentPage)
        }
    }

    // MARK: - Progress Persistence

    private func saveReadingProgress() {
        let key = "reading_progress_\(gid)"
        UserDefaults.standard.set(vm.currentPage, forKey: key)
    }

    // MARK: - Navigation

    #if os(iOS)
    /// 把硬件按键映射成翻页动作 —— 方向键要按当前阅读方向解释
    private func handleReaderKey(_ action: ReaderKeyAction) {
        switch action {
        case .previousPage: goToPreviousPage()
        case .nextPage:     goToNextPage()
        case .firstPage:    goToPage(0)
        case .lastPage:     goToPage(vm.totalPages - 1)
        case .dismiss:      dismiss()
        case .arrowLeft:    handleKeyNavigation(forward: readingDirection == .rightToLeft)
        case .arrowRight:   handleKeyNavigation(forward: readingDirection != .rightToLeft)
        case .arrowUp:      goToPreviousPage()
        case .arrowDown:    goToNextPage()
        }
    }
    #endif

    private func handleKeyNavigation(forward: Bool) {
        if forward { goToNextPage() } else { goToPreviousPage() }
    }

    private func goToNextPage() {
        if vm.isDoublePageEnabled {
            // 双页模式: 按 spread 翻页
            guard let currentIdx = vm.currentSpreadIndex else { return }
            let nextSpread = currentIdx + 1
            guard nextSpread < vm.spreads.count else { return }
            let nextPage = vm.pageForSpread(nextSpread)
            // 不使用 withAnimation: ScrollView 自带翻页动画，额外动画会导致闪烁
            vm.currentPage = nextPage
            vm.currentSpreadIndex = nextSpread
            Task { await vm.onPageChange(nextPage) }
        } else {
            guard vm.currentPage < vm.totalPages - 1 else { return }
            vm.currentPage += 1
            Task { await vm.onPageChange(vm.currentPage) }
        }
    }

    private func goToPreviousPage() {
        if vm.isDoublePageEnabled {
            guard let currentIdx = vm.currentSpreadIndex else { return }
            let prevSpread = currentIdx - 1
            guard prevSpread >= 0 else { return }
            let prevPage = vm.pageForSpread(prevSpread)
            vm.currentPage = prevPage
            vm.currentSpreadIndex = prevSpread
            Task { await vm.onPageChange(prevPage) }
        } else {
            guard vm.currentPage > 0 else { return }
            vm.currentPage -= 1
            Task { await vm.onPageChange(vm.currentPage) }
        }
    }

    private func goToPage(_ page: Int) {
        let target = max(0, min(vm.totalPages - 1, page))
        vm.currentPage = target
        if vm.isDoublePageEnabled {
            vm.syncSpreadIndex()
        }
        Task { await vm.onPageChange(target) }
    }

    // MARK: - Auto Page

    private func toggleAutoPage() {
        autoPageEnabled.toggle()
        if autoPageEnabled {
            startAutoPage()
        } else {
            autoPageTask?.cancel()
        }
    }

    private func startAutoPage() {
        autoPageTask?.cancel()
        autoPageTask = Task {
            while !Task.isCancelled && autoPageEnabled {
                try? await Task.sleep(nanoseconds: UInt64(AppSettings.shared.autoPageInterval) * 1_000_000_000)
                if !Task.isCancelled && autoPageEnabled {
                    await MainActor.run {
                        goToNextPage()
                    }
                }
            }
        }
    }

    // MARK: - Horizontal Page Reader (iOS)
    // Perf P0-1: 使用 ScrollView + LazyHStack + .scrollTargetBehavior(.paging) 替代 TabView
    // TabView(.page) 是非懒加载的 — 会一次性实例化所有子 View
    // LazyHStack 只创建可见区域内的 View，40 页画廊 → 仅 ~3 个 View

    private func horizontalPageReader(geometry: GeometryProxy) -> some View {
        Group {
            if vm.isDoublePageEnabled {
                // 双页模式: 按 spread 遍历，每个 spread 显示合成图
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 0) {
                        ForEach(vm.spreads) { spread in
                            spreadPageView(spread: spread)
                                .containerRelativeFrame(.horizontal)
                                .id(spread.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $vm.currentSpreadIndex)
                #if os(iOS)
                .environment(\.layoutDirection, readingDirection == .rightToLeft ? .rightToLeft : .leftToRight)
                #endif
                .onChange(of: vm.currentSpreadIndex) { _, newIdx in
                    guard let idx = newIdx else { return }
                    let page = vm.pageForSpread(idx)
                    if vm.currentPage != page {
                        vm.currentPage = page
                    }
                    saveReadingProgress()
                    // Perf: 去抖 — 快速翻页时只处理最终落地页
                    pageChangeTask?.cancel()
                    pageChangeTask = Task {
                        try? await Task.sleep(nanoseconds: 80_000_000) // 80ms debounce
                        guard !Task.isCancelled else { return }
                        await vm.onPageChange(page)
                    }
                }
            } else {
                // 单页模式
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 0) {
                        ForEach(0..<vm.totalPages, id: \.self) { idx in
                            pageImage(index: idx)
                                .containerRelativeFrame(.horizontal)
                                .id(idx)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $vm.lazyCurrentPage)
                // 图片缩放时禁用翻页滚动，让 SwiftUIZoomableImage 的拖动手势控制平移
                .scrollDisabled(isZoomed)
                #if os(iOS)
                .environment(\.layoutDirection, readingDirection == .rightToLeft ? .rightToLeft : .leftToRight)
                #endif
                .onChange(of: vm.lazyCurrentPage) { _, newPage in
                    if let page = newPage, page != vm.currentPage {
                        vm.currentPage = page
                    }
                    saveReadingProgress()
                    // Perf: 去抖 — 快速滑动时取消上一次预加载，仅处理结束页
                    pageChangeTask?.cancel()
                    pageChangeTask = Task {
                        try? await Task.sleep(nanoseconds: 80_000_000) // 80ms debounce
                        guard !Task.isCancelled else { return }
                        await vm.onPageChange(vm.currentPage)
                    }
                }
                .onChange(of: vm.currentPage) { _, newPage in
                    // 外部翻页 (键盘/浮动按钮/slider) → 同步 scrollPosition
                    if vm.lazyCurrentPage != newPage {
                        vm.lazyCurrentPage = newPage
                    }
                }
            }
        }
    }

    // MARK: - macOS Page Reader

    #if os(macOS)
    private func macOSPageReader(geometry: GeometryProxy) -> some View {
        ZStack {
            if vm.isDoublePageEnabled {
                let spreadIdx = vm.currentSpreadIndex ?? 0
                let spread = spreadIdx < vm.spreads.count
                    ? vm.spreads[spreadIdx]
                    : vm.spreads.last ?? PageSpread(id: 0, primaryPage: 0, secondaryPage: nil)
                spreadPageView(spread: spread)
            } else {
                pageImage(index: vm.currentPage)
            }

            ScrollWheelPageNavigator(
                onNext: { goToNextPage() },
                onPrevious: { goToPreviousPage() },
                isZoomed: isZoomed
            )
        }
        .onChange(of: vm.currentPage) { _, newPage in
            saveReadingProgress()
            Task { await vm.onPageChange(newPage) }
        }
    }
    #endif

    // MARK: - Spread Page View (双页合成视图)

    /// 显示一个 spread (单页或双页合成) — 使用 ViewModel 合成图
    @ViewBuilder
    private func spreadPageView(spread: PageSpread) -> some View {
        if let composited = vm.spreadImage(at: spread.id, direction: readingDirection) {
            ZoomableImageView(
                image: composited,
                scaleMode: scaleMode,
                startPosition: startPosition,
                allowsHorizontalScrollAtMinZoom: false,
                onSingleTap: { location, viewSize in
                    handleTapZone(location: location, viewSize: viewSize)
                },
                onZoomChanged: { zoomed in
                    isZoomed = zoomed
                }
            )
        } else {
            // 至少一页尚未加载 — 显示加载状态
            VStack(spacing: 12) {
                // 主页状态
                pageLoadingIndicator(index: spread.primaryPage)

                // 副页状态 (如果有)
                if let sec = spread.secondaryPage {
                    Divider().frame(width: 60).overlay(Color.white.opacity(0.3))
                    pageLoadingIndicator(index: sec)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task {
                // 同时加载两页
                await withTaskGroup(of: Void.self) { group in
                    for p in spread.pages {
                        group.addTask {
                            await vm.loadPageWithRetry(p)
                            await vm.downloadImageData(p)
                        }
                    }
                }
            }
        }
    }

    /// 单页加载指示器 (复用于 spread 和单页模式)
    @ViewBuilder
    private func pageLoadingIndicator(index: Int) -> some View {
        if vm.errorPages.contains(index) {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title3)
                    .foregroundStyle(.white)
                Text(vm.errorMessages[index] ?? "加载失败")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                Button("重新加载") {
                    Task { await vm.retryLoadPage(index) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.9))
            }
        } else if let progress = vm.downloadProgress[index], progress >= 0 {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.3), lineWidth: 3)
                    .frame(width: 48, height: 48)
                Circle()
                    .trim(from: 0, to: max(0.01, progress))
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 48, height: 48)
                    .rotationEffect(.degrees(-90))
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }
        } else if let retryCount = vm.retryingPages[index], retryCount > 0 {
            VStack(spacing: 4) {
                ProgressView().tint(.white)
                Text("重试 \(retryCount)/5")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }
        } else {
            ProgressView().tint(.white)
        }
    }

    // MARK: - Vertical Scroll Reader
    // Perf P0-2: 使用 .scrollPosition(id:) 替代 GeometryReader + PreferenceKey
    // 原实现每个 page item 绑定 GeometryReader，滚动每帧触发 preference 级联
    // .scrollPosition 是 SwiftUI 原生 API，内部由 runtime 高效追踪

    private func verticalScrollReader(geometry: GeometryProxy) -> some View {
        let contentWidth = geometry.size.width
        let showInterval = verticalPageInterval

        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: showInterval ? 8 : 0) {
                    ForEach(0..<vm.totalPages, id: \.self) { idx in
                        verticalPageImage(index: idx, containerWidth: contentWidth)
                            .frame(width: contentWidth)
                            .id(idx)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .clipped()
            // Perf: 垂直模式不再使用 SwiftUIZoomableImage，无需 scrollDisabled
            .scrollTargetLayout()
            .scrollPosition(id: $vm.verticalScrollPage, anchor: .top)
            .scrollBounceBehavior(.basedOnSize)
            .contentShape(Rectangle())
            // Fix: 使用 SpatialTapGesture 恢复点击翻页区域
            // 用 simultaneousGesture 不阻塞 ScrollView 的滚动手势
            // 滚动后 500ms 内忽略点击，防止惯性滚动误触
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { value in
                        let timeSinceScroll = Date().timeIntervalSince(lastScrollChangeTime)
                        guard timeSinceScroll > 0.5 else { return }
                        handleTapZone(location: value.location, viewSize: geometry.size)
                    }
            )
            .onAppear {
                if vm.currentPage > 0 && !hasAppliedInitialScroll {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            proxy.scrollTo(vm.currentPage, anchor: .top)
                        }
                        vm.verticalScrollPage = vm.currentPage
                        hasAppliedInitialScroll = true
                    }
                }
            }
            .onChange(of: vm.verticalScrollPage) { _, newPage in
                // 滚动引起的页码变化 → 同步 currentPage
                guard let page = newPage, page != vm.currentPage else { return }
                isUpdatingFromScroll = true
                vm.currentPage = page
                lastScrollChangeTime = Date()
                saveReadingProgress()
                // Perf: 去抖预加载 — 快速滚动时只处理最终落地页，避免大量并发预加载
                pageChangeTask?.cancel()
                pageChangeTask = Task {
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms debounce
                    guard !Task.isCancelled else { return }
                    await vm.onPageChange(page)
                }
                DispatchQueue.main.async {
                    self.isUpdatingFromScroll = false
                }
            }
            .onChange(of: vm.currentPage) { _, newPage in
                // 外部翻页 (键盘/slider/浮动按钮) → 滚动到目标页
                if !isUpdatingFromScroll {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(newPage, anchor: .top)
                    }
                    vm.verticalScrollPage = newPage
                    saveReadingProgress()
                }
            }
        }
    }

    /// 垂直滚动模式的页面图片 — 宽度撑满、高度按比例
    @ViewBuilder
    private func verticalPageImage(index: Int, containerWidth: CGFloat) -> some View {
        // 预估占位高度 (典型漫画页比例 ~1.4:1)，减少图片加载时的布局跳动
        let estimatedHeight = containerWidth * 1.4

        if vm.errorPages.contains(index) {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.white)
                Text(vm.errorMessages[index] ?? "加载失败")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                Button("重新加载") {
                    Task { await vm.retryLoadPage(index) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.9))
            }
            .frame(maxWidth: .infinity)
            .frame(height: estimatedHeight)
        } else if let cachedImage = vm.cachedImages[index] {
            // Perf: 垂直滚动模式使用轻量渲染 — 不加载 SwiftUIZoomableImage 的
            // GeometryReader + PreferenceKey + 3 套手势识别器，大幅减少 LazyVStack 滑动开销
            let imgSize = cachedImage.size
            let ratio = imgSize.width > 0 ? imgSize.height / imgSize.width : 1.4

            if cachedImage.isAnimated {
                #if os(macOS)
                AnimatedImageView(image: cachedImage, contentMode: .scaleProportionallyUpOrDown)
                    .frame(width: containerWidth, height: containerWidth * ratio)
                #else
                AnimatedImageView(image: cachedImage, contentMode: .scaleAspectFit)
                    .frame(width: containerWidth, height: containerWidth * ratio)
                #endif
            } else {
                nativeImage(cachedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: containerWidth)
            }
        } else if vm.imageURLs[index] != nil {
            VStack(spacing: 8) {
                if let progress = vm.downloadProgress[index], progress >= 0 {
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.3), lineWidth: 3)
                            .frame(width: 48, height: 48)
                        Circle()
                            .trim(from: 0, to: max(0.01, progress))
                            .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .frame(width: 48, height: 48)
                            .rotationEffect(.degrees(-90))
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    }
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                    Text("下载图片中...")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: estimatedHeight)
            .task(id: "\(vm.imageURLs[index] ?? "")_\(vm.retryGeneration[index, default: 0])") {
                await vm.downloadImageData(index)
            }
        } else {
            VStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                if let retryCount = vm.retryingPages[index], retryCount > 0 {
                    Text("重试 \(retryCount)/5")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: estimatedHeight)
            .task {
                await vm.loadPageWithRetry(index)
            }
        }
    }

    // MARK: - Single Page Image (翻页模式单页)

    private func pageImage(index: Int) -> some View {
        Group {
            if vm.errorPages.contains(index) {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.white)
                    Text(vm.errorMessages[index] ?? "加载失败")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                    Button("重新加载") {
                        Task { await vm.retryLoadPage(index) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white.opacity(0.9))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let cachedImage = vm.cachedImages[index] {
                #if os(iOS)
                SwiftUIZoomableImage(
                    image: cachedImage,
                    isFullPage: true,
                    onSingleTap: { location, viewSize in
                        handleTapZone(location: location, viewSize: viewSize)
                    },
                    onZoomChanged: { zoomed in
                        isZoomed = zoomed
                    }
                )
                #else
                ZoomableImageView(
                    image: cachedImage,
                    scaleMode: scaleMode,
                    startPosition: startPosition,
                    allowsHorizontalScrollAtMinZoom: readingDirection == .topToBottom,
                    onSingleTap: { location, viewSize in
                        handleTapZone(location: location, viewSize: viewSize)
                    },
                    onZoomChanged: { zoomed in
                        isZoomed = zoomed
                    }
                )
                #endif
            } else if vm.imageURLs[index] != nil {
                VStack(spacing: 8) {
                    if let progress = vm.downloadProgress[index], progress >= 0 {
                        ZStack {
                            Circle()
                                .stroke(Color.white.opacity(0.3), lineWidth: 3)
                                .frame(width: 48, height: 48)
                            Circle()
                                .trim(from: 0, to: max(0.01, progress))
                                .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .frame(width: 48, height: 48)
                                .rotationEffect(.degrees(-90))
                            Text("\(Int(progress * 100))%")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    } else {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                        Text("下载图片中...")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: "\(vm.imageURLs[index] ?? "")_\(vm.retryGeneration[index, default: 0])") {
                    await vm.downloadImageData(index)
                }
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                    if let retryCount = vm.retryingPages[index], retryCount > 0 {
                        Text("重试 \(retryCount)/5")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task {
                    await vm.loadPageWithRetry(index)
                }
            }
        }
    }

    // MARK: - Tap Zone Detection

    private func handleTapZone(location: CGPoint, viewSize: CGSize) {
        guard viewSize.width > 0 && viewSize.height > 0 else { return }

        let relX = location.x / viewSize.width
        let relY = location.y / viewSize.height

        guard relY > tapZoneVerticalDeadZone && relY < (1 - tapZoneVerticalDeadZone) else {
            return
        }

        if relX < tapZoneRatio {
            // 左侧 25%: RTL → 下一页, LTR/垂直 → 上一页
            if readingDirection == .rightToLeft {
                goToNextPage()
            } else {
                goToPreviousPage()
            }
        } else if relX > (1 - tapZoneRatio) {
            // 右侧 25%: RTL → 上一页, LTR/垂直 → 下一页
            if readingDirection == .rightToLeft {
                goToPreviousPage()
            } else {
                goToNextPage()
            }
        } else {
            // 中间 50%: 切换工具栏
            withAnimation(.easeInOut(duration: 0.2)) { showOverlay.toggle() }
        }
    }

    // MARK: - Reader Tutorial Overlay

    private func readerTutorialOverlay(geometry: GeometryProxy) -> some View {
        let w = geometry.size.width
        let h = geometry.size.height
        let sideW = w * tapZoneRatio
        let deadH = h * tapZoneVerticalDeadZone

        return ZStack {
            Color.black.opacity(0.75)
                .ignoresSafeArea()

            // 左侧区域标注
            VStack(spacing: 4) {
                Image(systemName: readingDirection == .rightToLeft ? "arrow.right" : "arrow.left")
                    .font(.title2)
                Text(readingDirection == .rightToLeft ? "下一页" : "上一页")
                    .font(.caption.bold())
            }
            .foregroundStyle(.white)
            .position(x: sideW / 2, y: h / 2)

            // 中央区域标注
            VStack(spacing: 8) {
                Image(systemName: "hand.tap")
                    .font(.title)
                Text("单击: 显示/隐藏工具栏")
                    .font(.caption.bold())
                Divider()
                    .frame(width: 80)
                    .overlay(Color.white.opacity(0.5))
                Image(systemName: "hand.tap")
                    .font(.title)
                    .overlay(
                        Image(systemName: "hand.tap")
                            .font(.title)
                            .offset(x: 2, y: 2)
                            .opacity(0.5)
                    )
                Text("双击: 放大/复原")
                    .font(.caption.bold())
            }
            .foregroundStyle(.white)
            .position(x: w / 2, y: h / 2)

            // 右侧区域标注
            VStack(spacing: 4) {
                Image(systemName: readingDirection == .rightToLeft ? "arrow.left" : "arrow.right")
                    .font(.title2)
                Text(readingDirection == .rightToLeft ? "上一页" : "下一页")
                    .font(.caption.bold())
            }
            .foregroundStyle(.white)
            .position(x: w - sideW / 2, y: h / 2)

            // 上方死区标注
            Text("死区 (不响应)")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
                .position(x: w / 2, y: deadH / 2)

            // 下方死区标注
            Text("死区 (不响应)")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
                .position(x: w / 2, y: h - deadH / 2)

            // 左右滑动翻页提示
            VStack(spacing: 4) {
                Image(systemName: "hand.draw")
                    .font(.title3)
                Text("左右滑动也可以翻页")
                    .font(.caption)
            }
            .foregroundStyle(.white.opacity(0.8))
            .position(x: w / 2, y: h - deadH - 40)

            // 关闭按钮
            VStack {
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showTutorial = false
                    }
                    UserDefaults.standard.set(true, forKey: "reader_tutorial_shown")
                } label: {
                    Text("我知道了")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 12)
                        .background(.white.opacity(0.2), in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.5), lineWidth: 1))
                }
                .padding(.bottom, max(40, geometry.safeAreaInsets.bottom + 20))
            }

            // 区域分界线
            Rectangle()
                .fill(.white.opacity(0.2))
                .frame(width: 1, height: h - deadH * 2)
                .position(x: sideW, y: h / 2)
            Rectangle()
                .fill(.white.opacity(0.2))
                .frame(width: 1, height: h - deadH * 2)
                .position(x: w - sideW, y: h / 2)
            Rectangle()
                .fill(.white.opacity(0.15))
                .frame(width: w, height: 1)
                .position(x: w / 2, y: deadH)
            Rectangle()
                .fill(.white.opacity(0.15))
                .frame(width: w, height: 1)
                .position(x: w / 2, y: h - deadH)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.3)) {
                showTutorial = false
            }
            UserDefaults.standard.set(true, forKey: "reader_tutorial_shown")
        }
    }

    // MARK: - Immersive Overlay (沉浸式工具栏)

    /// 顶部/底部工具栏以滑入动画出现，对齐 Apple HIG 沉浸式媒体体验
    private func immersiveOverlay(geometry: GeometryProxy) -> some View {
        VStack {
            // 顶部工具栏 — 从顶部滑入
            if showOverlay {
                topBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Spacer()

            // 底部工具栏 — 从底部滑入
            if showOverlay {
                bottomBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showOverlay)
    }

    private var topBar: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }

            Spacer()

            // 页码显示 (双页模式标注 spread) — 点击可跳页
            Button {
                jumpPageText = "\(vm.currentPage + 1)"
                showJumpPageAlert = true
            } label: {
                Group {
                    if vm.isDoublePageEnabled, let currentIdx = vm.currentSpreadIndex, currentIdx < vm.spreads.count {
                        let spread = vm.spreads[currentIdx]
                        if let sec = spread.secondaryPage {
                            Text("\(spread.primaryPage + 1)-\(sec + 1) / \(vm.totalPages)")
                        } else {
                            Text("\(spread.primaryPage + 1) / \(vm.totalPages)")
                        }
                    } else {
                        Text("\(displayedPage + 1) / \(vm.totalPages)")
                    }
                }
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
            }

            Spacer()

            // 阅读方向
            Menu {
                ForEach(ReadingDirection.allCases, id: \.rawValue) { dir in
                    Button {
                        readingDirection = dir
                        AppSettings.shared.readingDirection = dir.rawValue
                    } label: {
                        Label(dir.label, systemImage: dir.icon)
                    }
                }
            } label: {
                Image(systemName: readingDirection.icon)
                    .font(.title3)
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }

            // 设置
            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.horizontal)
        .padding(.top, 50)
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            // 阅读方向提示
            if readingDirection != .topToBottom {
                HStack(spacing: 6) {
                    Text(readingDirection == .rightToLeft ? "← 从右到左" : "从左到右 →")
                    if vm.isDoublePageEnabled {
                        Text("· 双页")
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
            }

            HStack(spacing: 16) {
                Button(action: goToPreviousPage) {
                    Image(systemName: "chevron.left.circle.fill")
                        .font(.title)
                        .foregroundStyle(.white.opacity(vm.currentPage > 0 ? 1 : 0.3))
                }
                .disabled(vm.currentPage == 0)

                // 拖动期间只更新本地 state，不碰 vm.currentPage。
                // currentPage 是 @Observable，每动一像素写一次会让整个阅读器
                // (ScrollView + 所有页视图) 重新求值 —— 这正是拖进度条卡顿的原因。
                Slider(
                    value: Binding(
                        get: { isSeeking ? seekValue : Double(vm.currentPage) },
                        // setter 自己置 isSeeking —— 不能依赖 onEditingChanged(true)
                        // 先于第一次 set 到达，否则它会把刚拖到的值清回当前页
                        set: { newValue in
                            isSeeking = true
                            seekValue = newValue
                        }
                    ),
                    in: 0...Double(max(vm.totalPages - 1, 1)),
                    step: 1
                ) { editing in
                    guard !editing else { return }
                    isSeeking = false
                    let target = Int(seekValue.rounded())
                    guard target != vm.currentPage,
                          target >= 0, target < vm.totalPages else { return }
                    vm.currentPage = target
                    vm.lazyCurrentPage = target
                    vm.verticalScrollPage = target
                    if vm.isDoublePageEnabled { vm.syncSpreadIndex() }
                    Task { await vm.onPageChange(target) }
                }
                .tint(.white)

                Button(action: goToNextPage) {
                    Image(systemName: "chevron.right.circle.fill")
                        .font(.title)
                        .foregroundStyle(.white.opacity(vm.currentPage < vm.totalPages - 1 ? 1 : 0.3))
                }
                .disabled(vm.currentPage == vm.totalPages - 1)
            }
            .padding(.horizontal)

            // 自动翻页
            HStack {
                Button(action: toggleAutoPage) {
                    HStack {
                        Image(systemName: autoPageEnabled ? "pause.fill" : "play.fill")
                        Text(autoPageEnabled ? "暂停" : "自动翻页")
                    }
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    // MARK: - HUD Overlay

    private func hudOverlay(geometry: GeometryProxy) -> some View {
        VStack {
            Spacer()
            HStack {
                if AppSettings.shared.showClock {
                    Text(currentTime, style: .time)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                }

                Spacer()

                // 页码已移至 floatingNavigationOverlay，不再重复显示

                if AppSettings.shared.showBattery {
                    batteryView
                }
            }
            .padding(.horizontal, max(20, geometry.safeAreaInsets.leading + 12))
            .padding(.bottom, max(12, geometry.safeAreaInsets.bottom + 4))
        }
    }

    // MARK: - Floating Navigation Overlay (浮动导航)

    /// 浮动导航栏 — 工具栏隐藏时始终可见，提供翻页和工具栏切换
    /// 修复: 上下滚动模式无法翻页 + 没有上/下一页按钮
    @ViewBuilder
    private func floatingNavigationOverlay(geometry: GeometryProxy) -> some View {
        if !showOverlay && vm.totalPages > 0 {
            let isRTL = readingDirection == .rightToLeft
            let isVertical = readingDirection == .topToBottom
            let isFirstPage = vm.currentPage <= 0
            let isLastPage = vm.currentPage >= vm.totalPages - 1

            VStack {
                Spacer()

                HStack(spacing: 0) {
                    // 左侧 / 上一页按钮
                    Button {
                        if isRTL { goToNextPage() } else { goToPreviousPage() }
                    } label: {
                        Image(systemName: isVertical ? "chevron.up" : "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 40)
                    }
                    .disabled(isRTL ? isLastPage : isFirstPage)
                    .opacity((isRTL ? isLastPage : isFirstPage) ? 0.25 : 0.8)

                    // 自定义分割线 (替代 Divider 避免超出 Capsule)
                    Rectangle()
                        .fill(Color.white.opacity(0.2))
                        .frame(width: 1, height: 20)

                    // 中央: 页码 + 点击跳页
                    Button {
                        jumpPageText = "\(vm.currentPage + 1)"
                        showJumpPageAlert = true
                    } label: {
                        Text("\(displayedPage + 1) / \(vm.totalPages)")
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(minWidth: 64, maxHeight: 40)
                    }

                    // 自定义分割线
                    Rectangle()
                        .fill(Color.white.opacity(0.2))
                        .frame(width: 1, height: 20)

                    // 右侧 / 下一页按钮
                    Button {
                        if isRTL { goToPreviousPage() } else { goToNextPage() }
                    } label: {
                        Image(systemName: isVertical ? "chevron.down" : "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 40)
                    }
                    .disabled(isRTL ? isFirstPage : isLastPage)
                    .opacity((isRTL ? isFirstPage : isLastPage) ? 0.25 : 0.8)
                }
                .background(.black.opacity(0.35), in: Capsule())
                .padding(.bottom, max(16, geometry.safeAreaInsets.bottom + 4))
            }
        }
    }

    private var batteryView: some View {
        HStack(spacing: 2) {
            #if os(iOS)
            let level = Int(UIDevice.current.batteryLevel * 100)
            let isCharging = UIDevice.current.batteryState == .charging
            Image(systemName: isCharging ? "battery.100.bolt" : "battery.\(min(100, max(0, (level / 25) * 25)))")
                .font(.caption)
            Text("\(max(0, level))%")
                .font(.caption.monospacedDigit())
            #else
            Image(systemName: "battery.100")
                .font(.caption)
            #endif
        }
        .foregroundStyle(.white.opacity(0.7))
    }
}

// MARK: - Reader Settings Sheet

struct ReaderSettingsSheet: View {
    @Binding var readingDirection: ReadingDirection
    @Binding var scaleMode: ScaleMode
    @Binding var startPosition: StartPosition
    @Binding var autoPageEnabled: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("阅读方向") {
                    Picker("方向", selection: $readingDirection) {
                        ForEach(ReadingDirection.allCases, id: \.rawValue) { dir in
                            Label(dir.label, systemImage: dir.icon).tag(dir)
                        }
                    }
                    .onChange(of: readingDirection) { _, newValue in
                        AppSettings.shared.readingDirection = newValue.rawValue
                    }
                }

                Section("缩放模式") {
                    Picker("缩放", selection: $scaleMode) {
                        ForEach(ScaleMode.allCases, id: \.rawValue) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .onChange(of: scaleMode) { _, newValue in
                        AppSettings.shared.pageScaling = newValue.rawValue
                    }
                }

                Section("起始位置") {
                    Picker("位置", selection: $startPosition) {
                        ForEach(StartPosition.allCases, id: \.rawValue) { pos in
                            Text(pos.label).tag(pos)
                        }
                    }
                    .onChange(of: startPosition) { _, newValue in
                        AppSettings.shared.startPosition = newValue.rawValue
                    }
                }

                Section("显示") {
                    Toggle("显示时钟", isOn: Binding(
                        get: { AppSettings.shared.showClock },
                        set: { AppSettings.shared.showClock = $0 }
                    ))
                    Toggle("显示进度", isOn: Binding(
                        get: { AppSettings.shared.showProgress },
                        set: { AppSettings.shared.showProgress = $0 }
                    ))
                    Toggle("显示电量", isOn: Binding(
                        get: { AppSettings.shared.showBattery },
                        set: { AppSettings.shared.showBattery = $0 }
                    ))
                    Toggle("页面间距", isOn: Binding(
                        get: { AppSettings.shared.showPageInterval },
                        set: { AppSettings.shared.showPageInterval = $0 }
                    ))
                }

                Section("行为") {
                    Toggle("屏幕常亮", isOn: Binding(
                        get: { AppSettings.shared.keepScreenOn },
                        set: { AppSettings.shared.keepScreenOn = $0 }
                    ))
                    Toggle("全屏模式", isOn: Binding(
                        get: { AppSettings.shared.readingFullscreen },
                        set: { AppSettings.shared.readingFullscreen = $0 }
                    ))

                    #if os(iOS)
                    Toggle("自定义亮度", isOn: Binding(
                        get: { AppSettings.shared.customScreenLightness },
                        set: { AppSettings.shared.customScreenLightness = $0 }
                    ))

                    if AppSettings.shared.customScreenLightness {
                        HStack {
                            Image(systemName: "sun.min")
                            Slider(value: Binding(
                                get: { Double(AppSettings.shared.screenLightness) },
                                set: {
                                    AppSettings.shared.screenLightness = Int($0)
                                    setScreenBrightness(CGFloat($0) / 100.0)
                                }
                            ), in: 0...100)
                            Image(systemName: "sun.max")
                        }
                    }
                    #endif
                }

                Section("自动翻页") {
                    Stepper(
                        "间隔: \(AppSettings.shared.autoPageInterval) 秒",
                        value: Binding(
                            get: { AppSettings.shared.autoPageInterval },
                            set: { AppSettings.shared.autoPageInterval = $0 }
                        ),
                        in: 1...60
                    )
                }
            }
            .navigationTitle("阅读设置")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
    }
}

// Perf P0-2: PageOffsetPreferenceKey 已移除 — 改用 .scrollPosition(id:) 追踪页码

// MARK: - Edge Swipe Dismiss (iOS fullScreenCover 边缘侧滑返回)

// MARK: - SwiftUI Zoomable Image (纯 SwiftUI 缩放)

/// PreferenceKey: 向父视图传递子视图尺寸
private struct ViewSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// 纯 SwiftUI 可缩放图片 — 不使用 UIScrollView，彻底避免与父 ScrollView 的手势冲突
///
/// 手势架构:
/// 1. 单击/双击: 统一用 SpatialTapGesture(count:1) + 手动 300ms 延时检测
///    解决 TapGesture(count:2) 与 SpatialTapGesture(count:1) 类型不匹配导致双击无法触发的问题
/// 2. 双指缩放 (MagnifyGesture): 始终以 .simultaneousGesture 挂载，不阻塞父 ScrollView
/// 3. 拖动平移 (DragGesture): 通过 overlay + allowsHitTesting(isZoomed) 控制
///    - 1x 时 overlay 不接收触摸 → 父 ScrollView 自由滚动/翻页
///    - >1x 时 overlay 拦截触摸 → 拖动平移图片，阻止父 ScrollView 滚动
///    - overlay 上同时挂载 tap + pinch 手势，防止被 overlay 遮挡
#if os(iOS)
private struct SwiftUIZoomableImage: View {
    let image: PlatformImage
    /// 全屏页模式 (翻页阅读器) vs 流式模式 (垂直滚动)
    var isFullPage: Bool = false
    var onSingleTap: ((CGPoint, CGSize) -> Void)?
    var onZoomChanged: ((Bool) -> Void)?

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var viewSize: CGSize = .zero
    /// 手动双击检测
    @State private var lastTapTime: Date = .distantPast
    @State private var pendingSingleTap: Task<Void, Never>?
    /// 防止双指缩放时触发拖动平移
    @State private var isPinching: Bool = false

    private var isZoomed: Bool { scale > 1.01 }

    var body: some View {
        let imgSize = image.size
        let ratio = imgSize.width > 0 ? imgSize.height / imgSize.width : 1.0

        imageContent(ratio: ratio)
            .background {
                GeometryReader { geo in
                    Color.clear
                        .preference(key: ViewSizePreferenceKey.self, value: geo.size)
                }
            }
            .onPreferenceChange(ViewSizePreferenceKey.self) { viewSize = $0 }
            // ── 非缩放时的手势 (overlay 不拦截, 这些生效) ──
            // 单击/双击: 统一 SpatialTapGesture + 300ms 手动检测
            .gesture(
                SpatialTapGesture(count: 1)
                    .onEnded { value in
                        handleTap(at: value.location)
                    }
            )
            // 双指缩放: simultaneousGesture 不阻塞父 ScrollView
            .simultaneousGesture(magnifyGesture)
            // ── 缩放后的拖动 overlay ──
            // allowsHitTesting: 1x 时不拦截 → 父 ScrollView 正常; >1x 时拦截 → 拖动平移
            .overlay {
                Color.clear
                    .contentShape(Rectangle())
                    .allowsHitTesting(isZoomed)
                    // overlay 上也需要 tap + pinch，否则会被 overlay 吞掉
                    .gesture(
                        SpatialTapGesture(count: 1)
                            .onEnded { value in
                                handleTap(at: value.location)
                            }
                    )
                    .simultaneousGesture(magnifyGesture)
                    // 拖动平移 (simultaneousGesture: 不阻塞同层 tap/pinch)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 5)
                            .onChanged { value in
                                guard !isPinching else { return }
                                let proposed = CGSize(
                                    width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height
                                )
                                offset = clampOffset(proposed)
                            }
                            .onEnded { _ in
                                if isPinching {
                                    // 双指缩放期间的误触拖动 → 还原
                                    offset = lastOffset
                                } else {
                                    lastOffset = offset
                                }
                            }
                    )
            }
    }

    // MARK: - Gesture Definitions

    /// 双指缩放手势 (抽取为计算属性, base 和 overlay 复用)
    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                isPinching = true
                scale = max(1.0, min(3.0, lastScale * value.magnification))
            }
            .onEnded { _ in
                isPinching = false
                lastScale = scale
                if scale < 1.1 {
                    withAnimation(.spring()) { resetZoom() }
                } else {
                    onZoomChanged?(true)
                }
            }
    }

    /// 手动双击/单击检测: 300ms 窗口
    /// - 第二次点击在 300ms 内 → 双击 (缩放切换)
    /// - 超过 300ms 无第二次 → 单击 (工具栏/翻页)
    private func handleTap(at location: CGPoint) {
        let now = Date()
        let interval = now.timeIntervalSince(lastTapTime)
        lastTapTime = now

        if interval < 0.3 {
            // ── 双击 ──
            pendingSingleTap?.cancel()
            pendingSingleTap = nil
            withAnimation(.spring(duration: 0.3)) {
                if scale < 1.5 {
                    scale = 2.0
                    lastScale = 2.0
                    onZoomChanged?(true)
                } else {
                    resetZoom()
                }
            }
        } else {
            // ── 可能是单击 — 等 300ms 确认不是双击 ──
            pendingSingleTap?.cancel()
            let size = viewSize
            pendingSingleTap = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                onSingleTap?(location, size)
            }
        }
    }

    // MARK: - Image Content

    @ViewBuilder
    private func imageContent(ratio: CGFloat) -> some View {
        if isFullPage {
            if image.isAnimated {
                #if os(macOS)
                AnimatedImageView(image: image, contentMode: .scaleProportionallyUpOrDown)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scaleEffect(scale)
                    .offset(offset)
                    .clipped()
                #else
                AnimatedImageView(image: image, contentMode: .scaleAspectFit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scaleEffect(scale)
                    .offset(offset)
                    .clipped()
                #endif
            } else {
                nativeImage(image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scaleEffect(scale)
                    .offset(offset)
                    .clipped()
            }
        } else {
            if image.isAnimated {
                #if os(macOS)
                AnimatedImageView(image: image, contentMode: .scaleProportionallyUpOrDown)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1.0 / ratio, contentMode: .fit)
                    .scaleEffect(scale)
                    .offset(offset)
                    .clipped()
                #else
                AnimatedImageView(image: image, contentMode: .scaleAspectFit)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1.0 / ratio, contentMode: .fit)
                    .scaleEffect(scale)
                    .offset(offset)
                    .clipped()
                #endif
            } else {
                nativeImage(image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1.0 / ratio, contentMode: .fit)
                    .scaleEffect(scale)
                    .offset(offset)
                    .clipped()
            }
        }
    }

    private func resetZoom() {
        scale = 1.0
        lastScale = 1.0
        offset = .zero
        lastOffset = .zero
        onZoomChanged?(false)
    }

    /// 限制平移范围: 不允许超过缩放后多出的可视区域
    private func clampOffset(_ proposed: CGSize) -> CGSize {
        let maxX = max(0, viewSize.width * (scale - 1) / 2)
        let maxY = max(0, viewSize.height * (scale - 1) / 2)
        return CGSize(
            width: min(maxX, max(-maxX, proposed.width)),
            height: min(maxY, max(-maxY, proposed.height))
        )
    }
}
#endif

#if os(iOS)
/// UIScreenEdgePanGestureRecognizer — 在 fullScreenCover 中实现原生边缘右滑返回
/// fullScreenCover 无 UINavigationController，需要自行添加手势
struct EdgeSwipeDismissView: UIViewRepresentable {
    let onDismiss: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = EdgeSwipeGestureView()
        let edgeGesture = UIScreenEdgePanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleEdgePan(_:))
        )
        edgeGesture.edges = .left
        // 降低手势优先级，避免与 TabView 滑动冲突
        edgeGesture.delegate = context.coordinator
        view.addGestureRecognizer(edgeGesture)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    /// 透明视图，仅在左边缘 30pt 内响应触摸
    class EdgeSwipeGestureView: UIView {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            // 只拦截左边缘 30pt 的触摸
            if point.x < 30 {
                return self
            }
            return nil
        }
    }

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let onDismiss: () -> Void

        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
        }

        @objc func handleEdgePan(_ gesture: UIScreenEdgePanGestureRecognizer) {
            guard gesture.state == .ended else { return }
            let translation = gesture.translation(in: gesture.view)
            let velocity = gesture.velocity(in: gesture.view)
            // 滑动距离 > 80pt 或速度 > 500 则触发返回
            if translation.x > 80 || velocity.x > 500 {
                onDismiss()
            }
        }

        // 允许与其他手势同时识别
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            return false
        }
    }
}
#endif

// MARK: - macOS Scroll Wheel Page Navigator

#if os(macOS)
/// macOS 滚轮翻页 — 累积 deltaY 超过阈值翻页
struct ScrollWheelPageNavigator: NSViewRepresentable {
    let onNext: () -> Void
    let onPrevious: () -> Void
    let isZoomed: Bool

    func makeNSView(context: Context) -> ScrollWheelCaptureView {
        let view = ScrollWheelCaptureView()
        view.onNext = onNext
        view.onPrevious = onPrevious
        view.isZoomed = isZoomed
        return view
    }

    func updateNSView(_ nsView: ScrollWheelCaptureView, context: Context) {
        nsView.onNext = onNext
        nsView.onPrevious = onPrevious
        nsView.isZoomed = isZoomed
    }

    class ScrollWheelCaptureView: NSView {
        var onNext: (() -> Void)?
        var onPrevious: (() -> Void)?
        var isZoomed: Bool = false
        private var accumulatedDelta: CGFloat = 0
        private let threshold: CGFloat = 40
        private var lastScrollTime: Date = .distantPast

        override func scrollWheel(with event: NSEvent) {
            guard !isZoomed else {
                super.scrollWheel(with: event)
                return
            }

            let delta = event.scrollingDeltaY
            let now = Date()
            if now.timeIntervalSince(lastScrollTime) > 0.5 {
                accumulatedDelta = 0
            }
            lastScrollTime = now

            accumulatedDelta += delta

            if accumulatedDelta > threshold {
                accumulatedDelta = 0
                onPrevious?()
            } else if accumulatedDelta < -threshold {
                accumulatedDelta = 0
                onNext?()
            }
        }

        override var acceptsFirstResponder: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            if isZoomed { return nil }
            return frame.contains(point) ? self : nil
        }
    }
}
#endif

// MARK: - Helper Functions

#if os(iOS)
/// 设置屏幕亮度
private func setScreenBrightness(_ brightness: CGFloat) {
    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
       let screen = windowScene.windows.first?.screen {
        screen.brightness = brightness
    }
}
#endif
