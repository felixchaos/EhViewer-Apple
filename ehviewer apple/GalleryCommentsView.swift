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
    let initialComments: [GalleryComment]
    let hasMore: Bool
    
    @State private var vm = GalleryCommentsViewModel()
    @State private var composing: CommentComposeTarget?

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
                
                // 加载更多
                if vm.hasMore {
                    Button {
                        Task { await vm.loadAllComments(gid: gid, token: token) }
                    } label: {
                        HStack {
                            if vm.isLoading {
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                            Text(vm.isLoading ? "加载中..." : "加载全部评论")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color(.tertiarySystemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .padding()
                    .disabled(vm.isLoading)
                }
            }
        }
        .navigationTitle("评论 (\(vm.comments.count)\(vm.hasMore ? "+" : ""))")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            vm.setInitialComments(initialComments, hasMore: hasMore)
        }
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
                    vm.setInitialComments(list.comments, hasMore: list.hasMore)
                }
            )
        }
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
                                await vm.voteComment(
                                    apiUid: apiUid, apiKey: apiKey,
                                    gid: gid, token: token,
                                    commentId: comment.id, vote: 1
                                )
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
                                await vm.voteComment(
                                    apiUid: apiUid, apiKey: apiKey,
                                    gid: gid, token: token,
                                    commentId: comment.id, vote: -1
                                )
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

@Observable
class GalleryCommentsViewModel {
    var comments: [GalleryComment] = []
    var hasMore = false
    var isLoading = false
    var errorMessage: String?
    
    func setInitialComments(_ comments: [GalleryComment], hasMore: Bool) {
        self.comments = comments
        self.hasMore = hasMore
    }
    
    func loadAllComments(gid: Int64, token: String) async {
        guard !isLoading else { return }
        isLoading = true
        
        do {
            let result = try await EhAPI.shared.getAllComments(gid: gid, token: token)
            
            await MainActor.run {
                self.comments = result.comments
                self.hasMore = result.hasMore
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = EhError.localizedMessage(for: error)
                self.isLoading = false
            }
        }
    }

    /// 评论投票 — 连通 EhAPI.voteComment (对齐 Android GalleryCommentsScene.voteComment)
    func voteComment(
        apiUid: Int64, apiKey: String,
        gid: Int64, token: String,
        commentId: Int64, vote: Int
    ) async {
        do {
            let result = try await EhAPI.shared.voteComment(
                apiUid: apiUid, apiKey: apiKey,
                gid: gid, token: token,
                commentId: commentId, commentVote: vote
            )
            // 更新本地评论状态
            await MainActor.run {
                if let idx = comments.firstIndex(where: { $0.id == commentId }) {
                    comments[idx].score = result.score
                    // vote == 1 → 用户点赞; vote == -1 → 用户点踩
                    // result.vote: 服务端返回的最终投票状态 (1 = 已赞, -1 = 已踩, 0 = 取消)
                    comments[idx].voteUpEd = result.vote == 1
                    comments[idx].voteDownEd = result.vote == -1
                }
            }
        } catch {
            await MainActor.run {
                self.errorMessage = EhError.localizedMessage(for: error)
            }
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
