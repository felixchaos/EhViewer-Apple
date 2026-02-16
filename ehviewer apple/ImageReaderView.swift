//
//  ImageReaderView.swift
//  ehviewer apple
//
//  完整图片阅读器 — 对齐 Android GalleryActivity
//  支持: 翻页/滚动模式、音量键翻页、屏幕常亮、亮度控制、时钟/电量/进度显示
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

// MARK: - 阅读方向
enum ReadingDirection: Int, CaseIterable {
    case leftToRight = 0  // 从左到右
    case rightToLeft = 1  // 从右到左 (漫画常用)
    case topToBottom = 2  // 从上到下 (条漫)

    var label: String {
        switch self {
        case .leftToRight: return "从左到右"
        case .rightToLeft: return "从右到左"
        case .topToBottom: return "从上到下"
        }
    }

    var icon: String {
        switch self {
        case .leftToRight: return "arrow.right"
        case .rightToLeft: return "arrow.left"
        case .topToBottom: return "arrow.down"
        }
    }
}

// MARK: - 缩放模式
enum ScaleMode: Int, CaseIterable {
    case origin = 0      // 原始大小
    case fitWidth = 1    // 适应宽度
    case fitHeight = 2   // 适应高度
    case fit = 3         // 适应屏幕
    case fixed = 4       // 固定缩放

    var label: String {
        switch self {
        case .origin: return "原始大小"
        case .fitWidth: return "适应宽度"
        case .fitHeight: return "适应高度"
        case .fit: return "适应屏幕"
        case .fixed: return "固定缩放"
        }
    }
}

// MARK: - 起始位置
enum StartPosition: Int, CaseIterable {
    case topLeft = 0
    case topRight = 1
    case bottomLeft = 2
    case bottomRight = 3
    case center = 4

    var label: String {
        switch self {
        case .topLeft: return "左上"
        case .topRight: return "右上"
        case .bottomLeft: return "左下"
        case .bottomRight: return "右下"
        case .center: return "居中"
        }
    }
}

// MARK: - ImageReaderView

struct ImageReaderView: View {
    let gid: Int64
    let token: String
    let pages: Int
    let previewSet: PreviewSet?
    let isDownloaded: Bool
    /// 初始页面 (0-based, 对齐 Android GalleryActivityEvent.page)
    let initialPage: Int?
    
    @State private var vm: ImageReaderViewModel
    @State private var showOverlay = true
    @State private var showSettings = false
    @State private var hasAppliedInitialPage = false  // TabView 初始页修正标志
    @State private var isZoomed = false  // 当前页面是否处于放大状态 (防止缩放时手势泄漏到 TabView)
    @State private var showTutorial = false  // 新手教程

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

    @State private var isUpdatingFromScroll = false
    @State private var hasAppliedInitialScroll = false
    @State private var lastScrollChangeTime: Date = .distantPast
    @State private var verticalZoomScale: CGFloat = 1.0
    @State private var verticalBaseScale: CGFloat = 1.0

    @Environment(\.dismiss) private var dismiss

    // 点击区域比例
    private let tapZoneRatio: CGFloat = 0.25
    /// 纵向边缘死区比例 (上下各 15%，对齐 Android 手势区域)
    private let tapZoneVerticalDeadZone: CGFloat = 0.15
    
    /// 显式初始化器 (解决 Swift 默认参数在链接时的问题)
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
        
        // 在 init 中创建 ViewModel 并设置初始状态 (对齐 Android GalleryActivity.onCreate 中设置 startPage)
        let viewModel = ImageReaderViewModel()
        viewModel.gid = gid
        viewModel.token = token
        viewModel.totalPages = pages
        viewModel.isDownloaded = isDownloaded
        
        // 优先使用传入的 initialPage，否则尝试恢复阅读进度 (对齐 Android: mPage >= 0 ? mPage : getStartPage())
        if let initial = initialPage, initial >= 0 && initial < pages {
            viewModel.currentPage = initial
        } else {
            // 恢复上次阅读进度
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
                Color.black.ignoresSafeArea()

                // 主内容
                if vm.totalPages == 0 {
                    ProgressView()
                        .tint(.white)
                } else if readingDirection == .topToBottom {
                    verticalScrollReader(geometry: geometry)
                } else {
                    #if os(macOS)
                    macOSPageReader
                    #else
                    horizontalPageReader
                    #endif
                }

                // 点击区域 — 已移至 ZoomableImageView 内部统一处理
                // 对齐 Android GalleryView: 单击/双击互斥，由 UIKit 手势识别器管理

                // 覆盖层
                if showOverlay {
                    overlayContent(geometry: geometry)
                }

                // HUD 显示 (时钟/电量/进度)
                if !showOverlay {
                    hudOverlay(geometry: geometry)
                }

                // 新手教程 (首次使用阅读器时显示)
                if showTutorial {
                    readerTutorialOverlay(geometry: geometry)
                }
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
            if readingDirection == .topToBottom { return .ignored }  // 上下滚动模式由 ScrollView 处理
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
    }

    // MARK: - Setup

    private func setupReader() {
        // 加载设置
        readingDirection = ReadingDirection(rawValue: AppSettings.shared.readingDirection) ?? .rightToLeft
        scaleMode = ScaleMode(rawValue: AppSettings.shared.pageScaling) ?? .fit
        startPosition = StartPosition(rawValue: AppSettings.shared.startPosition) ?? .topRight

        // 屏幕常亮
        #if os(iOS)
        if AppSettings.shared.keepScreenOn {
            UIApplication.shared.isIdleTimerDisabled = true
        }

        // 启用电量监控 (否则 UIDevice.current.batteryLevel 返回 -1.0)
        UIDevice.current.isBatteryMonitoringEnabled = true

        // 自定义亮度
        if AppSettings.shared.customScreenLightness {
            setScreenBrightness(CGFloat(AppSettings.shared.screenLightness) / 100.0)
        }
        #endif

        // 时间更新
        timeTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            currentTime = Date()
        }
        
        // TabView 初始页修正: 仅在翻页模式需要 (对齐 Android GalleryView.setStartPage())
        if readingDirection != .topToBottom && !hasAppliedInitialPage {
            let targetPage = vm.currentPage
            if targetPage > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self.vm.currentPage = targetPage
                }
            }
            hasAppliedInitialPage = true
        }

        // 新手教程: 首次使用阅读器时显示 (对齐 Android GalleryActivity 首次提示)
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

        // 保存阅读进度
        saveReadingProgress()
    }

    private func initializeReader() async {
        // ViewModel 的基础属性已在 init 中设置
        vm.setupLocalGallery()

        if let ps = previewSet {
            vm.extractPTokens(from: ps)
        }

        // 如果页数未知，从服务器获取
        if vm.totalPages == 0 {
            await vm.fetchGalleryInfo()
        }

        // 获取页数后重新检查初始页/阅读进度
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
        if forward {
            goToNextPage()
        } else {
            goToPreviousPage()
        }
    }

    private func goToNextPage() {
        if vm.currentPage < vm.totalPages - 1 {
            withAnimation(.easeInOut(duration: 0.15)) {
                vm.currentPage += 1
            }
            Task { await vm.onPageChange(vm.currentPage) }
        }
    }

    private func goToPreviousPage() {
        if vm.currentPage > 0 {
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

    // MARK: - Views

    private var horizontalPageReader: some View {
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
            // 对齐 Android GalleryActivity.onPageChange: 保存进度 + 加载页面
            saveReadingProgress()
            Task { await vm.onPageChange(newPage) }
        }
    }

    #if os(macOS)
    /// macOS 翻页阅读器 — 单页显示，键盘/鼠标滚轮翻页 (桌面图片查看器模式)
    /// TabView.page 样式仅 iOS 可用，macOS 使用单页切换方式
    private var macOSPageReader: some View {
        ZStack {
            pageImage(index: vm.currentPage)

            // 鼠标滚轮翻页 (透明层拦截滚轮事件)
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
                    // 滚动后短时间内忽略点击，避免滚动时意外触发 overlay
                    if Date().timeIntervalSince(lastScrollChangeTime) > 0.3 {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showOverlay.toggle()
                        }
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
                // 对齐 Android: 初始滚动到保存的阅读位置 (无动画，避免从顶部滚动)
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
                    // 对齐 Android: 保存进度
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

    /// 垂直滚动模式的页面图片 — 宽度撑满、高度按比例 (对齐 Android ScrollLayoutManager.obtainPage)
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
            // 对齐 Android ScrollLayoutManager: 宽度 = 屏幕宽, 高度 = 按比例
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
                // 使用 ZoomableImageView 实现每页独立缩放 (对齐 Android GalleryView 缩放逻辑)
                // 所有点击操作统一在 ZoomableImageView 内部处理:
                //   - 双击: 放大/复原 (由 UIKit 双击手势处理)
                //   - 单击: 区域判断 (左=翻页/右=翻页/中=工具栏，由 onSingleTap 回调处理)
                // 对齐 Android GalleryView.onSingleTapConfirmed + onDoubleTap
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
                // URL 已获取，正在下载图片数据 — 显示下载百分比进度
                VStack(spacing: 8) {
                    if let progress = vm.downloadProgress[index], progress > 0 {
                        // 有进度: 显示圆环 + 百分比
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
                // 使用 retryGeneration 确保重试时即使 URL 相同也能重新触发
                .task(id: "\(vm.imageURLs[index] ?? "")_\(vm.retryGeneration[index, default: 0])") {
                    await vm.downloadImageData(index)
                }
            } else {
                // 加载中：获取图片 URL (对齐 Android onPageDownload 进度显示)
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

    // MARK: - Tap Zone Detection (对齐 Android GalleryView 手势区域: 2D 网格布局)
    // 上下边缘 15% 为死区，左右 25% 为翻页区域，中心区域为菜单切换区域
    // 所有点击统一由 ZoomableImageView 的 UIKit 手势识别器处理，
    // 确保单击和双击互斥 (require(toFail:))

    private func handleTapZone(location: CGPoint, viewSize: CGSize) {
        guard viewSize.width > 0 && viewSize.height > 0 else { return }

        let relX = location.x / viewSize.width
        let relY = location.y / viewSize.height

        // 上下 15% 为死区 — 不响应任何点击 (对齐 Android 手势区域)
        guard relY > tapZoneVerticalDeadZone && relY < (1 - tapZoneVerticalDeadZone) else {
            return
        }

        if relX < tapZoneRatio {
            // 左侧 25% 区域 — 翻页
            if readingDirection == .rightToLeft {
                goToNextPage()
            } else if readingDirection == .leftToRight {
                goToPreviousPage()
            } else {
                // topToBottom 模式: 中间点击 → 切换工具栏
                withAnimation(.easeInOut(duration: 0.2)) {
                    showOverlay.toggle()
                }
            }
        } else if relX > (1 - tapZoneRatio) {
            // 右侧 25% 区域 — 翻页
            if readingDirection == .rightToLeft {
                goToPreviousPage()
            } else if readingDirection == .leftToRight {
                goToNextPage()
            } else {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showOverlay.toggle()
                }
            }
        } else {
            // 中央区域 — 切换工具栏 (对齐 Android: 仅中心单击触发工具栏)
            withAnimation(.easeInOut(duration: 0.2)) {
                showOverlay.toggle()
            }
        }
    }

    // MARK: - Reader Tutorial Overlay (新手教程)
    // 对齐 Android: 首次使用阅读器时显示手势操作提示

    private func readerTutorialOverlay(geometry: GeometryProxy) -> some View {
        let w = geometry.size.width
        let h = geometry.size.height
        let sideW = w * tapZoneRatio
        let deadH = h * tapZoneVerticalDeadZone

        return ZStack {
            // 半透明背景
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

            // 区域分界线 (视觉参考)
            // 左侧分界
            Rectangle()
                .fill(.white.opacity(0.2))
                .frame(width: 1, height: h - deadH * 2)
                .position(x: sideW, y: h / 2)
            // 右侧分界
            Rectangle()
                .fill(.white.opacity(0.2))
                .frame(width: 1, height: h - deadH * 2)
                .position(x: w - sideW, y: h / 2)
            // 上死区分界
            Rectangle()
                .fill(.white.opacity(0.15))
                .frame(width: w, height: 1)
                .position(x: w / 2, y: deadH)
            // 下死区分界
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

    // MARK: - Overlay

    private func overlayContent(geometry: GeometryProxy) -> some View {
        VStack {
            topBar
            Spacer()
            bottomBar
        }
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

            // 页码显示
            Text("\(vm.currentPage + 1) / \(vm.totalPages)")
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
                Text(readingDirection == .rightToLeft ? "← 从右到左" : "从左到右 →")
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

                // 跳页滑块 - 对齐 Android ReversibleSeekBar
                // 使用直接绑定 vm.currentPage，通过 onChange 触发页面加载
                Slider(
                    value: Binding(
                        get: { Double(vm.currentPage) },
                        set: { vm.currentPage = Int($0) }
                    ),
                    in: 0...Double(max(vm.totalPages - 1, 1)),
                    step: 1
                ) { isEditing in
                    // 当用户停止拖动时，加载对应页面
                    // 对应 Android: onStopTrackingTouch
                    if !isEditing {
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

    // MARK: - HUD Overlay (时钟/电量/进度)

    private func hudOverlay(geometry: GeometryProxy) -> some View {
        VStack {
            Spacer()
            HStack {
                // 时钟
                if AppSettings.shared.showClock {
                    Text(currentTime, style: .time)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                }

                Spacer()

                // 进度
                if AppSettings.shared.showProgress {
                    Text("\(vm.currentPage + 1)/\(vm.totalPages)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                }

                Spacer()

                // 电量
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
        .presentationDetents([.large])  // 对齐 Android: 使用全高度 AlertDialog
        .presentationDragIndicator(.visible)
        #endif
    }
}

private struct PageOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]

    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// MARK: - ViewModel

@Observable
class ImageReaderViewModel {
    var currentPage = 0
    var totalPages = 0
    var gid: Int64 = 0
    var token = ""
    var isDownloaded = false
    var imageURLs: [Int: String] = [:]
    var errorPages: Set<Int> = []
    var errorMessages: [Int: String] = [:]  // 错误提示信息
    var retryingPages: [Int: Int] = [:]     // 重试次数追踪
    /// 下载进度 (0.0~1.0)，用于 UI 显示百分比
    var downloadProgress: [Int: Double] = [:]
    /// 已下载的图片数据 (NSCache 后端 + @Observable 触发) — 解决 AsyncImage 缓存命中率低的问题
    var cachedImages: [Int: PlatformImage] = [:]
    /// 用于打断 .task(id:) 的重试计数器 (URL 不变也能重新触发)
    var retryGeneration: [Int: Int] = [:]
    private var pTokens: [Int: String] = [:]
    private var showKeys: [Int: String] = [:]
    private var loadingPages: Set<Int> = []
    private var downloadingImages: Set<Int> = []  // 防止重复下载
    private var downloadDir: URL?

    /// NSCache 后端: 控制内存用量 (200MB / 30张)
    private static let imageCache: NSCache<NSNumber, PlatformImage> = {
        let cache = NSCache<NSNumber, PlatformImage>()
        cache.totalCostLimit = 200 * 1024 * 1024  // 200MB
        cache.countLimit = 30
        return cache
    }()

    /// 共享 URLSession，保持 cookies (对齐 Android OkHttpClient 单例)
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = .shared
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 6  // 增加并发连接数，改善快速滚动时的加载
        return URLSession(configuration: config)
    }()

    private static let pTokenUrlPattern = try! NSRegularExpression(pattern: #"/s/([0-9a-f]+)/(\d+)-(\d+)"#)

    func setupLocalGallery() {
        guard isDownloaded else { return }
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let ehviewerDir = documentsDir.appendingPathComponent("download", isDirectory: true)
        downloadDir = ehviewerDir.appendingPathComponent("\(gid)-\(token)", isDirectory: true)
    }

    func extractPTokens(from previewSet: PreviewSet) {
        let urls: [String]
        switch previewSet {
        case .normal(let items): urls = items.map { $0.pageUrl }
        case .large(let items): urls = items.map { $0.pageUrl }
        }

        for url in urls {
            let range = NSRange(url.startIndex..., in: url)
            if let match = Self.pTokenUrlPattern.firstMatch(in: url, range: range),
               let ptRange = Range(match.range(at: 1), in: url),
               let pnRange = Range(match.range(at: 3), in: url) {
                let pt = String(url[ptRange])
                let pn = Int(url[pnRange]) ?? 0
                pTokens[pn - 1] = pt
            }
        }
    }

    func fetchGalleryInfo() async {
        let site = GalleryActionService.siteBaseURL
        let urlStr = "\(site)g/\(gid)/\(token)/"
        guard let url = URL(string: urlStr) else { return }

        do {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 15

            let (data, _) = try await Self.session.data(for: request)
            let html = String(data: data, encoding: .utf8) ?? ""

            let pagesRx = try! NSRegularExpression(pattern: #"(\d+)\s*pages?"#, options: .caseInsensitive)
            if let match = pagesRx.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                let pages = Int(html[range]) ?? 0
                await MainActor.run { self.totalPages = pages }
            }

            let range = NSRange(html.startIndex..., in: html)
            let matches = Self.pTokenUrlPattern.matches(in: html, range: range)
            for m in matches {
                guard let ptRange = Range(m.range(at: 1), in: html),
                      let pnRange = Range(m.range(at: 3), in: html) else { continue }
                let pt = String(html[ptRange])
                let pn = Int(html[pnRange]) ?? 0
                pTokens[pn - 1] = pt
            }
        } catch {}
    }

    func loadCurrentPage() async {
        await loadPage(currentPage)
        await downloadImageData(currentPage)
        await preload(around: currentPage)
    }

    func onPageChange(_ page: Int) async {
        await loadPage(page)
        await downloadImageData(page)
        await preload(around: page)
    }

    /// 下载图片数据到 NSCache，带进度追踪 (解决 AsyncImage 缓存命中率低的问题)
    func downloadImageData(_ index: Int) async {
        // 已缓存 → 跳过
        if let cached = Self.imageCache.object(forKey: NSNumber(value: index)) {
            await MainActor.run {
                if self.cachedImages[index] == nil {
                    self.cachedImages[index] = cached
                }
            }
            return
        }
        guard let urlString = imageURLs[index], let url = URL(string: urlString) else { return }
        guard !downloadingImages.contains(index) else { return }
        downloadingImages.insert(index)
        defer { downloadingImages.remove(index) }

        // 下载重试最多 3 次 (对齐 Android downloadImage retry)
        for attempt in 0..<3 {
            do {
                var request = URLRequest(url: url)
                request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
                request.setValue(GalleryActionService.siteBaseURL, forHTTPHeaderField: "Referer")
                request.timeoutInterval = 60

                let (asyncBytes, response) = try await Self.session.bytes(for: request)
                let expectedLength = response.expectedContentLength
                var data = Data()
                if expectedLength > 0 {
                    data.reserveCapacity(Int(expectedLength))
                }

                var received: Int64 = 0
                for try await byte in asyncBytes {
                    data.append(byte)
                    received += 1
                    // 每 8KB 更新一次进度
                    if received % 8192 == 0 && expectedLength > 0 {
                        let p = min(1.0, Double(received) / Double(expectedLength))
                        await MainActor.run { self.downloadProgress[index] = p }
                    }
                }

                if let img = PlatformImage(data: data) {
                    let cost = data.count
                    Self.imageCache.setObject(img, forKey: NSNumber(value: index), cost: cost)
                    await MainActor.run {
                        self.cachedImages[index] = img
                        self.downloadProgress.removeValue(forKey: index)
                    }
                    return  // 成功
                } else {
                    await MainActor.run {
                        self.errorPages.insert(index)
                        self.errorMessages[index] = "图片数据无效"
                        self.downloadProgress.removeValue(forKey: index)
                    }
                    return
                }
            } catch is CancellationError {
                return
            } catch let urlError as URLError where urlError.code == .cancelled {
                // URLSession 取消 (Task 被外部取消时) — 不标记错误
                return
            } catch {
                // 检查 Task 是否已取消 (快速滚动导致视图回收)
                if Task.isCancelled { return }
                print("[ImageReader] Image download error for page \(index) (attempt \(attempt + 1)): \(error.localizedDescription)")
                if attempt < 2 {
                    // 指数退避重试: 1s, 2s
                    try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt))) * 1_000_000_000)
                    if Task.isCancelled { return }
                    continue
                }
                await MainActor.run {
                    self.errorPages.insert(index)
                    self.errorMessages[index] = "下载失败: \(error.localizedDescription)"
                    self.downloadProgress.removeValue(forKey: index)
                }
            }
        }
    }

    /// 带重试的页面加载 (对齐 Android SpiderWorker.downloadImage 最多重试 5 次)
    func loadPageWithRetry(_ index: Int) async {
        let maxRetries = 5
        for attempt in 0..<maxRetries {
            // 检查 Task 是否被取消 (快速滚动时 LazyVStack 回收会取消 .task)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.retryingPages[index] = attempt
            }
            await loadPage(index)
            // 成功 → 退出
            if imageURLs[index] != nil {
                await MainActor.run {
                    _ = self.retryingPages.removeValue(forKey: index)
                }
                return
            }
            // 已标记错误 → 退出（不再自动重试，用户可手动）
            if errorPages.contains(index) { return }
            // 取消检查
            guard !Task.isCancelled else { return }
            // 等待后重试 (指数退避: 1s, 2s, 4s, 8s, 16s)
            let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                // Task.sleep 抛出 CancellationError → 直接退出，不标记为错误
                return
            }
        }
        // 所有重试失败 — 仅在未取消时标记错误
        guard !Task.isCancelled else { return }
        await MainActor.run {
            self.errorPages.insert(index)
            self.errorMessages[index] = "加载超时，请点击重试"
            self.retryingPages.removeValue(forKey: index)
        }
    }

    func loadPage(_ index: Int) async {
        guard index >= 0, index < totalPages else { return }
        guard imageURLs[index] == nil else { return }
        guard !loadingPages.contains(index) else { return }

        // 优先本地
        if isDownloaded, let dir = downloadDir {
            if let localURL = SpiderInfoFile.getLocalImageURL(in: dir, pageIndex: index) {
                await MainActor.run {
                    self.imageURLs[index] = localURL.absoluteString
                    self.errorPages.remove(index)
                }
                return
            }
        }

        // 缓存
        if let cached = GalleryCache.shared.getImageURL(gid: gid, page: index) {
            await MainActor.run {
                self.imageURLs[index] = cached
                self.errorPages.remove(index)
            }
            return
        }

        loadingPages.insert(index)
        defer { loadingPages.remove(index) }

        do {
            let site = GalleryActionService.siteBaseURL
            let pageUrl: String

            if let pToken = pTokens[index] {
                pageUrl = "\(site)s/\(pToken)/\(gid)-\(index + 1)"
            } else {
                let pToken = try await fetchPToken(page: index)
                pTokens[index] = pToken
                pageUrl = "\(site)s/\(pToken)/\(gid)-\(index + 1)"
            }

            guard let url = URL(string: pageUrl) else { return }

            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 15

            let (data, _) = try await Self.session.data(for: request)
            let html = String(data: data, encoding: .utf8) ?? ""

            let imgRx = try! NSRegularExpression(pattern: #"id="img"\s+src="([^"]+)""#)
            if let m = imgRx.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let r = Range(m.range(at: 1), in: html) {
                let imgUrl = String(html[r])
                GalleryCache.shared.putImageURL(imgUrl, gid: gid, page: index)
                await MainActor.run {
                    self.imageURLs[index] = imgUrl
                    self.errorPages.remove(index)
                }
            } else {
                // 无法从页面 HTML 中提取图片 URL → 标记为失败
                print("[ImageReader] Failed to extract image URL from page HTML for page \(index)")
                await MainActor.run {
                    _ = self.errorPages.insert(index)
                }
                return
            }

            let skRx = try! NSRegularExpression(pattern: #"var showkey\s*=\s*"([^"]+)""#)
            if let m = skRx.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let r = Range(m.range(at: 1), in: html) {
                showKeys[index] = String(html[r])
            }
        } catch is CancellationError {
            // 任务取消 → 不标记错误，让重试逻辑处理
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            // URLSession 取消 → 同上
            return
        } catch {
            // 网络错误 → 不立即标记为错误，由 loadPageWithRetry 决定是否重试
            // 仅在单独调用 loadPage (非 WithRetry) 时标记错误
            if !Task.isCancelled {
                print("[ImageReader] Page \(index) load error: \(error.localizedDescription)")
            }
        }
    }

    func retryLoadPage(_ index: Int) async {
        await MainActor.run {
            self.imageURLs[index] = nil
            self.cachedImages.removeValue(forKey: index)
            self.errorPages.remove(index)
            self.errorMessages.removeValue(forKey: index)
            self.retryingPages.removeValue(forKey: index)
            self.downloadProgress.removeValue(forKey: index)
            // 递增 retryGeneration 确保 .task(id:) 一定重新触发
            self.retryGeneration[index, default: 0] += 1
        }
        Self.imageCache.removeObject(forKey: NSNumber(value: index))
        // 重试时清除缓存的 pToken 重新获取 (对齐 Android 强制刷新逻辑)
        pTokens.removeValue(forKey: index)
        // 也清除 GalleryCache 中可能过期的 URL
        GalleryCache.shared.removeImageURL(gid: gid, page: index)
        // 确保 loadingPages 不会阻塞重试
        loadingPages.remove(index)
        await loadPageWithRetry(index)
        // 主动下载图片 (防止 .task(id:) 未重新触发)
        await downloadImageData(index)
    }

    /// 预加载页面 (对齐 Android SpiderQueen.request addNeighbor 逻辑)
    private func preload(around page: Int) async {
        // 使用设置中的预加载数量 (对齐 Android Settings.getPreloadImage())
        let preloadNum = AppSettings.shared.preloadImage
        
        // 预加载范围：前1页 + 后 preloadNum 页 (对齐 Android: index + 1 到 index + 1 + mPreloadNumber)
        let startPage = max(0, page - 1)
        let endPage = min(totalPages - 1, page + preloadNum)
        
        // 收集需要加载的页面
        var pagesToLoad: [Int] = []
        for i in startPage...endPage where imageURLs[i] == nil && !loadingPages.contains(i) {
            pagesToLoad.append(i)
        }
        
        // 并行加载 URL + 图片数据 (对齐 Android SpiderDecoder 多线程)
        await withTaskGroup(of: Void.self) { group in
            for pageIndex in pagesToLoad {
                group.addTask {
                    await self.loadPage(pageIndex)
                    await self.downloadImageData(pageIndex)
                }
            }
        }
    }

    private func fetchPToken(page: Int) async throws -> String {
        let site = GalleryActionService.siteBaseURL
        let detailPage = page / 20
        let urlStr = "\(site)g/\(gid)/\(token)/\(detailPage > 0 ? "?p=\(detailPage)" : "")"
        guard let url = URL(string: urlStr) else {
            throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Bad URL"])
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, _) = try await Self.session.data(for: request)
        let html = String(data: data, encoding: .utf8) ?? ""

        let range = NSRange(html.startIndex..., in: html)
        let matches = Self.pTokenUrlPattern.matches(in: html, range: range)

        for m in matches {
            guard let ptRange = Range(m.range(at: 1), in: html),
                  let pnRange = Range(m.range(at: 3), in: html) else { continue }
            let pt = String(html[ptRange])
            let pn = Int(html[pnRange]) ?? 0
            pTokens[pn - 1] = pt
        }

        if let pt = pTokens[page] { return pt }
        throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "pToken not found"])
    }


}

// MARK: - macOS Scroll Wheel Page Navigator

#if os(macOS)
/// macOS 滚轮翻页 — 捕获 NSScrollView 之外的滚轮事件，累积 deltaY 超过阈值翻页
/// 当图片缩放(isZoomed=true)时不拦截，让 NSScrollView 自行处理平移
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

    /// 透明 NSView，拦截 scrollWheel 事件用于翻页
    class ScrollWheelCaptureView: NSView {
        var onNext: (() -> Void)?
        var onPrevious: (() -> Void)?
        var isZoomed: Bool = false
        private var accumulatedDelta: CGFloat = 0
        private let threshold: CGFloat = 40 // 滚轮翻页灵敏度
        private var lastScrollTime: Date = .distantPast

        override func scrollWheel(with event: NSEvent) {
            // 缩放状态下不拦截 → 让底层 ZoomableImageView 的 NSScrollView 处理
            guard !isZoomed else {
                super.scrollWheel(with: event)
                return
            }

            // 精确触控板 (phase-based) 或普通鼠标滚轮
            let delta = event.scrollingDeltaY

            // 超过 0.5s 没有滚动 → 重置累积
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
            // 缩放时让底层视图处理事件
            if isZoomed { return nil }
            // 非缩放状态拦截滚轮事件
            return frame.contains(point) ? self : nil
        }
    }
}
#endif

// MARK: - Helper Functions

#if os(iOS)
/// 设置屏幕亮度 (iOS 26.0 兼容)
private func setScreenBrightness(_ brightness: CGFloat) {
    // iOS 26.0 之后 UIScreen.main 被弃用，使用 UIWindowScene 的方式
    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
       let screen = windowScene.windows.first?.screen {
        // iOS 26+: 使用 UIWindowScene 中的 screen
        screen.brightness = brightness
    }
}
#endif
