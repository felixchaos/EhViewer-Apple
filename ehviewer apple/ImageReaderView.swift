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
    let isDownloaded: Bool
    /// 初始页面 (0-based, 对齐 Android GalleryActivityEvent.page)
    let initialPage: Int?

    @State private var vm: ReaderViewModel
    @State private var showOverlay = true
    @State private var showSettings = false
    @State private var hasAppliedInitialPage = false
    @State private var isZoomed = false
    @State private var showTutorial = false

    // 从设置读取
    @State private var readingDirection: ReadingDirection = .rightToLeft
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
    @State private var verticalZoomScale: CGFloat = 1.0
    @State private var verticalBaseScale: CGFloat = 1.0

    @Environment(\.dismiss) private var dismiss

    // 点击区域比例
    private let tapZoneRatio: CGFloat = 0.25
    /// 纵向边缘死区比例 (上下各 15%)
    private let tapZoneVerticalDeadZone: CGFloat = 0.15

    /// 显式初始化器
    init(
        gid: Int64,
        token: String,
        pages: Int,
        previewSet: PreviewSet? = nil,
        isDownloaded: Bool = false,
        initialPage: Int? = nil
    ) {
        self.gid = gid
        self.token = token
        self.pages = pages
        self.previewSet = previewSet
        self.isDownloaded = isDownloaded
        self.initialPage = initialPage

        let viewModel = ReaderViewModel()
        viewModel.gid = gid
        viewModel.token = token
        viewModel.totalPages = pages
        viewModel.isDownloaded = isDownloaded

        if let initial = initialPage, initial >= 0 && initial < pages {
            viewModel.currentPage = initial
        } else {
            let key = "reading_progress_\(gid)"
            if let saved = UserDefaults.standard.object(forKey: key) as? Int, pages > 0 {
                viewModel.currentPage = min(saved, max(0, pages - 1))
            }
        }

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

                // 新手教程
                if showTutorial {
                    readerTutorialOverlay(geometry: geometry)
                }
            }
            .onAppear {
                // 检测宽屏 → 双页模式
                vm.updateLayout(screenWidth: geometry.size.width)
                vm.computeSpreads()
            }
            .onChange(of: geometry.size.width) { _, newWidth in
                vm.updateLayout(screenWidth: newWidth)
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
        }
        .sheet(isPresented: $showSettings) {
            ReaderSettingsSheet(
                readingDirection: $readingDirection,
                scaleMode: $scaleMode,
                startPosition: $startPosition,
                autoPageEnabled: $autoPageEnabled
            )
        }
        // 键盘事件 (macOS / iPad 键盘)
        .onKeyPress(.leftArrow) {
            handleKeyNavigation(forward: readingDirection != .rightToLeft)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            handleKeyNavigation(forward: readingDirection == .rightToLeft)
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
            if readingDirection == .topToBottom { return .ignored }
            goToPreviousPage()
            return .handled
        }
        .onKeyPress(.downArrow) {
            if readingDirection == .topToBottom { return .ignored }
            goToNextPage()
            return .handled
        }
        #if os(macOS)
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
        #endif
        #if os(iOS)
        // 边缘侧滑返回 (fullScreenCover 无 UINavigationController，需自行添加手势)
        .overlay {
            EdgeSwipeDismissView { dismiss() }
                .allowsHitTesting(true)
        }
        #endif
    }

    // MARK: - Ambient Background (模糊氛围背景)

    /// 主色调氛围背景 — 使用当前页的 CIAreaAverage 提取色填充未覆盖区域
    @ViewBuilder
    private var ambientBackground: some View {
        if let color = vm.dominantColors[vm.currentPage] {
            color
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.5), value: vm.currentPage)
        } else {
            Color.black.ignoresSafeArea()
        }
    }

    // MARK: - Setup

    private func setupReader() {
        readingDirection = ReadingDirection(rawValue: AppSettings.shared.readingDirection) ?? .rightToLeft
        scaleMode = ScaleMode(rawValue: AppSettings.shared.pageScaling) ?? .fit
        startPosition = StartPosition(rawValue: AppSettings.shared.startPosition) ?? .topRight

        #if os(iOS)
        if AppSettings.shared.keepScreenOn {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        UIDevice.current.isBatteryMonitoringEnabled = true
        if AppSettings.shared.customScreenLightness {
            setScreenBrightness(CGFloat(AppSettings.shared.screenLightness) / 100.0)
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
        #endif
        timeTimer?.invalidate()
        autoPageTask?.cancel()
        saveReadingProgress()
    }

    private func initializeReader() async {
        vm.setupLocalGallery()

        if let ps = previewSet {
            vm.extractPTokens(from: ps)
        }

        if vm.totalPages == 0 {
            await vm.fetchGalleryInfo()
        }

        // 获取页数后重算 spreads
        vm.computeSpreads()

        if let initial = initialPage, initial >= 0, initial < vm.totalPages {
            vm.currentPage = initial
        } else if initialPage == nil {
            let key = "reading_progress_\(gid)"
            if let saved = UserDefaults.standard.object(forKey: key) as? Int, vm.totalPages > 0 {
                vm.currentPage = min(saved, max(0, vm.totalPages - 1))
            }
        }

        await vm.loadCurrentPage()
    }

    // MARK: - Progress Persistence

    private func saveReadingProgress() {
        let key = "reading_progress_\(gid)"
        UserDefaults.standard.set(vm.currentPage, forKey: key)
    }

    // MARK: - Navigation

    private func handleKeyNavigation(forward: Bool) {
        if forward { goToNextPage() } else { goToPreviousPage() }
    }

    private func goToNextPage() {
        if vm.isDoublePageEnabled {
            // 双页模式: 按 spread 翻页
            let nextSpread = vm.currentSpreadIndex + 1
            guard nextSpread < vm.spreads.count else { return }
            let nextPage = vm.pageForSpread(nextSpread)
            withAnimation(.easeInOut(duration: 0.15)) {
                vm.currentPage = nextPage
                vm.currentSpreadIndex = nextSpread
            }
            Task { await vm.onPageChange(nextPage) }
        } else {
            guard vm.currentPage < vm.totalPages - 1 else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                vm.currentPage += 1
            }
            Task { await vm.onPageChange(vm.currentPage) }
        }
    }

    private func goToPreviousPage() {
        if vm.isDoublePageEnabled {
            let prevSpread = vm.currentSpreadIndex - 1
            guard prevSpread >= 0 else { return }
            let prevPage = vm.pageForSpread(prevSpread)
            withAnimation(.easeInOut(duration: 0.15)) {
                vm.currentPage = prevPage
                vm.currentSpreadIndex = prevSpread
            }
            Task { await vm.onPageChange(prevPage) }
        } else {
            guard vm.currentPage > 0 else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                vm.currentPage -= 1
            }
            Task { await vm.onPageChange(vm.currentPage) }
        }
    }

    private func goToPage(_ page: Int) {
        let target = max(0, min(vm.totalPages - 1, page))
        withAnimation(.easeInOut(duration: 0.15)) {
            vm.currentPage = target
        }
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

    private func horizontalPageReader(geometry: GeometryProxy) -> some View {
        Group {
            if vm.isDoublePageEnabled {
                // 双页模式: 按 spread 遍历，每个 spread 显示合成图
                TabView(selection: $vm.currentSpreadIndex) {
                    ForEach(vm.spreads) { spread in
                        spreadPageView(spread: spread)
                            .tag(spread.id)
                    }
                }
                #if os(iOS)
                .tabViewStyle(.page(indexDisplayMode: .never))
                .environment(\.layoutDirection, readingDirection == .rightToLeft ? .rightToLeft : .leftToRight)
                #endif
                .onChange(of: vm.currentSpreadIndex) { _, newIdx in
                    let page = vm.pageForSpread(newIdx)
                    if vm.currentPage != page {
                        vm.currentPage = page
                    }
                    saveReadingProgress()
                    Task { await vm.onPageChange(page) }
                }
            } else {
                // 单页模式
                TabView(selection: $vm.currentPage) {
                    ForEach(0..<vm.totalPages, id: \.self) { idx in
                        pageImage(index: idx)
                            .tag(idx)
                    }
                }
                #if os(iOS)
                .tabViewStyle(.page(indexDisplayMode: .never))
                .environment(\.layoutDirection, readingDirection == .rightToLeft ? .rightToLeft : .leftToRight)
                #endif
                .onChange(of: vm.currentPage) { _, newPage in
                    saveReadingProgress()
                    Task { await vm.onPageChange(newPage) }
                }
            }
        }
    }

    // MARK: - macOS Page Reader

    #if os(macOS)
    private func macOSPageReader(geometry: GeometryProxy) -> some View {
        ZStack {
            if vm.isDoublePageEnabled {
                let spread = vm.currentSpreadIndex < vm.spreads.count
                    ? vm.spreads[vm.currentSpreadIndex]
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
        } else if let progress = vm.downloadProgress[index], progress > 0 {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.3), lineWidth: 3)
                    .frame(width: 48, height: 48)
                Circle()
                    .trim(from: 0, to: progress)
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

    private func verticalScrollReader(geometry: GeometryProxy) -> some View {
        let contentWidth = geometry.size.width * verticalZoomScale

        return ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal], showsIndicators: false) {
                LazyVStack(spacing: AppSettings.shared.showPageInterval ? 8 : 0) {
                    ForEach(0..<vm.totalPages, id: \.self) { idx in
                        verticalPageImage(index: idx)
                            .frame(width: contentWidth)
                            .id(idx)
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: PageOffsetPreferenceKey.self,
                                        value: [idx: geo.frame(in: .named("readerScroll")).minY]
                                    )
                                }
                            )
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture().onEnded {
                    if Date().timeIntervalSince(lastScrollChangeTime) < 0.3 { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showOverlay.toggle()
                    }
                }
            )
            #if os(iOS)
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        verticalZoomScale = max(1.0, min(3.0, verticalBaseScale * value.magnification))
                    }
                    .onEnded { value in
                        verticalBaseScale = verticalZoomScale
                        if verticalZoomScale < 1.1 {
                            withAnimation(.spring()) {
                                verticalZoomScale = 1.0
                                verticalBaseScale = 1.0
                            }
                        }
                    }
            )
            #endif
            .coordinateSpace(name: "readerScroll")
            .onAppear {
                if vm.currentPage > 0 && !hasAppliedInitialScroll {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            proxy.scrollTo(vm.currentPage, anchor: .top)
                        }
                        hasAppliedInitialScroll = true
                    }
                }
            }
            .onChange(of: vm.currentPage) { _, newPage in
                if !isUpdatingFromScroll {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        proxy.scrollTo(newPage, anchor: .top)
                    }
                    saveReadingProgress()
                }
            }
            .onPreferenceChange(PageOffsetPreferenceKey.self) { offsets in
                guard !offsets.isEmpty else { return }
                let nearest = offsets.min { abs($0.value) < abs($1.value) }
                guard let current = nearest?.key, current != vm.currentPage else { return }
                isUpdatingFromScroll = true
                vm.currentPage = current
                lastScrollChangeTime = Date()
                saveReadingProgress()
                DispatchQueue.main.async {
                    self.isUpdatingFromScroll = false
                }
            }
        }
    }

    /// 垂直滚动模式的页面图片 — 宽度撑满、高度按比例
    @ViewBuilder
    private func verticalPageImage(index: Int) -> some View {
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
            .frame(height: 300)
        } else if let cachedImage = vm.cachedImages[index] {
            let imgSize = cachedImage.size
            let ratio = imgSize.width > 0 ? imgSize.height / imgSize.width : 1.0
            nativeImage(cachedImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .aspectRatio(1.0 / ratio, contentMode: .fit)
        } else if vm.imageURLs[index] != nil {
            VStack(spacing: 8) {
                if let progress = vm.downloadProgress[index], progress > 0 {
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.3), lineWidth: 3)
                            .frame(width: 48, height: 48)
                        Circle()
                            .trim(from: 0, to: progress)
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
            .frame(height: 300)
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
            .frame(height: 300)
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
            } else if vm.imageURLs[index] != nil {
                VStack(spacing: 8) {
                    if let progress = vm.downloadProgress[index], progress > 0 {
                        ZStack {
                            Circle()
                                .stroke(Color.white.opacity(0.3), lineWidth: 3)
                                .frame(width: 48, height: 48)
                            Circle()
                                .trim(from: 0, to: progress)
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
            if readingDirection == .rightToLeft {
                goToNextPage()
            } else if readingDirection == .leftToRight {
                goToPreviousPage()
            } else {
                withAnimation(.easeInOut(duration: 0.2)) { showOverlay.toggle() }
            }
        } else if relX > (1 - tapZoneRatio) {
            if readingDirection == .rightToLeft {
                goToPreviousPage()
            } else if readingDirection == .leftToRight {
                goToNextPage()
            } else {
                withAnimation(.easeInOut(duration: 0.2)) { showOverlay.toggle() }
            }
        } else {
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

            // 页码显示 (双页模式标注 spread)
            Group {
                if vm.isDoublePageEnabled, vm.currentSpreadIndex < vm.spreads.count {
                    let spread = vm.spreads[vm.currentSpreadIndex]
                    if let sec = spread.secondaryPage {
                        Text("\(spread.primaryPage + 1)-\(sec + 1) / \(vm.totalPages)")
                    } else {
                        Text("\(spread.primaryPage + 1) / \(vm.totalPages)")
                    }
                } else {
                    Text("\(vm.currentPage + 1) / \(vm.totalPages)")
                }
            }
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())

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

                Slider(
                    value: Binding(
                        get: { Double(vm.currentPage) },
                        set: { vm.currentPage = Int($0) }
                    ),
                    in: 0...Double(max(vm.totalPages - 1, 1)),
                    step: 1
                ) { isEditing in
                    if !isEditing {
                        if vm.isDoublePageEnabled { vm.syncSpreadIndex() }
                        Task { await vm.onPageChange(vm.currentPage) }
                    }
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

            // 页码
            HStack {
                Text("1")
                Spacer()
                Text("\(vm.currentPage + 1)")
                    .fontWeight(.bold)
                Spacer()
                Text("\(vm.totalPages)")
            }
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 20)

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

                if AppSettings.shared.showProgress {
                    Text("\(vm.currentPage + 1)/\(vm.totalPages)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                }

                Spacer()

                if AppSettings.shared.showBattery {
                    batteryView
                }
            }
            .padding(.horizontal, max(20, geometry.safeAreaInsets.leading + 12))
            .padding(.bottom, max(12, geometry.safeAreaInsets.bottom + 4))
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

// MARK: - Page Offset Preference Key

private struct PageOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]

    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// MARK: - Edge Swipe Dismiss (iOS fullScreenCover 边缘侧滑返回)

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
