//
//  SearchFocusPanel.swift
//  ehviewer apple
//
//  搜索聚焦面板 — 设计稿第 2 屏
//
//  搜索框获得焦点后整屏接管，分三段：标签建议 / 最近搜索 / 快速搜索，
//  下面再放标签选择器与高级搜索两个整行入口。
//
//  之前的做法是把这些功能塞进搜索胶囊右侧的三个 15pt 图标：点按目标远小于
//  HIG 要求的 44pt，手机上基本按不中；「快速搜索」更是在改版时整个丢了。
//  设计稿本来就把它们放在聚焦面板里——那里有整行的宽度，不必和输入框抢位置。
//

import SwiftUI
import EhModels
import EhSettings

struct SearchFocusPanel: View {
    /// 输入框里的自由文本（不含已成为 token 的标签）
    let text: String
    /// 已加入的标签 token
    @Binding var tokens: [String]

    let suggestions: [GalleryListViewModel.TagSuggestionItem]
    let history: [String]

    var onClearHistory: () -> Void
    var onPickHistory: (String) -> Void
    var onOpenTagSelector: () -> Void
    var onOpenAdvancedSearch: () -> Void
    var onOpenQuickSearch: () -> Void
    var isAdvancedActive: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !suggestions.isEmpty {
                    sectionHeader("标签建议", trailing: "EhTagDatabase")
                    ForEach(suggestions) { item in
                        suggestionRow(item)
                    }
                }

                if text.isEmpty && !history.isEmpty {
                    sectionHeader("最近搜索", action: ("清除", onClearHistory))
                    // 历史用胶囊平铺而不是逐行列出：它们通常很短，
                    // 一行一条会把面板撑得很长，而用户是在里面找一个眼熟的
                    FlowLayout(spacing: 8) {
                        ForEach(history, id: \.self) { term in
                            Button {
                                onPickHistory(term)
                            } label: {
                                Text(term)
                                    .font(EhFont.caption)
                                    .foregroundStyle(EhColor.label)
                                    .lineLimit(1)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background { Capsule().fill(EhColor.fill) }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, EhSpacing.page)
                    .padding(.bottom, 6)
                }

                sectionHeader("更多方式")
                entryRow(
                    symbol: "bookmark",
                    title: "快速搜索",
                    subtitle: "保存好的搜索条件，一点即用",
                    action: onOpenQuickSearch
                )
                entryRow(
                    symbol: "tag",
                    title: "标签选择器",
                    subtitle: "按命名空间浏览，自动拼装搜索语法",
                    action: onOpenTagSelector
                )
                entryRow(
                    symbol: isAdvancedActive
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle",
                    title: "高级搜索",
                    subtitle: isAdvancedActive ? "已设置筛选条件" : "分类、评分、页数范围",
                    tint: isAdvancedActive ? EhColor.accent : EhColor.secondaryLabel,
                    action: onOpenAdvancedSearch
                )
            }
            .padding(.bottom, 24)
        }
        .background(EhColor.background)
    }

    // MARK: - 组件

    private func sectionHeader(
        _ title: String, trailing: String? = nil,
        action: (title: String, run: () -> Void)? = nil
    ) -> some View {
        HStack {
            Text(title).ehSectionHeader()
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(EhFont.footnote)
                    .foregroundStyle(EhColor.tertiaryLabel)
            }
            if let action {
                Button(action.title, action: action.run)
                    .font(EhFont.footnote)
                    .foregroundStyle(EhColor.accent)
            }
        }
        .padding(.horizontal, EhSpacing.page)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    /// 标签建议行：命名空间 + 原文 + 中文 + 是否已加入
    private func suggestionRow(_ item: GalleryListViewModel.TagSuggestionItem) -> some View {
        let already = tokens.contains(item.english)
        return Button {
            if already {
                tokens.removeAll { $0 == item.english }
            } else {
                tokens.append(item.english)
            }
            Haptics.tap()
        } label: {
            HStack(spacing: EhSpacing.row) {
                if let ns = namespace(of: item.english) {
                    Text(ns)
                        .font(EhFont.footnote.weight(.semibold))
                        .foregroundStyle(EhColor.accent)
                        .frame(width: 44, alignment: .trailing)
                } else {
                    Color.clear.frame(width: 44)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.chinese)
                        .font(EhFont.body)
                        .foregroundStyle(EhColor.label)
                    Text(item.english)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(EhColor.secondaryLabel)
                }

                Spacer(minLength: 8)

                // 明确告诉用户「这条已经加进搜索框了」——此前点完没有任何反馈，
                // 用户无从判断到底加没加上
                Image(systemName: already ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(already ? EhColor.accent : EhColor.tertiaryLabel)
            }
            .padding(.horizontal, EhSpacing.page)
            .frame(minHeight: EhSize.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { EhHairline(inset: EhSpacing.page + 56) }
    }

    private func entryRow(
        symbol: String, title: String, subtitle: String,
        tint: Color = EhColor.secondaryLabel,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: EhSpacing.row) {
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(EhFont.body).foregroundStyle(EhColor.label)
                    Text(subtitle).font(EhFont.footnote).foregroundStyle(EhColor.secondaryLabel)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(EhColor.tertiaryLabel)
            }
            .padding(.horizontal, EhSpacing.page)
            // 整行 52pt 高，远高于 44pt 的最小点按目标——
            // 这正是把它们从搜索胶囊里挪出来的原因
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { EhHairline(inset: EhSpacing.page + 36) }
    }

    /// `female:"glasses$"` → `female`
    private func namespace(of tag: String) -> String? {
        guard let idx = tag.firstIndex(of: ":"), idx != tag.startIndex else { return nil }
        return String(tag[tag.startIndex..<idx])
    }
}

// FlowLayout 复用 GalleryDetailView 里已有的实现（详情页的标签也用它），
// 不再另写一份。
