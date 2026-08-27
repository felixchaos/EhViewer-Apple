//
//  CommentComposerView.swift
//  ehviewer apple
//
//  发表 / 编辑评论 — 对齐 Android GalleryCommentsScene 的输入框
//
//  编辑走上游 2026-07-30 新增的 `geteditcomment` 接口先取回**原始 BBCode**，
//  而不是拿列表里渲染过的 HTML —— 后者会把 [b]…[/b] 之类的标记吃掉，
//  用户一提交就等于把自己的排版删了。
//

import SwiftUI
import EhModels
import EhAPI
import EhSettings

struct CommentComposerView: View {
    let gid: Int64
    let token: String
    /// 详情页 URL，评论接口以它为提交地址
    let galleryUrl: String
    /// nil = 新发表；非 nil = 编辑这条
    let editing: GalleryComment?
    /// geteditcomment 需要的凭据
    let apiUid: Int64
    let apiKey: String

    /// 提交成功后把最新评论列表回传给调用方
    let onPosted: (GalleryCommentList) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var editorFocused: Bool

    @State private var text = ""
    @State private var isLoadingOriginal = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private var isEditing: Bool { editing != nil }

    private var canSubmit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSubmitting && !isLoadingOriginal
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $text)
                            .frame(minHeight: 160)
                            .focused($editorFocused)
                            .disabled(isLoadingOriginal)

                        if text.isEmpty && !isLoadingOriginal {
                            Text("说点什么…")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }

                    if isLoadingOriginal {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在取回原文…").foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text(isEditing ? "编辑评论" : "发表评论")
                } footer: {
                    Text("支持 BBCode，例如 [b]加粗[/b]、[url=…]链接[/url]。至少 10 个字符，否则服务端会拒绝。")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isEditing ? "编辑评论" : "发表评论")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSubmitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(isEditing ? "保存" : "发表") {
                            Task { await submit() }
                        }
                        .disabled(!canSubmit)
                    }
                }
            }
            .task { await loadOriginalIfEditing() }
        }
    }

    // MARK: - 取回原文

    private func loadOriginalIfEditing() async {
        guard let editing else {
            editorFocused = true
            return
        }
        isLoadingOriginal = true
        defer {
            isLoadingOriginal = false
            editorFocused = true
        }

        do {
            let original = try await EhAPI.shared.getEditComment(
                apiUid: apiUid, apiKey: apiKey,
                gid: gid, token: token, commentId: editing.id
            )
            text = original.comment
        } catch {
            // 取不回原文时不要静默塞入渲染过的 HTML —— 那样用户会把自己的 BBCode 改没
            errorMessage = "取不回评论原文（\(EhError.localizedMessage(for: error))），"
                + "现在提交会覆盖掉原有格式。"
        }
    }

    // MARK: - 提交

    private func submit() async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            let list = try await EhAPI.shared.commentGallery(
                url: galleryUrl,
                comment: text,
                editId: editing.map { String($0.id) }
            )
            onPosted(list)
            dismiss()
        } catch {
            errorMessage = EhError.localizedMessage(for: error)
        }
    }
}

/// sheet(item:) 的包装 —— nil comment 表示新发表
struct CommentComposeTarget: Identifiable {
    let comment: GalleryComment?
    var id: Int64 { comment?.id ?? -1 }
}
