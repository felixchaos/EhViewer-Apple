//
//  ProfileView.swift
//  ehviewer apple
//
//  账号资料 + 图片配额 — 对齐 Android GetProfileScene / HomeScene 的配额面板
//
//  `getProfile` 以前只用来在登录后取一次头像和昵称，`getHomeDetail` / `resetLimit`
//  更是写好后从来没有任何界面调用过。图片配额是 E-Hentai 最常被关心的状态之一
//  （超了就 509，看不了图），值得有个能随时查看和重置的地方。
//

import SwiftUI
import EhModels
import EhAPI
import EhSettings

struct ProfileView: View {
    @State private var profile: ProfileResult?
    @State private var quota: HomeDetail?
    @State private var isLoading = true
    @State private var isResetting = false
    @State private var errorMessage: String?
    @State private var resetResult: String?

    var body: some View {
        Form {
            accountSection
            quotaSection

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("账号资料")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: - 账号

    private var accountSection: some View {
        Section {
            HStack(spacing: 14) {
                avatar
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile?.displayName ?? AppSettings.shared.displayName ?? "未登录")
                        .font(.headline)
                    if let uid = AppSettings.shared.userId, !uid.isEmpty {
                        Text("UID \(uid)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if isLoading { ProgressView().controlSize(.small) }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var avatar: some View {
        let url = profile?.avatar ?? AppSettings.shared.avatar
        CachedAsyncImage(url: URL(string: url ?? "")) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .foregroundStyle(.tertiary)
        }
        .frame(width: 52, height: 52)
        .clipShape(Circle())
    }

    // MARK: - 图片配额

    @ViewBuilder
    private var quotaSection: some View {
        Section {
            if let quota, quota.totalLimit > 0 {
                let used = Double(quota.currentUsed)
                let total = Double(quota.totalLimit)
                let ratio = min(1, max(0, used / total))

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("已用")
                        Spacer()
                        Text("\(quota.currentUsed) / \(quota.totalLimit)")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: ratio)
                        // 快满了变色 —— 超了就是 509，看不了图
                        .tint(ratio > 0.9 ? .red : (ratio > 0.7 ? .orange : .accentColor))
                }
                .padding(.vertical, 2)

                if quota.resetCost > 0 {
                    Button {
                        Task { await reset() }
                    } label: {
                        HStack {
                            Text("重置配额")
                            Spacer()
                            if isResetting {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("花费 \(quota.resetCost) GP")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(isResetting)
                }

                if let resetResult {
                    Text(resetResult)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("读取配额…").foregroundStyle(.secondary)
                }
            } else {
                Text("读不到配额信息，可能未登录。")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("图片配额")
        } footer: {
            Text("浏览图片会消耗配额，用完会出现 509 错误。配额每天自动恢复，也可以花 GP 立即重置。")
        }
    }

    // MARK: - 数据

    private func load() async {
        isLoading = true
        errorMessage = nil
        resetResult = nil

        async let profileTask = try? await EhAPI.shared.getProfile()
        async let quotaTask = try? await EhAPI.shared.getHomeDetail()
        let (p, q) = await (profileTask, quotaTask)

        profile = p
        quota = q

        // 顺手把最新头像/昵称写回设置，其它界面共用
        if let name = p?.displayName, !name.isEmpty { AppSettings.shared.displayName = name }
        if let avatar = p?.avatar, !avatar.isEmpty { AppSettings.shared.avatar = avatar }

        if p == nil && q == nil {
            errorMessage = "请求失败，检查网络或登录状态。"
        }
        isLoading = false
    }

    private func reset() async {
        isResetting = true
        defer { isResetting = false }
        do {
            let updated = try await EhAPI.shared.resetLimit()
            quota = updated
            resetResult = "已重置，当前 \(updated.currentUsed) / \(updated.totalLimit)"
        } catch {
            errorMessage = EhError.localizedMessage(for: error)
        }
    }
}
