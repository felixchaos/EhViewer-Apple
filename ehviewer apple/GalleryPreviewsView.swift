//
//  GalleryPreviewsView.swift
//  ehviewer apple
//
//  预览图懒加载查看 (对齐 Android GalleryPreviewsScene - 滚动加载全部预览)
//

import SwiftUI
import EhModels
import EhAPI
import EhSettings

struct GalleryPreviewsView: View {
    let gid: Int64
    let token: String
    let totalPages: Int
    let galleryPages: Int
    let initialPreviewSet: PreviewSet
    
    @State private var vm = GalleryPreviewsViewModel()
    @State private var readerTarget: ReaderTarget? = nil
    /// 跳到指定预览页（对齐 Android scene_gallery_previews.xml 的 action_go_to）。
    /// 几百页的本子靠滚是找不到某一页的。
    @State private var showJumpSheet = false
    @State private var jumpText = ""
    
    // 预览图尺寸 (对齐 Android gallery_grid_column_width_middle = 120dp)
    private let previewWidth: CGFloat = 120
    private let previewAspect: CGFloat = 2.0 / 3.0  // 对齐 Android FixedThumb aspect=0.667
    
    init(gid: Int64, token: String, totalPages: Int, galleryPages: Int, initialPreviewSet: PreviewSet) {
        self.gid = gid
        self.token = token
        self.totalPages = totalPages
        self.galleryPages = galleryPages
        self.initialPreviewSet = initialPreviewSet
    }
    
    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: previewWidth, maximum: previewWidth + 20), spacing: 8)], spacing: 16) {
                ForEach(vm.allPreviews, id: \.position) { preview in
                    previewItem(preview: preview)
                }

                // 触底哨兵 —— 只有它出现时才拉下一页。
                // 原先把 onAppear 挂在每个格子上，滚动时每露出一个格子就要
                // 比较一次尾部位置并可能起一个 Task，纯属浪费。
                if !vm.allPreviews.isEmpty && !vm.isLoadingMore {
                    Color.clear
                        .frame(height: 1)
                        .onAppear {
                            Task {
                                await vm.loadNextPageIfNeeded(gid: gid, token: token, totalPages: totalPages)
                            }
                        }
                }
                
                // 加载更多指示器
                if vm.isLoadingMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical)
        }
        .navigationTitle("预览 (\(galleryPages)张)")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    jumpText = ""
                    showJumpSheet = true
                } label: {
                    Image(systemName: "arrow.right.to.line")
                }
                .accessibilityLabel("跳转到页码")
            }
        }
        .alert("跳转到第几张", isPresented: $showJumpSheet) {
            TextField("1 - \(galleryPages)", text: $jumpText)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            Button("跳转") {
                guard let page = Int(jumpText), page >= 1, page <= galleryPages else { return }
                // 预览是分页拉的，目标还没加载出来就先把它那一页取回来
                Task {
                    await vm.loadUpTo(position: page - 1, gid: gid, token: token,
                                      totalPages: totalPages)
                    // 让出一帧再滚。
                    //
                    // 刚 append 进 allPreviews 的条目，SwiftUI 还没把它们排进
                    // LazyVGrid 的布局里；这时候 scrollTo 找不到那个 id，
                    // 是一次静默的空操作——加载明明成功了，界面却纹丝不动。
                    try? await Task.sleep(for: .milliseconds(80))
                    withAnimation { proxy.scrollTo(page - 1, anchor: .top) }
                }
            }
            Button("取消", role: .cancel) {}
        }
        .onAppear {
            if vm.allPreviews.isEmpty {
                vm.initialize(initialPreviewSet: initialPreviewSet)
            }
        }
        .overlay {
            if vm.isInitialLoading {
                ProgressView("加载中...")
            }
        }
        }
        #if os(iOS)
        .fullScreenCover(item: $readerTarget) { target in
            ImageReaderView(
                gid: gid,
                token: token,
                pages: galleryPages,
                previewSet: initialPreviewSet,
                initialPage: target.page
            )
            .id(gid)
        }
        #else
        .sheet(item: $readerTarget) { target in
            ImageReaderView(
                gid: gid,
                token: token,
                pages: galleryPages,
                previewSet: initialPreviewSet,
                initialPage: target.page
            )
            .id(gid)
            .frame(minWidth: 800, minHeight: 600)
        }
        #endif
    }
    
    // MARK: - 预览项 (点击跳转到阅读器，对齐 Android GalleryPreviewsScene.onItemClick)
    
    /// 已读到的页索引（0-based）。与列表行、详情页读同一个键。
    private var readUpTo: Int {
        UserDefaults.standard.integer(forKey: "reading_progress_\(gid)")
    }

    @ViewBuilder
    private func previewItem(preview: PreviewItem) -> some View {
        Button {
            // 对齐 Android: 预览点击直接进入阅读器并定位页面
            readerTarget = ReaderTarget(page: preview.position)
        } label: {
            VStack(spacing: 6) {
                Group {
                    switch preview.type {
                    case .large(let imageUrl):
                        CachedAsyncImage(url: URL(string: imageUrl), showProgress: false) { img in
                            img.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            EhColor.thumbnailPlaceholder
                        }
                    case .normal(let normalPreview):
                        SpritePreviewView(preview: normalPreview)
                    }
                }
                .frame(width: previewWidth, height: previewWidth / previewAspect)
                .clipShape(RoundedRectangle(cornerRadius: EhRadius.thumbnail, style: .continuous))
                // 已读的页在底部画一条琥珀线，当前页整格描边。
                // 翻到一半退出来再进预览时，能立刻看出读到哪了。
                .overlay(alignment: .bottom) {
                    if preview.position < readUpTo {
                        Rectangle()
                            .fill(EhColor.accentFill)
                            .frame(height: 2)
                    }
                }
                .overlay {
                    if preview.position == readUpTo {
                        RoundedRectangle(cornerRadius: EhRadius.thumbnail, style: .continuous)
                            .strokeBorder(EhColor.accentFill, lineWidth: 1.5)
                    }
                }

                // 页码标签 (1-based，对齐 Android preview.getPosition() + 1)
                Text("\(preview.position + 1)")
                    .font(EhFont.mono(11))
                    .foregroundStyle(
                        preview.position == readUpTo ? EhColor.accent : EhColor.tertiaryLabel
                    )
            }
        }
        .buttonStyle(.plain)
    }
}

    private struct ReaderTarget: Identifiable {
        let id = UUID()
        let page: Int
    }

// MARK: - 统一预览项模型

struct PreviewItem: Identifiable {
    let id: Int
    let position: Int
    let type: PreviewType
    
    enum PreviewType {
        case large(imageUrl: String)
        case normal(NormalPreview)
    }
    
    init(position: Int, type: PreviewType) {
        self.id = position
        self.position = position
        self.type = type
    }
}

// MARK: - ViewModel

@Observable
class GalleryPreviewsViewModel {
    var allPreviews: [PreviewItem] = []
    var isInitialLoading = false
    var isLoadingMore = false
    private var loadedPages: Set<Int> = []
    private var currentPage = 0
    private var isLoading = false
    
    func initialize(initialPreviewSet: PreviewSet) {
        appendPreviews(from: initialPreviewSet)
        loadedPages.insert(0)
        currentPage = 0
    }
    
    func loadNextPageIfNeeded(gid: Int64, token: String, totalPages: Int) async {
        guard !isLoading else { return }
        
        let nextPage = currentPage + 1
        guard nextPage < totalPages else { return }
        guard !loadedPages.contains(nextPage) else { return }
        
        isLoading = true
        await MainActor.run { isLoadingMore = true }
        
        do {
            let site = GalleryActionService.siteBaseURL
            let urlStr = "\(site)g/\(gid)/\(token)/?p=\(nextPage)"
            debugLog("Loading preview page \(nextPage): \(urlStr)")
            let (previewSet, _) = try await EhAPI.shared.getPreviewSet(url: urlStr)
            
            await MainActor.run {
                self.appendPreviews(from: previewSet)
                self.loadedPages.insert(nextPage)
                self.currentPage = nextPage
                self.isLoadingMore = false
                self.isLoading = false
                debugLog("Loaded preview page \(nextPage) with \(previewSet.count) items, total: \(allPreviews.count)")
            }
        } catch {
            debugLog("Failed to load preview page \(nextPage): \(error)")
            await MainActor.run {
                self.isLoadingMore = false
                self.isLoading = false
            }
        }
    }
    
    /// 一直往后拉，直到目标位置已经在列表里（或者拉不动了）。
    ///
    /// 预览是按页拉的，跳到第 300 张时那一页多半还没请求过；不先拉回来，
    /// scrollTo 会因为找不到那个 id 而什么都不做。
    func loadUpTo(position: Int, gid: Int64, token: String, totalPages: Int) async {
        var guardCount = 0
        while !allPreviews.contains(where: { $0.position >= position }) {
            let before = allPreviews.count
            await loadNextPageIfNeeded(gid: gid, token: token, totalPages: totalPages)
            // 没有新内容进来就说明拉到头了，别空转
            guard allPreviews.count > before else { return }
            guardCount += 1
            if guardCount > totalPages { return }
        }
    }

    private func appendPreviews(from previewSet: PreviewSet) {
        switch previewSet {
        case .large(let items):
            let newItems = items.map { preview in
                PreviewItem(position: preview.position, type: .large(imageUrl: preview.imageUrl))
            }
            // 去重并排序
            let existingPositions = Set(allPreviews.map { $0.position })
            let filtered = newItems.filter { !existingPositions.contains($0.position) }
            allPreviews.append(contentsOf: filtered)
            allPreviews.sort { $0.position < $1.position }
            
        case .normal(let items):
            let newItems = items.map { preview in
                PreviewItem(position: preview.position, type: .normal(preview))
            }
            let existingPositions = Set(allPreviews.map { $0.position })
            let filtered = newItems.filter { !existingPositions.contains($0.position) }
            allPreviews.append(contentsOf: filtered)
            allPreviews.sort { $0.position < $1.position }
        }
    }
}


