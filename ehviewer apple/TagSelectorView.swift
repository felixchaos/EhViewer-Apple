//
//  TagSelectorView.swift
//  ehviewer apple
//
//  标签选择器 — 对齐 Android 上游 2026-03 新增的 TagSelectorActivity
//
//  搜索框里手打 `f:"big breasts$"` 这种语法既难记又容易打错，
//  这里按命名空间分组浏览，点一下就拼进搜索框。
//  数据直接来自已有的 EhTagDatabase（含中文翻译），不需要额外接口。
//

import SwiftUI
import EhSettings

struct TagSelectorView: View {
    /// 选中的标签以搜索语法形式回传，如 `f:"big breasts$"`
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var namespaces: [String] = []
    @State private var selectedNamespace = "female"
    @State private var filter = ""
    @State private var tags: [TagEntry] = []
    @State private var picked: [String] = []

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 8)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if namespaces.isEmpty {
                    ContentUnavailableView {
                        Label("标签数据库还没下载", systemImage: "tag.slash")
                    } description: {
                        Text("到「设置 → 更新标签翻译数据库」下载后即可使用。")
                    }
                } else {
                    namespacePicker
                    Divider()
                    tagGrid
                }
            }
            .navigationTitle("选择标签")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $filter, prompt: "在本组内筛选")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("加入 (\(picked.count))") {
                        picked.forEach(onPick)
                        dismiss()
                    }
                    .disabled(picked.isEmpty)
                }
            }
            .task { await loadNamespaces() }
            .onChange(of: selectedNamespace) { _, _ in reloadTags() }
            .onChange(of: filter) { _, _ in reloadTags() }
        }
    }

    // MARK: - 分组切换

    private var namespacePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(namespaces, id: \.self) { namespace in
                    let isSelected = namespace == selectedNamespace
                    Button {
                        selectedNamespace = namespace
                    } label: {
                        Text(Self.displayName(namespace))
                            .font(.footnote.weight(isSelected ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                isSelected ? Color.accentColor : Color.secondary.opacity(0.15),
                                in: Capsule()
                            )
                            .foregroundStyle(isSelected ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
    }

    // MARK: - 标签网格

    private var tagGrid: some View {
        ScrollView {
            if tags.isEmpty {
                Text(filter.isEmpty ? "这一组暂时没有标签" : "没有匹配的标签")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            } else {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(tags) { tag in
                        tagChip(tag)
                    }
                }
                .padding()
            }
        }
    }

    private func tagChip(_ tag: TagEntry) -> some View {
        let keyword = EhTagDatabase.rebuildKeyword(tag.english)
        let isPicked = picked.contains(keyword)

        return Button {
            if isPicked {
                picked.removeAll { $0 == keyword }
            } else {
                picked.append(keyword)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(tag.chinese.isEmpty ? tag.bareEnglish : tag.chinese)
                    .font(.footnote)
                    .lineLimit(1)
                // 中英都显示 —— 搜索语法用的是英文，只给中文会让人搜不到
                if !tag.chinese.isEmpty {
                    Text(tag.bareEnglish)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                isPicked ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isPicked ? Color.accentColor : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 数据

    private func loadNamespaces() async {
        let available = EhTagDatabase.shared.availableNamespaces()
        namespaces = available
        if let first = available.first, !available.contains(selectedNamespace) {
            selectedNamespace = first
        }
        reloadTags()
    }

    private func reloadTags() {
        tags = EhTagDatabase.shared
            .tags(inNamespace: selectedNamespace, filter: filter)
            .map { TagEntry(chinese: $0.chinese, english: $0.english) }
    }

    private static func displayName(_ namespace: String) -> String {
        switch namespace {
        case "female":    return "女性"
        case "male":      return "男性"
        case "mixed":     return "混合"
        case "artist":    return "艺术家"
        case "group":     return "团体"
        case "parody":    return "原作"
        case "character": return "角色"
        case "cosplayer": return "扮演者"
        case "language":  return "语言"
        case "other":     return "其他"
        case "reclass":   return "重分类"
        case "misc":      return "杂项"
        default:          return namespace
        }
    }
}

struct TagEntry: Identifiable, Hashable {
    let chinese: String
    /// 完整 `namespace:tag`
    let english: String

    var id: String { english }

    /// 去掉命名空间前缀后的标签本体
    var bareEnglish: String {
        english.split(separator: ":", maxSplits: 1).last.map(String.init) ?? english
    }
}
