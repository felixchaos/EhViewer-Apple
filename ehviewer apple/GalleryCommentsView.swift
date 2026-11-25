//
//  GalleryCommentsView.swift
//  ehviewer apple
//
//  评论列表页面 (对齐 Android GalleryCommentsScene)
//

import SwiftUI
import EhModels
import EhAPI
import EhSettings
import EhDatabase

struct GalleryCommentsView: View {
    let gid: Int64
    let token: String
    let apiUid: Int64
    let apiKey: String
    
    @State private var vm: GalleryCommentsViewModel
    @State private var loadRequest: UUID?

    @State private var composing: CommentComposeTarget?

    init(gid: Int64, token: String, apiUid: Int64, apiKey: String,
         initialComments: [GalleryComment], hasMore: Bool) {
        self.gid = gid
        self.token = token
        self.apiUid = apiUid
        self.apiKey = apiKey
        _vm = State(initialValue: GalleryCommentsViewModel(comments: initialComments, hasMore: hasMore))
    }

    /// 未登录时不显示发表入口 —— 点了也只会拿到服务端的拒绝
    private var canComment: Bool { AppSettings.shared.isLogin }

    private var galleryUrl: String {
        "\(GalleryActionService.siteBaseURL)g/\(gid)/\(token)/"
    }
    
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(vm.comments.enumerated()), id: \.offset) { idx, comment in
                    commentRow(comment)
                    
                    if idx < vm.comments.count - 1 {
                        Divider()
                            .padding(.leading)
                    }
                }
                
                if vm.hasMore {
                    VStack(spacing: 8) {
                        if vm.isLoading {
                            ProgressView("正在加载评论")
                            Button("取消") { cancelLoading() }
                        } else {
                            if vm.loadFailed { Text("评论加载失败。") }
                            Button(vm.loadFailed ? "重试" : "加载全部评论") {
                                loadRequest = UUID()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                }
            }
        }
        .navigationTitle("评论 (\(vm.comments.count)\(vm.hasMore ? "+" : ""))")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: loadRequest) {
            guard loadRequest != nil else { return }
            await vm.loadAllComments {
                try await EhAPI.shared.getAllComments(gid: gid, token: token)
            }
        }
        .onDisappear { cancelLoading() }
        .toolbar {
            if canComment {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        composing = CommentComposeTarget(comment: nil)
                    } label: {
                        Label("发表评论", systemImage: "square.and.pencil")
                    }
                }
            }
        }
        .sheet(item: $composing) { target in
            CommentComposerView(
                gid: gid,
                token: token,
                galleryUrl: galleryUrl,
                editing: target.comment,
                apiUid: apiUid,
                apiKey: apiKey,
                onPosted: { list in
                    cancelLoading()
                    vm.replaceComments(list)
                }
            )
        }
    }
    
    private func cancelLoading() {
        loadRequest = nil
        vm.cancelLoading()
    }

    // MARK: - 单条评论
    
    private func commentRow(_ comment: GalleryComment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 头部：用户名、上传者徽标、时间、分数
            HStack(spacing: 8) {
                Text(comment.user)
                    .font(EhFont.body.weight(.semibold))
                    .foregroundStyle(EhColor.label)

                // 上传者本人的评论单独标出来：同一串评论里，作者的说明
                // （补图、修正、致歉）和读者的闲聊分量完全不同。
                // 服务端不单独下发标记，但上传者评论的 id 固定为 0（也因此不可投票）。
                if comment.id == 0 {
                    Text("上传者")
                        .font(EhFont.footnote.weight(.semibold))
                        .foregroundStyle(EhColor.onAccentFill)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(EhColor.accentFill))
                }

                Spacer(minLength: 4)

                Text(comment.time, style: .date)
                    .font(EhFont.mono(11))
                    .foregroundStyle(EhColor.tertiaryLabel)

                if comment.score != 0 {
                    Text(comment.score > 0 ? "+\(comment.score)" : "\(comment.score)")
                        .font(EhFont.mono(12, weight: .semibold))
                        .foregroundStyle(comment.score > 0 ? EhColor.success : EhColor.danger)
                }
            }

            // 评论内容 (HTML 转纯文本，完整显示)
            Text(comment.comment.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
                .font(EhFont.body)
                .foregroundStyle(EhColor.label)
            
            // 投票 / 编辑
            if comment.voteUpAble || comment.voteDownAble || comment.editable {
                HStack(spacing: 16) {
                    // editable 由服务端下发 —— 只有自己的评论才有
                    if comment.editable {
                        Button {
                            composing = CommentComposeTarget(comment: comment)
                        } label: {
                            Label("编辑", systemImage: "pencil")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    if comment.voteUpAble {
                        Button {
                            Task {
                                if !(await vm.voteComment(
                                    apiUid: apiUid, apiKey: apiKey,
                                    gid: gid, token: token,
                                    commentId: comment.id, vote: 1
                                )) { EhToast.failure("无法确认投票结果。") }
                            }
                        } label: {
                            Label("赞同", systemImage: comment.voteUpEd ? "hand.thumbsup.fill" : "hand.thumbsup")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    
                    if comment.voteDownAble {
                        Button {
                            Task {
                                if !(await vm.voteComment(
                                    apiUid: apiUid, apiKey: apiKey,
                                    gid: gid, token: token,
                                    commentId: comment.id, vote: -1
                                )) { EhToast.failure("无法确认投票结果。") }
                            }
                        } label: {
                            Label("反对", systemImage: comment.voteDownEd ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            
            // 编辑信息
            if let lastEdited = comment.lastEdited {
                Text("最后编辑: \(lastEdited, style: .date)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        // 长按菜单（对齐 Android GalleryCommentsScene 的 copy_comment_text /
        // join_blacklist）。此前评论行只有投票和编辑按钮，想复制一段评论
        // 或者屏蔽一个反复刷屏的人，都没有出口。
        .contextMenu {
            Button {
                #if os(iOS)
                UIPasteboard.general.string = Self.plainText(comment.comment)
                #else
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Self.plainText(comment.comment), forType: .string)
                #endif
                EhToast.success("已复制评论")
            } label: {
                Label("复制评论内容", systemImage: "doc.on.doc")
            }

            if !comment.user.isEmpty {
                Button(role: .destructive) {
                    blockCommenter(comment.user)
                } label: {
                    Label("屏蔽「\(comment.user)」", systemImage: "person.slash")
                }
            }
        }
    }

    /// 复制时给纯文本，不给 HTML —— 评论正文在模型里是带标签的原始 HTML，
    /// 直接贴出去是一串 <br> 和 <a href>。
    private static func plainText(_ html: String) -> String {
        html.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#039;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 把评论者加进过滤器。
    /// mode 1 = 上传者过滤，与 FilterView 里那一类是同一套（评论者用的也是
    /// E-Hentai 的用户名，和上传者同一个命名空间）。
    private func blockCommenter(_ user: String) {
        do {
            try EhDatabase.shared.insertFilter(
                FilterRecord(mode: 1, text: user, enable: true)
            )
            EhToast.success("已屏蔽「\(user)」")
        } catch {
            EhToast.failure("屏蔽失败")
            debugLog("[Comments] 屏蔽评论者失败: \(error)")
        }
    }
}

// MARK: - ViewModel

@MainActor
@Observable
final class GalleryCommentsViewModel {
    private(set) var comments: [GalleryComment]
    private(set) var hasMore: Bool
    private(set) var isLoading = false
    private(set) var loadFailed = false
    private var activeLoad: UUID?

    init(comments: [GalleryComment], hasMore: Bool) {
        self.comments = comments
        self.hasMore = hasMore
    }

    func replaceComments(_ list: GalleryCommentList) {
        comments = list.comments
        hasMore = list.hasMore
        loadFailed = false
    }

    func cancelLoading() {
        activeLoad = nil
        isLoading = false
    }

    func loadAllComments(fetch: @MainActor () async throws -> GalleryCommentList) async {
        guard hasMore, activeLoad == nil, !Task.isCancelled else { return }
        let id = UUID()
        activeLoad = id
        isLoading = true
        loadFailed = false
        defer {
            if activeLoad == id { cancelLoading() }
        }

        do {
            let result = try await fetch()
            guard activeLoad == id, !Task.isCancelled else { return }
            replaceComments(result)
        } catch {
            guard activeLoad == id, !Task.isCancelled, !(error is CancellationError) else { return }
            loadFailed = true
        }
    }

    func voteComment(
        apiUid: Int64, apiKey: String,
        gid: Int64, token: String,
        commentId: Int64, vote: Int
    ) async -> Bool {
        do {
            let result = try await EhAPI.shared.voteComment(
                apiUid: apiUid, apiKey: apiKey,
                gid: gid, token: token,
                commentId: commentId, commentVote: vote
            )
            if let idx = comments.firstIndex(where: { $0.id == commentId }) {
                comments[idx].score = result.score
                comments[idx].voteUpEd = result.vote == 1
                comments[idx].voteDownEd = result.vote == -1
            }
            return true
        } catch {
            return false
        }
    }
}

#Preview {
    NavigationStack {
        GalleryCommentsView(
            gid: 12345,
            token: "abc123",
            apiUid: -1,
            apiKey: "",
            initialComments: [],
            hasMore: true
        )
    }
}
