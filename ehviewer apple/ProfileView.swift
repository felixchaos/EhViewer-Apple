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
import EhCookie
import EhSettings

struct ProfileView: View {
    private var profile: AccountProfileStore { .shared }
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
        Section("账号") {
            HStack(spacing: 14) {
                LocalAccountAvatar(bytes: profile.avatar, size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.displayTitle)
                        .font(.headline)
                    if let memberID = profile.memberID {
                        Text("UID \(memberID)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if case .loading = profile.nameState { ProgressView().controlSize(.small) }
            }
            .padding(.vertical, 4)
            if let memberID = profile.memberID {
                LocalAccountAvatarEditor(memberID: memberID)
                    .id(memberID)
                if case .failed = profile.nameState {
                    Button("重试读取用户名") { Task { await profile.refreshName(force: true) } }
                }
            }
        }
    }

    // MARK: - 图片配额

    @ViewBuilder
    private var quotaSection: some View {
        Section {
            if let quota, quota.totalLimit > 0 {
                let used = Double(quota.currentUsed)
                let total = Double(quota.totalLimit)
                let ratio = min(1, max(0, used / total))

                VStack(alignment: .leading, spacing: 10) {
                    // 大数字给「还剩多少」而不是「已用多少」：
                    // 用户真正要判断的是「今天还能不能接着看」
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(quota.totalLimit - quota.currentUsed)")
                            .font(EhFont.display)
                            .foregroundStyle(ratio > 0.9 ? EhColor.danger : EhColor.label)
                        Text("剩余 / 共 \(quota.totalLimit)")
                            .font(EhFont.meta)
                            .foregroundStyle(EhColor.tertiaryLabel)
                    }

                    ZStack(alignment: .leading) {
                        Capsule().fill(EhColor.fill)
                        GeometryReader { geo in
                            Capsule()
                                // 快满了变色 —— 超了就是 509，看不了图
                                .fill(ratio > 0.9 ? EhColor.danger
                                      : (ratio > 0.7 ? EhColor.warning : EhColor.accentFill))
                                .frame(width: geo.size.width * ratio)
                        }
                    }
                    .frame(height: 6)

                    Text("今日已用 \(quota.currentUsed)")
                        .font(EhFont.meta)
                        .foregroundStyle(EhColor.secondaryLabel)
                }
                .padding(.vertical, 6)

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
            } else if quota != nil {
                // 请求成功但没有数字额度：这个账号用的是基于 IP 的限制，
                // E-Hentai 本来就不给「已用 X / 上限 Y」，只有买了 Bronze Star
                // 或 More Pages 的账号才有。
                //
                // 这里原本一律显示「读不到配额信息，可能未登录」——把一个
                // 完全正常的状态说成登录出了问题，白白让人去排查登录。
                VStack(alignment: .leading, spacing: 6) {
                    Label("当前无配额限制", systemImage: "checkmark.circle")
                        .foregroundStyle(EhColor.success)
                    Text("该账号按 IP 限额。E-Hentai 不提供具体用量。"
                         + "Bronze Star 或 More Pages 可将配额与账号绑定，并显示用量。")
                        .font(EhFont.caption)
                        .foregroundStyle(EhColor.secondaryLabel)
                }
            } else {
                Text("读不到配额信息，检查网络后重试。")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("图片配额")
        } footer: {
            Text("浏览图片消耗配额。配额耗尽时返回 509。配额每日恢复，也可消耗 GP 重置。")
        }
    }

    // MARK: - 数据

    private func load() async {
        isLoading = true
        errorMessage = nil
        resetResult = nil

        profile.synchronize()
        let member = profile.memberID
        guard let member else {
            quota = nil
            isLoading = false
            return
        }
        #if EH_OFFLINE_UI_FIXTURE && targetEnvironment(simulator)
        if EhOfflineUIFixture.enabled {
            await profile.refreshName()
            isLoading = false
            return
        }
        #endif
        async let name: Void = profile.refreshName()
        let result = try? await EhAPI.shared.getHomeDetail()
        await name
        guard profile.memberID == member, !Task.isCancelled else {
            isLoading = false
            return
        }
        quota = result
        if result == nil { errorMessage = "无法读取图片配额。" }
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
