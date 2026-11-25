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
    
    @State private var vm: GalleryPreviewsViewModel
    @State private var scrollPosition: Int?
    @State private var jumpRequest: JumpRequest?
    @State private var jumpFailed = false
    @State private var retryPage: UUID?

    private struct JumpRequest: Equatable {
        let position: Int
        let id = UUID()
    }
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
        _vm = State(initialValue: GalleryPreviewsViewModel(seed: initialPreviewSet, totalPages: totalPages))
    }
    
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: previewWidth, maximum: previewWidth + 20), spacing: 8)], spacing: 16) {
                ForEach(vm.allPreviews, id: \.position) { preview in
                    previewItem(preview: preview)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 8)
            .padding(.vertical)

            previewFooter
        }
        .scrollPosition(id: $scrollPosition, anchor: .top)
        // Keep the viewport unchanged on failure or cancellation.
        .overlay(alignment: .bottom) { jumpStatus }
        .task(id: retryPage) {
            if retryPage != nil { await loadNextPage() }
        }
        .task(id: jumpRequest) {
            guard let request = jumpRequest else { return }
            do {
                let found = try await vm.loadUpTo(position: request.position, fetch: fetchPreview)
                guard !Task.isCancelled, request == jumpRequest else { return }
                if found {
                    jumpRequest = nil
                    withAnimation { scrollPosition = request.position }
                } else {
                    jumpFailed = true
                }
            } catch {
                guard !Task.isCancelled, request == jumpRequest else { return }
                jumpFailed = true
            }
        }
        .onDisappear {
            jumpRequest = nil
            jumpFailed = false
            retryPage = nil
            vm.cancelPageRequest()
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
        .alert("跳转至预览页", isPresented: $showJumpSheet) {
            TextField("1 - \(galleryPages)", text: $jumpText)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            Button("跳转") {
                guard let page = validJumpPage else { return }
                jumpFailed = false
                jumpRequest = JumpRequest(position: page - 1)
            }
            .disabled(validJumpPage == nil)
            Button("取消", role: .cancel) {}
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
                .presentationBackground(.clear)
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
    
    @ViewBuilder
    private var previewFooter: some View {
        if vm.pageFailed {
            VStack(spacing: 8) {
                Text("预览加载失败。")
                Button("重试") { retryPage = UUID() }
                    .disabled(jumpRequest != nil)
            }
            .padding()
        } else if vm.isLoadingMore {
            ProgressView().padding()
        } else if vm.hasNextPage && !vm.allPreviews.isEmpty {
            Color.clear.frame(height: 1)
                .task(id: vm.nextPage) {
                    guard jumpRequest == nil else { return }
                    await loadNextPage()
                }
        }
    }

    @ViewBuilder
    private var jumpStatus: some View {
        if let jump = jumpRequest {
            let page = jump.position + 1
            HStack {
                if jumpFailed {
                    Text("第 \(page) 页预览不可用。")
                } else {
                    ProgressView("正在查找第 \(page) 页")
                }
                Spacer()
                if jumpFailed && vm.hasNextPage {
                    Button("重试") {
                        jumpFailed = false
                        jumpRequest = JumpRequest(position: jump.position)
                    }
                }
                Button(jumpFailed ? "关闭" : "取消") { cancelJump() }
            }
            .padding()
            .background(.regularMaterial)
        }
    }

    private var validJumpPage: Int? {
        guard let page = Int(jumpText), page >= 1, page <= galleryPages else { return nil }
        return page
    }

    private func cancelJump() {
        if !jumpFailed { vm.cancelPageRequest() }
        jumpRequest = nil
        jumpFailed = false
    }

    private func fetchPreview(_ page: Int) async throws -> PreviewSet {
        let site = GalleryActionService.siteBaseURL
        let (previews, _) = try await EhAPI.shared.getPreviewSet(url: "\(site)g/\(gid)/\(token)/?p=\(page)")
        return previews
    }

    private func loadNextPage() async {
        do { _ = try await vm.loadNextPage(fetch: fetchPreview) }
        catch { /* The model exposes failure for an explicit retry. */ }
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

@MainActor
@Observable
final class GalleryPreviewsViewModel {
    private(set) var allPreviews: [PreviewItem] = []
    private(set) var nextPage = 1
    private(set) var isLoadingMore = false
    private(set) var pageFailed = false
    private var positions: Set<Int> = []
    private let totalPages: Int
    private var request: (id: UUID, task: Task<Bool, Error>)?

    var hasNextPage: Bool { nextPage < totalPages }

    init(seed: PreviewSet, totalPages: Int) {
        self.totalPages = totalPages
        appendPreviews(from: seed)
    }

    // The grid sentinel and jump action share a single request and its commit.
    func loadNextPage(fetch: @escaping @MainActor (Int) async throws -> PreviewSet) async throws -> Bool {
        try Task.checkCancellation()
        if let request { return try await request.task.value }
        guard hasNextPage else { return false }

        let page = nextPage
        let id = UUID()
        isLoadingMore = true
        pageFailed = false
        let task = Task {
            defer {
                if request?.id == id {
                    request = nil
                    isLoadingMore = false
                }
            }
            do {
                let previews = try await fetch(page)
                try Task.checkCancellation()
                guard request?.id == id else { throw CancellationError() }
                appendPreviews(from: previews)
                nextPage += 1
                return true
            } catch {
                if request?.id == id, !Task.isCancelled, !(error is CancellationError) {
                    pageFailed = true
                }
                throw error
            }
        }
        request = (id, task)
        return try await task.value
    }

    func cancelPageRequest() {
        request?.task.cancel()
        request = nil
        isLoadingMore = false
    }

    func loadUpTo(position: Int, fetch: @escaping @MainActor (Int) async throws -> PreviewSet) async throws -> Bool {
        while !positions.contains(position) {
            try Task.checkCancellation()
            guard try await loadNextPage(fetch: fetch) else { return false }
        }
        try Task.checkCancellation()
        return true
    }

    private func appendPreviews(from previewSet: PreviewSet) {
        let items: [PreviewItem]
        switch previewSet {
        case .large(let previews):
            items = previews.map { PreviewItem(position: $0.position, type: .large(imageUrl: $0.imageUrl)) }
        case .normal(let previews):
            items = previews.map { PreviewItem(position: $0.position, type: .normal($0)) }
        }
        let newItems = items.filter { positions.insert($0.position).inserted }
        if !newItems.isEmpty {
            allPreviews = (allPreviews + newItems).sorted { $0.position < $1.position }
        }
    }
}
