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
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: previewWidth, maximum: previewWidth + 20), spacing: 8)], spacing: 16) {
                ForEach(vm.allPreviews, id: \.position) { preview in
                    previewItem(preview: preview)
                        .onAppear {
                            // 懒加载: 当预览出现时检查是否需要加载更多 (对齐 Android RecyclerView 懒加载)
                            let lastPosition = vm.allPreviews.last?.position ?? 0
                            if preview.position >= lastPosition - 5 {
                                Task {
                                    await vm.loadNextPageIfNeeded(gid: gid, token: token, totalPages: totalPages)
                                }
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
    
    @ViewBuilder
    private func previewItem(preview: PreviewItem) -> some View {
        Button {
            // 对齐 Android: 预览点击直接进入阅读器并定位页面
            readerTarget = ReaderTarget(page: preview.position)
        } label: {
            VStack(spacing: 6) {
                switch preview.type {
                case .large(let imageUrl):
                    CachedAsyncImage(url: URL(string: imageUrl)) { img in
                        img.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color(.tertiarySystemFill)
                            .overlay { ProgressView() }
                    }
                    .frame(width: previewWidth, height: previewWidth / previewAspect)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
                    
                case .normal(let normalPreview):
                    SpritePreviewView(preview: normalPreview)
                        .frame(width: previewWidth, height: previewWidth / previewAspect)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
                }
                
                // 页码标签 (1-based，对齐 Android preview.getPosition() + 1)
                Text("\(preview.position + 1)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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


