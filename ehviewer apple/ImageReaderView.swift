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
import UniformTypeIdentifiers
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
    let galleryHint: GalleryInfo?
    let onRequestClose: (() -> Void)?
    /// 初始页面 (0-based, 对齐 Android GalleryActivityEvent.page)
    let initialPage: Int?

    @State private var vm: ReaderViewModel
    @State private var openAttempt = 0
    @State private var failedToOpen = false
    @State private var showOverlay = true
    @State private var showSettings = false
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    @State private var idleTimerReaderID = UUID()
    @State private var isReaderVisible = false

    private var wantsIdleTimerDisabled: Bool {
        isReaderVisible && scenePhase == .active && AppSettings.shared.keepScreenOn
    }
    #endif
    /// 页面网格（对齐 Android 阅读器的「目录」）——
    /// 此前跳页只有底部那条 slider，200 页的本子要靠手感拖
    @State private var showPageGrid = false
    @State private var pageExport: ReaderPageExport?
    @State private var isExportingPageFile = false
    @State private var pageExportTask: Task<Void, Never>?
    #if os(iOS)
    @State private var pageShare: ReaderPageExport?
    #endif
    @State private var hasAppliedInitialPage = false
    @State private var isZoomed = false
    @State private var showTutorial = false

    // 跳页输入
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
    #if EH_OFFLINE_UI_FIXTURE && targetEnvironment(simulator)
    @State private var fixtureScrollMetrics = FixtureScrollMetrics()
    @State private var fixturePinchTrace = ""
    @State private var fixturePinchBegins = 0
    private struct FixtureScrollMetrics: Equatable {
        var x = 0
        var y = 0
        var width = 0
    }
    #endif
    @State private var verticalPageInterval: Bool = false

    // Perf: 翻页去抖 — 快速滑动时取消上一次预加载，仅处理最终落地页
    @State private var pageChangeTask: Task<Void, Never>?
    #if os(iOS)
    @State private var singlePagePaging = ReaderPagingCommit()
    @State private var zoomedSinglePages: Set<Int> = []
    @State private var spreadPaging = ReaderPagingCommit()
    // The model's spread index remains the committed one during a swipe
    // so keyboard, tap and grid actions don't start from a transient ID.
    @State private var nativeSpreadAnchor: Int?
    #endif


    @Environment(\.dismiss) private var dismiss

    #if os(macOS)
    /// macOS 键盘焦点 — `.onKeyPress` 需要视图先获得焦点
    /// (iOS 不能这么做: 程序化聚焦会弹出软键盘，见 KeyCommandCatcher)
    @FocusState private var isReaderFocused: Bool
    #endif

    #if os(iOS)
    /// 音量键 / 媒体模式翻页器
    @State private var volumePageTurner = VolumeKeyPageTurner()
    @State private var verticalMediaScroll = ReaderVerticalMediaScroll()
    @State private var verticalZoom: CGFloat = 1
    @State private var verticalPinchActive = false
    @State private var verticalPinch: (scale: CGFloat, anchor: ReaderVerticalMediaScroll.ZoomAnchor)?
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
        initialPage: Int? = nil,
        galleryHint: GalleryInfo? = nil,
        onRequestClose: (() -> Void)? = nil
    ) {
        self.gid = gid
        self.token = token
        self.pages = pages
        self.previewSet = previewSet
        self.initialPage = initialPage
        self.galleryHint = galleryHint
        self.onRequestClose = onRequestClose

        let viewModel = ReaderViewModel()
        viewModel.gid = gid
        viewModel.token = token
        // Fix Race: 不在 init 中设置 totalPages — 延迟到 openGallery()
        // 中 setupLocalGallery() 完成后再设置，防止页面 .task 在本地目录
        // 确定前就触发 loadPage → 已下载画廊首页无意义走网络

        self._vm = State(initialValue: viewModel)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 模糊氛围背景 (双页/宽屏模式下，画面未覆盖区域显示主色调渐变)
                ambientBackground

                // Only the artwork extends beneath system insets. Controls and
                // HUD use the active window's live, potentially asymmetric safe area.
                GeometryReader { artworkGeometry in
                    if vm.totalPages == 0 {
                        if failedToOpen {
                            VStack(spacing: 14) {
                                Text("无法加载画廊")
                                Button("重试") {
                                    failedToOpen = false
                                    openAttempt += 1
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ProgressView()
                                .tint(.white)
                        }
                    } else if readingDirection == .topToBottom {
                        verticalScrollReader(geometry: artworkGeometry)
                    } else {
                        #if os(macOS)
                        macOSPageReader(geometry: artworkGeometry)
                        #else
                        horizontalPageReader(geometry: artworkGeometry)
                        #endif
                    }
                }
                .ignoresSafeArea(.container)

                // 沉浸式覆盖层 (顶部/底部滑入动画)
                immersiveOverlay

                // HUD 显示 (时钟/电量/进度)
                if !showOverlay {
                    hudOverlay
                }

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
        .onChange(of: wantsIdleTimerDisabled) { _, _ in
            updateIdleTimerOwnership()
        }
        .onChange(of: AppSettings.shared.volumePage) { _, _ in
            updateVolumePaging()
        }
        .statusBarHidden(AppSettings.shared.readingFullscreen)
        .persistentSystemOverlays(AppSettings.shared.readingFullscreen ? .hidden : .automatic)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            vm.discardSpreadComposition()
        }
        #endif
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #else
        .toolbar(.hidden)
        #endif
        // Only logical page changes affect progress. A resize can remap both
        // scroll anchors without being a page turn.
        .onChange(of: vm.currentPage) { oldPage, newPage in
            if readingDirection != .topToBottom {
                enterFullscreenOnAdvance(from: oldPage, to: newPage)
            }
            vm.saveReadingProgress(for: gid)
        }
        .onAppear(perform: setupReader)
        .onDisappear(perform: cleanupReader)
        .task(id: openAttempt) {
            await vm.openGallery(
                gid: gid, token: token, pageCount: pages,
                previewSet: previewSet, initialPage: initialPage
            )
            guard !Task.isCancelled else { return }
            failedToOpen = vm.totalPages == 0
            if !failedToOpen { recordReadingHistory() }
        }
        #if EH_OFFLINE_UI_FIXTURE && targetEnvironment(simulator)
        .overlay(alignment: .trailing) {
            if EhOfflineUIFixture.volumePagingFixture {
                VStack {
                    Button("Fixture volume down") { volumePageTurner.sendFixtureVolume(0.4) }
                    Button("Fixture volume up") { volumePageTurner.sendFixtureVolume(0.6) }
                    Text("Fixture page \(vm.currentPage + 1)")
                    if EhOfflineUIFixture.tallVolumeFixture {
                        Text("Fixture scroll").accessibilityValue(String(fixtureScrollMetrics.y))
                        if ProcessInfo.processInfo.environment["EH_FIXTURE_KEY_COMMANDS"] == "1" {
                            Button("Fixture PgDn") { KeyCommandView.sendFixtureKey(UIKeyCommand.inputPageDown, onKey: handleReaderKey) }
                            Button("Fixture PgUp") { KeyCommandView.sendFixtureKey(UIKeyCommand.inputPageUp, onKey: handleReaderKey) }
                            Button("Fixture Down") { KeyCommandView.sendFixtureKey(UIKeyCommand.inputDownArrow, onKey: handleReaderKey) }
                            Button("Fixture Up") { KeyCommandView.sendFixtureKey(UIKeyCommand.inputUpArrow, onKey: handleReaderKey) }
                        }
                    }
                }
                .padding(8)
                .foregroundStyle(.white)
                .background(.black)
            } else if EhOfflineUIFixture.verticalGestureFixture {
                VStack {
                    Text("Fixture vertical reader")
                        .accessibilityValue(Text(verbatim: "\(fixtureScrollMetrics.y)|\(vm.currentPage + 1)"))
                    Text("Fixture vertical zoom")
                        .accessibilityValue(Text(verbatim: "\(fixtureScrollMetrics.x)|\(fixtureScrollMetrics.y)|\(fixtureScrollMetrics.width)"))
                    Text("Fixture pinch")
                        .accessibilityValue(Text(verbatim: fixturePinchTrace))
                }
                .foregroundStyle(.white)
                .padding(8)
                .background(.black)
                .allowsHitTesting(false)
            }
        }
        #endif
        .sheet(isPresented: $showSettings) {
            ReaderSettingsSheet(
                readingDirection: $readingDirection,
                scaleMode: $scaleMode,
                startPosition: $startPosition,
                autoPageEnabled: $autoPageEnabled
            )
        }
        .fileExporter(isPresented: $isExportingPageFile,
                      document: pageExport.map(ReaderPageExportDocument.init),
                      contentTypes: [pageExport?.type ?? .image],
                      defaultFilename: pageExport?.basename) { result in
            pageExport = nil
            if case .failure = result { EhToast.failure("无法存储图片") }
        } onCancellation: {
            pageExport = nil
        }
        #if os(iOS)
        .sheet(item: $pageShare) { export in
            ReaderPageShareSheet(export: export)
        }
        #endif
        .sheet(isPresented: $showPageGrid) {
            ReaderPageGrid(total: vm.totalPages, current: vm.currentPage) { target in
                showPageGrid = false
                vm.currentPage = target
                vm.lazyCurrentPage = target
                vm.verticalScrollPage = target
                if vm.isDoublePageEnabled { vm.syncSpreadIndex() }
                Task { await vm.onPageChange(target) }
            }
        }
        // 跳页弹窗已随浮动导航一起删除：跳页现在走顶栏的目录网格
        // （ReaderPageGrid）和底栏的滑杆，不再需要手输页码
        // 切换阅读模式时从 NSCache 恢复已加载图片，避免重新下载
        .onChange(of: readingDirection) { previous, current in
            #if os(iOS)
            vm.discardSpreadOnEnteringVertical(from: previous, to: current)
            #endif
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
            closeReader()
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
        .modifier(ReaderInteractiveBack(onDismiss: closeReader))
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

    private func closeReader() {
        if let onRequestClose { onRequestClose() } else { dismiss() }
    }

    private func setupReader() {
        readingDirection = ReadingDirection(persistedRawValue: AppSettings.shared.readingDirection)
        #if EH_OFFLINE_UI_FIXTURE && targetEnvironment(simulator)
        if EhOfflineUIFixture.tallVolumeFixture { readingDirection = .topToBottom }
        if EhOfflineUIFixture.readerGestureFixture {
            readingDirection = EhOfflineUIFixture.verticalGestureFixture ? .topToBottom : .leftToRight
        }
        if let fixture = EhOfflineUIFixture.readerLoadingMode {
            readingDirection = fixture == "vertical" ? .topToBottom
                : (fixture == "spread-error" ? .rightToLeft : .leftToRight)
            if fixture.hasPrefix("spread"), !vm.isDoublePageEnabled { vm.toggleDoublePage() }
        }
        #endif
        scaleMode = ScaleMode(persistedRawValue: AppSettings.shared.pageScaling)
        startPosition = StartPosition(persistedRawValue: AppSettings.shared.startPosition)
        verticalPageInterval = AppSettings.shared.showPageInterval

        #if os(iOS)
        isReaderVisible = true
        updateIdleTimerOwnership()
        UIDevice.current.isBatteryMonitoringEnabled = true
        if AppSettings.shared.customScreenLightness {
            setScreenBrightness(CGFloat(AppSettings.shared.screenLightness) / 100.0)
        }
        updateVolumePaging()
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

    #if os(iOS)
    private func updateVolumePaging() {
        if isReaderVisible && AppSettings.shared.volumePage {
            volumePageTurner.start(
                onNext: { stepFromPagingKey(forward: true) },
                onPrevious: { stepFromPagingKey(forward: false) }
            )
        } else {
            volumePageTurner.stop()
        }
    }

    private func stepFromPagingKey(forward: Bool) {
        if readingDirection == .topToBottom,
           verticalMediaScroll.step(forward: forward, pageSpacing: verticalPageInterval ? 8 * verticalZoom : 0) {
            return
        }
        handleKeyNavigation(forward: forward)
    }

    private func updateIdleTimerOwnership() {
        ReaderIdleTimerOwnership.shared.update(idleTimerReaderID, isVisible: isReaderVisible,
                                               sceneIsActive: scenePhase == .active,
                                               keepAwake: AppSettings.shared.keepScreenOn)
    }
    #endif

    private func cleanupReader() {
        pageExportTask?.cancel()
        pageExportTask = nil
        #if os(iOS)
        isReaderVisible = false
        ReaderIdleTimerOwnership.shared.remove(idleTimerReaderID)
        UIDevice.current.isBatteryMonitoringEnabled = false
        volumePageTurner.stop()
        vm.discardSpreadComposition()
        #endif
        timeTimer?.invalidate()
        autoPageTask?.cancel()
        pageChangeTask?.cancel()
        if vm.totalPages > 0 {
            vm.saveReadingProgress(for: gid)
            #if os(iOS)
            if (UserDefaults.standard.object(forKey: "eh_last_reading_gid") as? NSNumber)?.int64Value == gid {
                NotificationCenter.default.post(name: .continueReadingProgressSaved, object: nil)
            }
            #endif
        }
    }

    /// Keep known history and local metadata when no detail has been loaded.
    private static func historyRecordFromLocalSources(gid: Int64, pages: Int) -> HistoryRecord? {
        if let existing = (try? EhDatabase.shared.getHistory(gid: gid)) ?? nil {
            return existing
        }
        if let dl = (try? EhDatabase.shared.getDownload(gid: gid)) ?? nil {
            var r = HistoryRecord(gid: gid, token: dl.token, title: dl.title,
                                  titleJpn: dl.titleJpn, thumb: dl.thumb,
                                  category: dl.category, posted: dl.posted,
                                  uploader: dl.uploader, rating: dl.rating,
                                  simpleLanguage: dl.simpleLanguage,
                                  pages: dl.pages > 0 ? dl.pages : pages,
                                  mode: 0, date: Date())
            r.simpleTags = dl.simpleTags
            return r
        }
        if let fav = (try? EhDatabase.shared.getLocalFavorite(gid: gid)) ?? nil {
            var r = HistoryRecord(gid: gid, token: fav.token, title: fav.title,
                                  titleJpn: fav.titleJpn, thumb: fav.thumb,
                                  category: fav.category, posted: fav.posted,
                                  uploader: fav.uploader, rating: fav.rating,
                                  simpleLanguage: fav.simpleLanguage,
                                  pages: fav.pages > 0 ? fav.pages : pages,
                                  mode: 0, date: Date())
            r.simpleTags = fav.simpleTags
            return r
        }
        return nil
    }

    private func historyRecord(from info: GalleryInfo) -> HistoryRecord {
        var record = HistoryRecord(
            gid: info.gid, token: info.token, title: info.bestTitle,
            category: info.category.rawValue, pages: vm.totalPages, mode: 0, date: Date()
        )
        record.titleJpn = info.titleJpn
        record.thumb = info.thumb
        record.posted = info.posted
        record.uploader = info.uploader
        record.rating = info.rating
        record.simpleTags = info.simpleTags
        record.simpleLanguage = info.simpleLanguage
        return record
    }

    /// A direct read can have a usable Browse row without a cached detail.
    /// Publish the resume target only after its matching History row is saved.
    private func recordReadingHistory() {
        guard !Task.isCancelled, vm.totalPages > 0 else { return }
        let record: HistoryRecord
        if let detail = GalleryCache.shared.getDetail(gid: gid) {
            record = historyRecord(from: detail.info)
        } else if var previous = Self.historyRecordFromLocalSources(gid: gid, pages: vm.totalPages) {
            previous.date = Date()
            previous.pages = vm.totalPages
            record = previous
        } else if let galleryHint, galleryHint.gid == gid, galleryHint.token == token,
                  [galleryHint.title, galleryHint.titleJpn].compactMap({ $0 })
                    .contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            record = historyRecord(from: galleryHint)
        } else {
            return
        }
        do {
            try EhDatabase.shared.insertHistory(record)
            UserDefaults.standard.set(gid, forKey: "eh_last_reading_gid")
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "eh_last_reading_time")
            try? EhDatabase.shared.trimHistory(maxCount: AppSettings.shared.historyInfoSize)
            NotificationCenter.default.post(name: .galleryHistoryChanged, object: nil)
        } catch {
            debugLog("Failed to record reading history: \(error)")
        }
    }

    /// 往后翻就收起工具条，进入全屏。
    ///
    /// 只在「前进」时收，不在回退时展开：读者往下读是连续动作，工具条留在
    /// 那里一直挡着；而往回翻常常是为了找刚才那一页，这时候突然弹出工具条
    /// 反而更碍事。要用工具条点一下屏幕中间就行。
    private func enterFullscreenOnAdvance(from old: Int?, to new: Int?) {
        guard let new, let old, new > old, showOverlay else { return }
        withAnimation(.easeInOut(duration: 0.2)) { showOverlay = false }
    }

    // MARK: - Navigation

    #if os(iOS)
    /// 把硬件按键映射成翻页动作 —— 方向键要按当前阅读方向解释
    private func handleReaderKey(_ action: ReaderKeyAction) {
        switch action {
        case .pageUp, .arrowUp: stepFromPagingKey(forward: false)
        case .pageDown, .arrowDown: stepFromPagingKey(forward: true)
        case .nextPage:     goToNextPage()
        case .firstPage:    goToPage(0)
        case .lastPage:     goToPage(vm.totalPages - 1)
        case .dismiss:      closeReader()
        case .arrowLeft:    handleKeyNavigation(forward: readingDirection == .rightToLeft)
        case .arrowRight:   handleKeyNavigation(forward: readingDirection != .rightToLeft)
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
                #if os(iOS)
                .scrollPosition(id: $nativeSpreadAnchor)
                .environment(\.layoutDirection, readingDirection == .rightToLeft ? .rightToLeft : .leftToRight)
                .onAppear { nativeSpreadAnchor = vm.currentSpreadIndex }
                .onDisappear { spreadPaging = ReaderPagingCommit() }
                .onChange(of: vm.currentPage) { _, _ in spreadPaging.explicitPageChanged() }
                .onChange(of: vm.currentSpreadIndex) { _, newIndex in
                    if nativeSpreadAnchor != newIndex {
                        nativeSpreadAnchor = newIndex
                    }
                }
                .onScrollPhaseChange { _, phase in
                    switch phase {
                    case .tracking, .interacting, .decelerating, .animating:
                        spreadPaging.begin(from: vm.currentPage)
                    case .idle:
                        let candidate = vm.pageTurnTarget(forSpreadID: nativeSpreadAnchor)
                        switch spreadPaging.settle(
                            logicalPage: vm.currentPage, candidate: candidate, totalPages: vm.totalPages
                        ) {
                        case .move(let page):
                            vm.currentSpreadIndex = nativeSpreadAnchor
                            commitSettledHorizontalPage(page)
                        case .restoreExplicitAnchor:
                            nativeSpreadAnchor = vm.currentSpreadIndex
                        case .unchanged:
                            break
                        }
                    @unknown default:
                        break
                    }
                }
                #else
                .scrollPosition(id: $vm.currentSpreadIndex)
                #endif
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
                #if os(iOS)
                .scrollDisabled(zoomedSinglePages.contains(vm.currentPage))
                .environment(\.layoutDirection, readingDirection == .rightToLeft ? .rightToLeft : .leftToRight)
                .onDisappear {
                    singlePagePaging = ReaderPagingCommit()
                    zoomedSinglePages.removeAll()
                }
                .onChange(of: vm.currentPage) { _, newPage in
                    singlePagePaging.explicitPageChanged()
                    if vm.lazyCurrentPage != newPage {
                        vm.lazyCurrentPage = newPage
                    }
                }
                .onScrollPhaseChange { _, phase in
                    switch phase {
                    case .tracking, .interacting, .decelerating, .animating:
                        singlePagePaging.begin(from: vm.currentPage)
                    case .idle:
                        switch singlePagePaging.settle(
                            logicalPage: vm.currentPage, candidate: vm.lazyCurrentPage, totalPages: vm.totalPages
                        ) {
                        case .move(let page):
                            commitSettledHorizontalPage(page)
                        case .restoreExplicitAnchor:
                            vm.lazyCurrentPage = vm.currentPage
                        case .unchanged:
                            break
                        }
                    @unknown default:
                        break
                    }
                }
                #else
                .scrollDisabled(isZoomed)
                #endif
            }
        }
    }

    #if os(iOS)
    private func commitSettledHorizontalPage(_ page: Int) {
        vm.currentPage = page
        pageChangeTask?.cancel()
        pageChangeTask = Task { await vm.onPageChange(page) }
    }
    #endif

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
            Task { await vm.onPageChange(newPage) }
        }
    }
    #endif

    // MARK: - Spread Page View (双页合成视图)

    /// 显示一个 spread (单页或双页合成) — 使用 ViewModel 合成图
    private func spreadPageView(spread: PageSpread) -> some View {
        let presentation = vm.spreadPresentation(at: spread.id, direction: readingDirection)
        let active = spread.pages.contains(vm.currentPage)
        let ready = spread.pages.allSatisfy { vm.isImageReady($0) && !vm.errorPages.contains($0) }
        return ZStack(alignment: .bottom) {
            if let presentation {
                spreadImageView(presentation)
                    #if EH_OFFLINE_UI_FIXTURE && targetEnvironment(simulator)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(presentation.displayedPage.map { "第 \($0 + 1) 页图片" } ?? "双页图片")
                    .accessibilityIdentifier(presentation.displayedPage.map { "reader-drawn-page-\($0 + 1)" }
                                             ?? "reader-drawn-spread")
                    #endif
                    .contextMenu {
                        if let page = presentation.displayedPage {
                            pageMenu(index: page)
                        } else if let second = spread.secondaryPage {
                            let first = spread.primaryPage
                            Menu("第 \(first + 1) 页") { pageMenu(index: first) }
                            Menu("第 \(second + 1) 页") { pageMenu(index: second) }
                        } else {
                            pageMenu(index: spread.primaryPage)
                        }
                    }
                if !ready, active {
                    // Keep the first image readable while its partner loads.
                    pageLoadingIndicator(for: spread.pages, active: true)
                        .padding(10)
                        .background(.black.opacity(0.78), in: .rect(cornerRadius: 12))
                        .padding(.bottom, 100)
                }
            } else {
                pageLoadingIndicator(for: spread.pages, active: active)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: spread.pages.map { "\(vm.imageURLs[$0] ?? "")_\(vm.retryGeneration[$0, default: 0])" }
                        .joined(separator: "|")) {
            // The secondary page must keep loading even if its partner already rendered.
            await withTaskGroup(of: Void.self) { group in
                for p in spread.pages {
                    group.addTask { await vm.superviseLoading(of: p) }
                }
            }
        }
    }

    private func spreadImageView(_ spread: ReaderViewModel.SpreadPresentation) -> ZoomableImageView {
        let view = ZoomableImageView(
            image: spread.image,
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
        #if os(iOS)
        var sizedView = view
        sizedView.logicalImageSize = spread.logicalSize
        return sizedView
        #else
        return view
        #endif
    }

    /// One status for the displayed image or spread. A prefetched placeholder
    /// may be partially visible, but must not start a second spinner.
    @ViewBuilder
    private func pageLoadingIndicator(for pages: [Int], active: Bool) -> some View {
        let failures = pages.filter { vm.errorPages.contains($0) }
        if !failures.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title3)
                    .foregroundStyle(.white)
                ForEach(failures, id: \.self) { index in
                    let error = vm.errorMessages[index] ?? "加载失败"
                    Text(pages.count > 1 ? "第 \(index + 1) 页：\(error)" : error)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                Button("重新加载") {
                    Task {
                        await withTaskGroup(of: Void.self) { group in
                            for index in failures {
                                group.addTask { await vm.retryLoadPage(index) }
                            }
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.9))
            }
        } else if active {
            let progress = loadingFraction(for: pages)
            let retry = pages.compactMap { vm.retryingPages[$0] }.max()
            VStack(spacing: 4) {
                if let progress {
                    ZStack {
                        Circle().stroke(.white.opacity(0.3), lineWidth: 3)
                        Circle()
                            .trim(from: 0, to: max(0.01, progress))
                            .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(min(99, Int(progress * 100)))%")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .frame(width: 48, height: 48)
                    .foregroundStyle(.white)
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .frame(width: 48, height: 48)
                    if let retry, retry > 0 {
                        Text("重试 \(retry)/5").font(.caption2).foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(pages.count > 1 ? "正在加载双页图片" : "正在加载图片")
            .accessibilityValue(progress.map { "\(min(99, Int($0 * 100)))%" } ?? "")
            .accessibilityIdentifier("reader-image-loading")
        } else {
            Image(systemName: "photo")
                .foregroundStyle(.white.opacity(0.32))
                .accessibilityHidden(true)
        }
    }

    private func loadingFraction(for pages: [Int]) -> Double? {
        let values = pages.compactMap { index -> Double? in
            if vm.isImageReady(index) { return 1 }
            guard let progress = vm.downloadProgress[index], progress.isFinite, progress >= 0 else { return nil }
            return min(1, progress)
        }
        guard !values.isEmpty, values.count == pages.count else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    // MARK: - Vertical Scroll Reader
    // Perf P0-2: 使用 .scrollPosition(id:) 替代 GeometryReader + PreferenceKey
    // 原实现每个 page item 绑定 GeometryReader，滚动每帧触发 preference 级联
    // .scrollPosition 是 SwiftUI 原生 API，内部由 runtime 高效追踪

    private func verticalScrollReader(geometry: GeometryProxy) -> some View {
        let viewportWidth = geometry.size.width
        #if os(iOS)
        let contentWidth = viewportWidth * verticalZoom
        let axes: Axis.Set = [.vertical, .horizontal]
        let spacing = verticalPageInterval ? 8 * verticalZoom : 0
        #else
        let contentWidth = viewportWidth
        let axes: Axis.Set = .vertical
        let spacing: CGFloat = verticalPageInterval ? 8 : 0
        #endif

        return ScrollViewReader { proxy in
            ScrollView(axes, showsIndicators: false) {
                LazyVStack(spacing: spacing) {
                    ForEach(0..<vm.totalPages, id: \.self) { idx in
                        verticalPageImage(index: idx, containerWidth: contentWidth)
                            .frame(width: contentWidth)
                            .id(idx)
                    }
                }
                .frame(width: contentWidth, alignment: .center)
                .scrollTargetLayout()
                #if os(iOS)
                .background(alignment: .topLeading) {
                    ReaderVerticalMediaScrollAnchor(target: verticalMediaScroll) { phase, scale, location in
                        handleVerticalPinch(phase, magnification: scale, at: location, viewportWidth: viewportWidth)
                    }
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                }
                #endif
            }
            .clipped()
            .scrollPosition(id: $vm.verticalScrollPage, anchor: .top)
            .scrollBounceBehavior(.basedOnSize, axes: axes)
            #if EH_OFFLINE_UI_FIXTURE && targetEnvironment(simulator)
            .onScrollGeometryChange(for: FixtureScrollMetrics.self, of: { geometry in
                guard EhOfflineUIFixture.verticalGestureFixture || EhOfflineUIFixture.tallVolumeFixture
                else { return FixtureScrollMetrics() }
                return FixtureScrollMetrics(x: Int(geometry.visibleRect.minX.rounded()),
                                            y: Int(geometry.visibleRect.minY.rounded()),
                                            width: Int(geometry.contentSize.width.rounded()))
            }, action: { _, metrics in fixtureScrollMetrics = metrics })
            #endif
            .contentShape(Rectangle())
            #if os(iOS)
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentSize.width }) { _, _ in
                // Wait until the scroll backing view sees the new lazy layout.
                Task { @MainActor in verticalMediaScroll.applyZoomAfterLayout() }
            }
            .simultaneousGesture(
                SpatialTapGesture(count: 2).onEnded { value in
                    guard !verticalPinchActive, viewportWidth > 0, geometry.size.height > 0 else { return }
                    let point = UnitPoint(x: value.location.x / viewportWidth,
                                          y: value.location.y / geometry.size.height)
                    guard let anchor = verticalMediaScroll.zoomAnchor(at: point, scale: verticalZoom) else { return }
                    setVerticalZoom(verticalZoom > 1.01 ? 1 : 2, anchor: anchor, viewportWidth: viewportWidth)
                }
                .exclusively(before: SpatialTapGesture().onEnded { value in
                    guard !verticalPinchActive else { return }
                    handleSettledVerticalTap(at: value.location, size: geometry.size)
                })
            )
            #else
            .simultaneousGesture(SpatialTapGesture().onEnded { value in
                handleSettledVerticalTap(at: value.location, size: geometry.size)
            })
            #endif
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
            .onChange(of: vm.verticalScrollPage) { oldPage, newPage in
                enterFullscreenOnAdvance(from: oldPage, to: newPage)
                // 滚动引起的页码变化 → 同步 currentPage
                guard let page = newPage, page != vm.currentPage else { return }
                isUpdatingFromScroll = true
                vm.currentPage = page
                lastScrollChangeTime = Date()
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
                }
            }
        }
    }

    private func handleSettledVerticalTap(at point: CGPoint, size: CGSize) {
        // A scroll settling on another image must not also trigger a tap zone.
        guard Date().timeIntervalSince(lastScrollChangeTime) > 0.5 else { return }
        handleTapZone(location: point, viewSize: size)
    }

    #if os(iOS)
    private func handleVerticalPinch(_ phase: UIGestureRecognizer.State, magnification: CGFloat,
                                     at location: UnitPoint, viewportWidth: CGFloat) {
        #if EH_OFFLINE_UI_FIXTURE && targetEnvironment(simulator)
        if EhOfflineUIFixture.verticalGestureFixture {
            if phase == .began { fixturePinchBegins += 1 }
            fixturePinchTrace = "\(fixturePinchBegins)|\(phase.rawValue)|\(Int(magnification * 1000))"
        }
        #endif
        switch phase {
        case .began:
            if let anchor = verticalMediaScroll.zoomAnchor(at: location, scale: verticalZoom) {
                verticalPinch = (verticalZoom, anchor)
                verticalPinchActive = true
            }
        case .changed, .ended:
            if let pinch = verticalPinch {
                let factor = pinch.scale * magnification
                setVerticalZoom(phase == .ended && factor < 1.05 ? 1 : factor,
                                anchor: pinch.anchor, viewportWidth: viewportWidth)
            }
            if phase == .ended {
                verticalPinch = nil
                verticalPinchActive = false
            }
        case .cancelled, .failed:
            verticalPinch = nil
            verticalPinchActive = false
        default:
            break
        }
    }

    private func setVerticalZoom(_ requested: CGFloat, anchor: ReaderVerticalMediaScroll.ZoomAnchor,
                                 viewportWidth: CGFloat) {
        let next = min(3, max(1, requested))
        guard abs(next - verticalZoom) * viewportWidth > 0.5 else { return }
        verticalMediaScroll.prepareZoom(width: viewportWidth * next, offset: anchor.offset(at: next))
        verticalZoom = next
    }
    #endif

    /// 垂直滚动模式的页面图片 — 宽度撑满、高度按比例
    @ViewBuilder
    private func verticalPageImage(index: Int, containerWidth: CGFloat) -> some View {
        // 预估占位高度 (典型漫画页比例 ~1.4:1)，减少图片加载时的布局跳动
        let estimatedHeight = containerWidth * 1.4

        if !vm.errorPages.contains(index), let cachedImage = vm.image(at: index) {
            // Perf: 垂直滚动模式使用轻量渲染 — 不加载 SwiftUIZoomableImage 的
            // GeometryReader + PreferenceKey + 3 套手势识别器，大幅减少 LazyVStack 滑动开销
            let imgSize = cachedImage.size
            let ratio = imgSize.width > 0 ? imgSize.height / imgSize.width : 1.4

            // 单页菜单在横竖两种模式下都要有。垂直模式走的是这条独立的
            // 轻量渲染路径，只在 pageImage 上挂菜单的话，上下滚动模式里长按没反应。
            Group {
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
            }
            .contextMenu {
                pageMenu(index: index)
            }
        } else {
            pageLoadingIndicator(for: [index], active: index == (vm.verticalScrollPage ?? vm.currentPage))
                .frame(maxWidth: .infinity)
                .frame(height: estimatedHeight)
                .task(id: "\(vm.imageURLs[index] ?? "")_\(vm.retryGeneration[index, default: 0])") {
                    await vm.superviseLoading(of: index)
                }
        }
    }

    // MARK: - Single Page Image (翻页模式单页)

    /// 单页菜单。四项与 Android GalleryActivity.showPageDialog 一一对应：
    private enum PageExportDestination {
        case file
        #if os(iOS)
        case share, photos
        #endif
    }

    @ViewBuilder
    private func pageMenu(index: Int) -> some View {
        Button {
            Task { await vm.retryLoadPage(index) }
        } label: {
            Label("刷新本页", systemImage: "arrow.clockwise")
        }

        #if os(iOS)
        Button {
            exportPage(index, to: .share)
        } label: {
            Label("分享", systemImage: "square.and.arrow.up")
        }
        Button {
            exportPage(index, to: .photos)
        } label: {
            Label("保存到相册", systemImage: "photo.badge.arrow.down")
        }
        #endif
        Button {
            exportPage(index, to: .file)
        } label: {
            Label("存储到文件", systemImage: "folder.badge.plus")
        }
    }

    private func exportPage(_ index: Int, to destination: PageExportDestination) {
        guard pageExportTask == nil, !isExportingPageFile else { return }
        pageExportTask = Task {
            defer { if !Task.isCancelled { pageExportTask = nil } }
            let source = await vm.pageExport(index)
            guard !Task.isCancelled else { return }
            guard let source else {
                EhToast.failure("未找到原图。刷新本页后重试。")
                return
            }
            switch destination {
            case .file:
                pageExport = source
                isExportingPageFile = true
            #if os(iOS)
            case .share:
                pageShare = source
            case .photos:
                await ReaderPagePhotos.save(source)
            #endif
            }
        }
    }

    private func pageImage(index: Int) -> some View {
        Group {
            if !vm.errorPages.contains(index), let cachedImage = vm.image(at: index) {
                #if os(iOS)
                SwiftUIZoomableImage(
                    image: cachedImage,
                    isFullPage: true,
                    pageIndex: index,
                    onSingleTap: { location, viewSize in
                        handleTapZone(location: location, viewSize: viewSize)
                    },
                    onZoomChanged: { zoomed in
                        if zoomed { zoomedSinglePages.insert(index) }
                        else { zoomedSinglePages.remove(index) }
                    }
                )
                // 单页菜单（对齐 Android GalleryActivity.showPageDialog）。
                // 此前一项都没有：一页加载坏了只能退出重进，想留一张也没出口。
                .contextMenu {
                    pageMenu(index: index)
                }
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
                .contextMenu { pageMenu(index: index) }
                #endif
            } else {
                pageLoadingIndicator(for: [index], active: index == vm.currentPage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task(id: "\(vm.imageURLs[index] ?? "")_\(vm.retryGeneration[index, default: 0])") {
                        await vm.superviseLoading(of: index)
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
        let guidance = ReaderGestureGuidance(direction: readingDirection)
        #if os(macOS)
        let input: ReaderGestureGuidance.Input = .pointer
        #else
        let input: ReaderGestureGuidance.Input = .touch
        #endif
        let motionTitle = guidance.motionTitle(for: input)

        return ZStack {
            Color.black.opacity(0.75)
                .ignoresSafeArea()

            // 左侧区域标注
            VStack(spacing: 4) {
                Image(systemName: readingDirection == .rightToLeft ? "arrow.right" : "arrow.left")
                    .font(.title2)
                Text(LocalizedStringKey(guidance.leftPageTitle))
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
                if guidance.showsDoubleTapZoom(for: input) {
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
            }
            .foregroundStyle(.white)
            .position(x: w / 2, y: h / 2)

            // 右侧区域标注
            VStack(spacing: 4) {
                Image(systemName: readingDirection == .rightToLeft ? "arrow.left" : "arrow.right")
                    .font(.title2)
                Text(LocalizedStringKey(guidance.rightPageTitle))
                    .font(.caption.bold())
            }
            .foregroundStyle(.white)
            .position(x: w - sideW / 2, y: h / 2)

            // 上方死区标注
            Text("此区单击无操作")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
                .position(x: w / 2, y: deadH / 2)

            // 下方死区标注
            Text("此区单击无操作")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
                .position(x: w / 2, y: h - deadH / 2)

            // 当前阅读模式的主要移动方式
            VStack(spacing: 4) {
                Image(systemName: "hand.draw")
                    .font(.title3)
                Text(LocalizedStringKey(motionTitle))
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
                .padding(.bottom, 24)
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
    private var immersiveOverlay: some View {
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
        // 两枚玻璃胶囊而非一条通栏工具栏：阅读器的主体是图，
        // 通栏会在图上压出一条硬边，胶囊只占它需要的宽度。
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Button(action: closeReader) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(EhReaderChrome.label)
                }
                .accessibilityLabel("返回")
                .accessibilityIdentifier("reader-close")

                if let title = readerTitle {
                    Text(title)
                        .font(EhFont.caption)
                        .foregroundStyle(EhReaderChrome.label)
                        .lineLimit(1)
                        .frame(maxWidth: 150, alignment: .leading)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .ehReaderGlass(cornerRadius: 19)

            Spacer(minLength: 8)

            // 双页与阅读方向只在底栏出现一次。
            // 此前顶栏和底栏各有一份，同一个开关在屏幕上有两个位置、
            // 两种样式，按哪个都行——这不是「快捷方式」，是重复。
            HStack(spacing: 14) {
                Button { showPageGrid = true } label: {
                    Image(systemName: "square.grid.2x2")
                        .foregroundStyle(EhReaderChrome.label)
                }
                .accessibilityLabel("页面目录")
                .accessibilityIdentifier("reader-pages")

                // 齿轮。这里原来画的是 sun.max，点开却是整个阅读设置面板——
                // 图标承诺的是亮度，打开的是设置。
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .foregroundStyle(EhReaderChrome.label)
                }
                .accessibilityLabel("阅读设置")
                .accessibilityIdentifier("reader-settings")
            }
            .font(.system(size: 15, weight: .medium))
            .padding(.horizontal, 14)
            .frame(height: 38)
            .ehReaderGlass(cornerRadius: 19)
        }
        .padding(.horizontal, EhSpacing.page)
        .padding(.top, 8)
    }

    /// Prefer the detail title; direct Browse entry can use its list title.
    private var readerTitle: String? {
        let info = GalleryCache.shared.getDetail(gid: gid)?.info ?? galleryHint
        let title = info?.suitableTitle(preferJpn: AppSettings.shared.showJpnTitle)
        return title.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// 底部页码文案 —— 双页时显示成 "12–13"
    private var pageIndicatorText: String {
        if vm.isDoublePageEnabled, let idx = vm.currentSpreadIndex, idx < vm.spreads.count {
            let spread = vm.spreads[idx]
            if let sec = spread.secondaryPage {
                return "\(spread.primaryPage + 1)–\(sec + 1)"
            }
            return "\(spread.primaryPage + 1)"
        }
        return "\(displayedPage + 1)"
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            HStack(spacing: EhSpacing.row) {
                Text(pageIndicatorText)
                    .font(EhFont.mono(13, weight: .semibold))
                    .foregroundStyle(EhReaderChrome.label)
                    .frame(minWidth: 44, alignment: .leading)

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
                .tint(EhColor.accentFill)

                Text("\(vm.totalPages)")
                    .font(EhFont.mono(13))
                    .foregroundStyle(EhReaderChrome.tertiaryLabel)
            }

            // 四个模式块：双页 / 方向 / 自动翻页 / 护眼。
            // 这四项在阅读中随时可能要改，此前分散在设置面板与顶栏菜单里，
            // 每改一次都要中断阅读。
            HStack(spacing: 6) {
                modeBlock("双页", isOn: vm.isDoublePageEnabled) {
                    vm.toggleDoublePage()
                }
                modeBlock(ReaderGestureGuidance(direction: readingDirection).directionTitle,
                          isOn: readingDirection == .rightToLeft) {
                    readingDirection = readingDirection == .rightToLeft ? .leftToRight : .rightToLeft
                    AppSettings.shared.readingDirection = readingDirection.rawValue
                }
                modeBlock("自动", isOn: autoPageEnabled) { toggleAutoPage() }
                // 护眼滤镜留在设置面板里。它是「设一次就不动」的偏好，
                // 不该和翻页方向这类阅读中随时要改的东西抢同一排位置。
            }
        }
        .padding(EhSpacing.page)
        .ehReaderGlass(cornerRadius: EhRadius.card)
        .padding(.horizontal, EhSpacing.page)
        .padding(.bottom, 8)
    }

    private func modeBlock(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isOn ? EhColor.onAccentFill : EhReaderChrome.label)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background {
                    RoundedRectangle(cornerRadius: EhRadius.smallControl, style: .continuous)
                        .fill(isOn ? EhColor.accentFill : EhReaderChrome.fill)
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: - HUD Overlay

    /// 底部信息条：时钟 · 页码 · 电量，同一行。
    ///
    /// 此前时钟和电量各自贴在屏幕最底边，而页码在另一个浮层里居中——三者
    /// 压在同一条边上互相挤，还盖住 Home Indicator。现在覆盖层
    /// 跟随当前窗口安全区，比分别计算窗口边距稳妥。
    ///
    /// 翻页/跳页按钮已经删掉：它悬在画面正中偏下，遮挡太重，而翻页本来就能
    /// 点两侧或滑动，跳页在工具栏的滑杆和目录网格里都有。这里只留页码。
    private var hudOverlay: some View {
        VStack {
            Spacer()
            HStack(spacing: EhSpacing.row) {
                if AppSettings.shared.showClock {
                    Text(currentTime, style: .time)
                        .font(EhFont.mono(11))
                        .foregroundStyle(.white.opacity(0.55))
                }

                Spacer(minLength: 8)

                if vm.totalPages > 0 {
                    Text("\(displayedPage + 1) / \(vm.totalPages)")
                        .font(EhFont.mono(12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.35), in: Capsule())
                }

                Spacer(minLength: 8)

                if AppSettings.shared.showBattery {
                    batteryView
                }
            }
            .padding(.horizontal, EhSpacing.page)
            .padding(.bottom, 10)
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
                    .accessibilityIdentifier("reader-picker-page-scaling")
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
                    .accessibilityIdentifier("reader-picker-start-position")
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

                // Android dialog_gallery_menu.xml 里有而我们缺的三项：
                // 屏幕方向、音量键翻页、护眼滤镜。前两项一直没有入口，
                // 护眼滤镜的开关此前只在底栏那排模式块里。
                Section("屏幕方向") {
                    Picker("方向", selection: Binding(
                        get: { AppSettings.shared.screenRotation },
                        set: {
                            AppSettings.shared.screenRotation = $0
                            applyScreenRotation($0)
                        }
                    )) {
                        Text("跟随系统").tag(0)
                        Text("锁定竖屏").tag(1)
                        Text("锁定横屏").tag(2)
                    }
                    .pickerStyle(.segmented)
                }

                Section("护眼滤镜") {
                    Toggle("启用", isOn: Binding(
                        get: { AppSettings.shared.colorFilter },
                        set: { AppSettings.shared.colorFilter = $0 }
                    ))
                    if AppSettings.shared.colorFilter {
                        // 存的是 ARGB，这里只让调不透明度——色相固定为暖黄，
                        // 和 Android 默认的 0x20000000 语义一致
                        HStack {
                            Text("强度").font(EhFont.caption)
                            Slider(value: Binding(
                                get: {
                                    Double((AppSettings.shared.colorFilterColor >> 24) & 0xFF)
                                },
                                set: { alpha in
                                    let rgb = AppSettings.shared.colorFilterColor & 0x00FFFFFF
                                    AppSettings.shared.colorFilterColor = (Int(alpha) << 24) | rgb
                                }
                            ), in: 0...128)
                        }
                    }
                }

                Section("行为") {
                    #if os(iOS)
                    Toggle("音量键翻页", isOn: Binding(
                        get: { AppSettings.shared.volumePage },
                        set: { AppSettings.shared.volumePage = $0 }
                    ))
                    if AppSettings.shared.volumePage {
                        Toggle("反转音量键方向", isOn: Binding(
                            get: { AppSettings.shared.reverseVolumePage },
                            set: { AppSettings.shared.reverseVolumePage = $0 }
                        ))
                    }
                    #endif
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
                        in: AppSettings.autoPageIntervalRange
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
/// 1. 未放大时保留当前的点按和双击处理；放大后由同一组互斥手势区分平移、双击、单击。
/// 2. 双指缩放 (MagnifyGesture): 始终以 .simultaneousGesture 挂载，不阻塞父 ScrollView
/// 3. 拖动平移 (DragGesture): 通过 overlay + allowsHitTesting(isZoomed) 控制
///    - 1x 时 overlay 不接收触摸 → 父 ScrollView 自由滚动/翻页
///    - >1x 时 overlay 拦截触摸 → 拖动平移图片，阻止父 ScrollView 滚动
///    - overlay 上平移比点按优先且互斥；缩放仍可同时识别
#if os(iOS)
private struct SwiftUIZoomableImage: View {
    let image: PlatformImage
    /// 全屏页模式 (翻页阅读器) vs 流式模式 (垂直滚动)
    var isFullPage: Bool = false
    let pageIndex: Int
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
            .onAppear { if isZoomed { onZoomChanged?(true) } }
            .onDisappear { if isZoomed { onZoomChanged?(false) } }
            #if EH_OFFLINE_UI_FIXTURE && targetEnvironment(simulator)
            .overlay(alignment: .topLeading) {
                if EhOfflineUIFixture.readerGestureFixture {
                    Text(isZoomed ? "Zoomed" : "Fit")
                        .accessibilityIdentifier("reader-zoom-page-\(pageIndex + 1)")
                        .allowsHitTesting(false)
                }
            }
            #endif
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
                    // A small drag can satisfy the tap recognizer's movement
                    // tolerance. Once panning wins, never also run a tap zone.
                    .gesture(
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
                                    offset = lastOffset
                                } else {
                                    lastOffset = offset
                                }
                            }
                            .exclusively(before: zoomedTapGesture)
                    )
                    .simultaneousGesture(magnifyGesture)
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

    private var zoomedTapGesture: some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { _ in
                pendingSingleTap?.cancel()
                pendingSingleTap = nil
                lastTapTime = .distantPast
                toggleDoubleTapZoom()
            }
            .exclusively(before:
                SpatialTapGesture(count: 1)
                    .onEnded { value in onSingleTap?(value.location, viewSize) }
            )
    }

    private func toggleDoubleTapZoom() {
        withAnimation(.spring(duration: 0.3)) {
            if scale < 1.5 {
                scale = 2.0
                lastScale = 2.0
                onZoomChanged?(true)
            } else {
                resetZoom()
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
            toggleDoubleTapZoom()
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

// MARK: - 页面网格（目录）

/// 跳页网格。对齐 Android 阅读器里的页码目录：
/// 底部那条 slider 在两百页的本子上根本定位不到具体页，
/// 而「回到第 87 页」是阅读时的常见需求。
struct ReaderPageGrid: View {
    let total: Int
    let current: Int
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 54), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(0..<max(total, 0), id: \.self) { index in
                            Button {
                                onSelect(index)
                            } label: {
                                Text("\(index + 1)")
                                    .font(EhFont.mono(15, weight: index == current ? .bold : .regular))
                                    .foregroundStyle(index == current
                                                     ? EhColor.onAccentFill : EhColor.label)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                                    .background {
                                        RoundedRectangle(cornerRadius: EhRadius.smallControl,
                                                         style: .continuous)
                                            .fill(index == current ? EhColor.accentFill : EhColor.fill)
                                    }
                            }
                            .buttonStyle(.plain)
                            .id(index)
                        }
                    }
                    .padding(EhSpacing.page)
                }
                .onAppear {
                    // 打开就停在当前页上，而不是从第 1 页开始滚
                    proxy.scrollTo(current, anchor: .center)
                }
            }
            .background(EhColor.background)
            .navigationTitle("跳转到第 \(current + 1) 页")
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
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }
}
