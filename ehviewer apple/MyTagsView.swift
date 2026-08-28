//
//  MyTagsView.swift
//  ehviewer apple
//
//  我的标签 (订阅标签管理) — 对齐 Android MyTagsActivity
//
//  接口 (getWatchedList / addTag / deleteWatchedTag) 和解析器早就写好了，
//  之前设置页里那一项只是用浏览器打开网页。这里换成原生页面。
//

import SwiftUI
import EhModels
import EhAPI
import EhSettings

struct MyTagsView: View {
    @State private var tags: [UserTag] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var busyTagId: String?
    @State private var showAddSheet = false
    @State private var newTagName = ""

    private var myTagsUrl: String {
        EhURL.myTagsUrl(for: AppSettings.shared.gallerySite)
    }

    var body: some View {
        Group {
            if isLoading && tags.isEmpty {
                ProgressView("读取订阅标签…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, tags.isEmpty {
                ContentUnavailableView {
                    Label("读不到订阅标签", systemImage: "tag.slash")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("重试") { Task { await load() } }
                }
            } else if tags.isEmpty {
                ContentUnavailableView {
                    Label("还没有订阅标签", systemImage: "tag")
                } description: {
                    Text("订阅标签后，「订阅」列表只会显示带这些标签的新画廊。")
                } actions: {
                    Button("添加标签") { showAddSheet = true }
                }
            } else {
                list
            }
        }
        .navigationTitle("我的标签")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddSheet = true
                } label: {
                    Label("添加标签", systemImage: "plus")
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .alert("添加订阅标签", isPresented: $showAddSheet) {
            TextField("如 female:big breasts", text: $newTagName)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            Button("添加") { Task { await add() } }
            Button("取消", role: .cancel) { newTagName = "" }
        } message: {
            Text("填 E-Hentai 的完整标签名，带命名空间，例如 artist:xxx。")
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(tags) { tag in
                    row(tag)
                }
                .onDelete { indexSet in
                    Task {
                        for index in indexSet { await remove(tags[index]) }
                    }
                }
            } footer: {
                Text("共 \(tags.count) 个标签。左滑删除。")
            }
        }
    }

    private func row(_ tag: UserTag) -> some View {
        HStack(spacing: EhSpacing.row) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    // 命名空间单独着色：订阅标签往往几十上百条，
                    // 按命名空间分辨比逐字读整串快得多
                    if let ns = namespace(of: tag.tagName) {
                        Text(ns)
                            .font(EhFont.footnote.weight(.semibold))
                            .foregroundStyle(EhColor.accent)
                    }
                    Text(bareName(of: tag.tagName))
                        .font(EhFont.body)
                        .foregroundStyle(EhColor.label)
                }
                // 中文翻译能显示就显示 —— 光看英文标签名不好认
                if let translated = EhTagDatabase.shared.getTranslation(tag.tagName),
                   translated != tag.tagName {
                    Text(translated)
                        .font(EhFont.meta)
                        .foregroundStyle(EhColor.secondaryLabel)
                }
            }

            Spacer(minLength: 0)

            if busyTagId == tag.userTagId {
                ProgressView().controlSize(.small)
            } else {
                if tag.hidden {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 11))
                        .foregroundStyle(EhColor.tertiaryLabel)
                }
                if tag.tagWeight != 0 {
                    // 权重条：数字本身不直观，一条相对长度能让「这个比那个更重」
                    // 在一列里横向可比
                    HStack(spacing: 6) {
                        ZStack(alignment: tag.tagWeight > 0 ? .leading : .trailing) {
                            Capsule().fill(EhColor.fill)
                            Capsule()
                                .fill(tag.tagWeight > 0 ? EhColor.success : EhColor.danger)
                                .frame(width: 40 * min(1, abs(Double(tag.tagWeight)) / 10))
                        }
                        .frame(width: 40, height: 3)

                        Text(tag.tagWeight > 0 ? "+\(tag.tagWeight)" : "\(tag.tagWeight)")
                            .font(EhFont.mono(12, weight: .medium))
                            .foregroundStyle(tag.tagWeight > 0 ? EhColor.success : EhColor.danger)
                            .frame(width: 30, alignment: .trailing)
                    }
                }
            }
        }
    }

    /// "female:glasses" → "female"
    private func namespace(of tag: String) -> String? {
        guard let idx = tag.firstIndex(of: ":"), idx != tag.startIndex else { return nil }
        return String(tag[tag.startIndex..<idx])
    }

    /// "female:glasses" → "glasses"
    private func bareName(of tag: String) -> String {
        guard let idx = tag.firstIndex(of: ":") else { return tag }
        return String(tag[tag.index(after: idx)...])
    }

    // MARK: - 数据

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            tags = try await EhAPI.shared.getWatchedList(url: myTagsUrl).userTags
        } catch {
            errorMessage = EhError.localizedMessage(for: error)
        }
        isLoading = false
    }

    private func add() async {
        let name = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        newTagName = ""
        guard !name.isEmpty else { return }

        do {
            var tag = UserTag()
            tag.tagName = name
            tag.watched = true
            tags = try await EhAPI.shared.addTag(url: myTagsUrl, tag: tag).userTags
        } catch {
            errorMessage = EhError.localizedMessage(for: error)
        }
    }

    private func remove(_ tag: UserTag) async {
        busyTagId = tag.userTagId
        defer { busyTagId = nil }
        do {
            tags = try await EhAPI.shared.deleteWatchedTag(url: myTagsUrl, tag: tag).userTags
        } catch {
            errorMessage = EhError.localizedMessage(for: error)
        }
    }
}
