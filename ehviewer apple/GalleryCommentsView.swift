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

struct GalleryCommentsView: View {
    let gid: Int64
    let token: String
    let apiUid: Int64
    let apiKey: String
    let initialComments: [GalleryComment]
    let hasMore: Bool
    
    @State private var vm = GalleryCommentsViewModel()
    
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
    }
    
    // MARK: - 单条评论
    
    private func commentRow(_ comment: GalleryComment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 头部：用户名、时间、分数
            HStack {
                Text(comment.user)
                    .font(.subheadline.bold())
                
                Spacer()
                
                Text(comment.time, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                if comment.score != 0 {
                    Text(comment.score > 0 ? "+\(comment.score)" : "\(comment.score)")
                        .font(.caption)
                        .foregroundStyle(comment.score > 0 ? .green : .red)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(comment.score > 0 ? Color.green.opacity(0.1) : Color.red.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            
            // 评论内容 (HTML 转纯文本，完整显示)
            Text(comment.comment.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
                .font(.subheadline)
                .foregroundStyle(.primary)
            
            // 投票按钮
            if comment.voteUpAble || comment.voteDownAble {
                HStack(spacing: 16) {
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
