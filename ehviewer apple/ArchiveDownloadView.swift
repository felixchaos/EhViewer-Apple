//
//  ArchiveDownloadView.swift
//  ehviewer apple
//
//  归档下载 — 对齐 Android GalleryDetailScene 的「Download Archive」对话框
//  (issue #3「希望增加与原版一样的下载到 h@h 选项卡」)
//
//  两条路径，对应页面上的两块内容：
//    · H@H 下载 — 把任务派给你自己的 H@H 客户端，由它在后台落盘，不消耗 GP
//    · 归档下载 — 服务端现打一个 zip，消耗 GP / Credits，拿到直链后交给系统下载
//

import SwiftUI
import EhModels
import EhAPI
import EhSettings

struct ArchiveDownloadView: View {
    let gid: Int64
    let token: String
    /// 详情页解析出的 archiver_key 链接
    let archiveUrl: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var isLoading = true
    @State private var loadError: String?

    // H@H
    @State private var paramOr = ""
    @State private var resolutions: [ArchiveResolution] = []
    @State private var dispatchingRes: String?
    @State private var hathMessage: HathMessage?

    // Archiver
    @State private var archiver: ArchiverData?
    @State private var preparingKind: ArchiverKind?
    @State private var readyLink: ReadyLink?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("读取归档信息…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    ContentUnavailableView {
                        Label("读不到归档信息", systemImage: "archivebox")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("重试") { Task { await load() } }
                    }
                } else {
                    form
                }
            }
            .navigationTitle("归档下载")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task { await load() }
            .alert(item: $hathMessage) { message in
                Alert(title: Text(message.title),
                      message: Text(message.body),
                      dismissButton: .default(Text("好")))
            }
            .sheet(item: $readyLink) { link in
                ArchiveLinkSheet(link: link)
            }
        }
    }

    // MARK: - 表单

    private var form: some View {
        Form {
            // 访客看到的是两块空壳，得说清楚为什么
            if !AppSettings.shared.isLogin {
                Section {
                    Label("归档与 H@H 都需要登录账号后才能使用。", systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if resolutions.isEmpty {
                    Text(AppSettings.shared.isLogin
                         ? "这本没有可用的 H@H 规格"
                         : "登录后才会列出可选规格")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(resolutions) { item in
                        Button {
                            Task { await dispatchToHath(item) }
                        } label: {
                            HStack {
                                Text(item.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if dispatchingRes == item.res {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.down.circle")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .disabled(dispatchingRes != nil)
                    }
                }
            } header: {
                Text("H@H 下载")
            } footer: {
                Text("任务会派给你账号下的 H@H 客户端，由它在后台下载，不消耗 GP。需要先在网站上绑定过 H@H 客户端。")
            }

            if let archiver {
                Section {
                    archiverRow(.original, cost: archiver.originalCost, size: archiver.originalSize,
                                url: archiver.originalUrl)
                    archiverRow(.resample, cost: archiver.resampleCost, size: archiver.resampleSize,
                                url: archiver.resampleUrl)
                } header: {
                    Text("归档下载")
                } footer: {
                    if let funds = archiver.funds, !funds.isEmpty {
                        Text("余额：\(funds)")
                    } else {
                        Text("服务端现打包，会消耗 GP 或 Credits。")
                    }
                }
            }
        }
    }

    private func archiverRow(_ kind: ArchiverKind, cost: String?, size: String?, url: String?) -> some View {
        Button {
            guard let url else { return }
            Task { await prepareArchive(kind: kind, formUrl: url) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title)
                        .foregroundStyle(url == nil ? .secondary : .primary)
                    let detail = [size, cost].compactMap { $0 }.filter { !$0.isEmpty }
                    Text(detail.isEmpty ? "不可用" : detail.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if preparingKind == kind {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "square.and.arrow.down")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .disabled(url == nil || preparingKind != nil)
    }

    // MARK: - 数据

    private func load() async {
        isLoading = true
        loadError = nil

        // 两块内容来自同一个页面，但解析方式不同，分别取
        async let listTask = try? await EhAPI.shared.getArchiveList(url: archiveUrl, gid: gid, token: token)
        async let archiverTask = try? await EhAPI.shared.getArchiver(url: archiveUrl, gid: gid, token: token)
        let (list, archiverData) = await (listTask, archiverTask)

        if let list {
            paramOr = list.paramOr
            resolutions = list.archives.map { ArchiveResolution(res: $0.0, name: $0.1) }
        }
        archiver = archiverData

        if list == nil && archiverData == nil {
            loadError = "请求失败，检查网络或稍后再试。"
        }
        isLoading = false
    }

    private func dispatchToHath(_ item: ArchiveResolution) async {
        dispatchingRes = item.res
        defer { dispatchingRes = nil }
        do {
            try await EhAPI.shared.downloadArchive(gid: gid, token: token, or: paramOr, res: item.res)
            hathMessage = HathMessage(
                title: "已派发",
                body: "「\(item.name)」已经交给你的 H@H 客户端，下载完成后在客户端本地目录查看。"
            )
        } catch EhError.noHathClient {
            hathMessage = HathMessage(
                title: "还没有 H@H 客户端",
                body: "这个功能需要先在 E-Hentai 网站上给账号绑定一个 H@H 客户端。"
            )
        } catch {
            hathMessage = HathMessage(title: "派发失败", body: EhError.localizedMessage(for: error))
        }
    }

    private func prepareArchive(kind: ArchiverKind, formUrl: String) async {
        preparingKind = kind
        defer { preparingKind = nil }
        do {
            let link = try await EhAPI.shared.downloadArchiver(
                url: formUrl,
                referer: archiveUrl,
                dltype: kind.dltype,
                dlcheck: kind.dlcheck
            )
            if let link, !link.isEmpty {
                readyLink = ReadyLink(url: link, title: kind.title)
            } else {
                hathMessage = HathMessage(title: "没拿到下载链接", body: "服务端没有返回直链，可能是余额不足。")
            }
        } catch {
            hathMessage = HathMessage(title: "请求失败", body: EhError.localizedMessage(for: error))
        }
    }
}

// MARK: - 附属类型

struct ArchiveResolution: Identifiable, Hashable {
    /// 表单里的 res 值 (如 "780x")
    let res: String
    /// 展示名 (如 "780x · 12 MB")
    let name: String
    var id: String { res }
}

enum ArchiverKind: String, Identifiable {
    case original, resample
    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "原始档案"
        case .resample: return "重采样档案"
        }
    }

    /// 对齐 Android ArchiverDownloadDialog
    var dltype: String {
        switch self {
        case .original: return "org"
        case .resample: return "res"
        }
    }

    var dlcheck: String {
        switch self {
        case .original: return "Download Original Archive"
        case .resample: return "Download Resample Archive"
        }
    }
}

struct HathMessage: Identifiable {
    let id = UUID()
    let title: String
    let body: String
}

struct ReadyLink: Identifiable {
    let id = UUID()
    let url: String
    let title: String
}

/// 拿到直链后的落地方式
///
/// 归档是服务端现打的 zip，App 内下载下来也没有解压和文件管理界面，
/// 所以交给系统：用浏览器下载能直接存进「文件」，或者分享给别的 App。
private struct ArchiveLinkSheet: View {
    let link: ReadyLink

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(link.url)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                } header: {
                    Text("下载链接已就绪")
                } footer: {
                    Text("链接有时效，尽快下载。用浏览器打开可以直接存进「文件」。")
                }

                Section {
                    if let url = URL(string: link.url) {
                        Button {
                            openURL(url)
                            dismiss()
                        } label: {
                            Label("在浏览器中下载", systemImage: "safari")
                        }

                        ShareLink(item: url) {
                            Label("分享链接", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            .navigationTitle(link.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
