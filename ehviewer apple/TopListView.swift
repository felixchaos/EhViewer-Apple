//
//  TopListView.swift
//  ehviewer apple
//
//  排行榜视图 - 7 个类别 × 4 个时间维度
//

import SwiftUI
import EhModels
import EhAPI

struct TopListView: View {
    @State private var vm = TopListViewModel()
    @State private var selectedCategory = 0
    @State private var selectedPeriod = 0

    /// 被推入父导航栈时，不创建自己的 NavigationStack，避免嵌套
    private var isPushed: Bool = false

    private let periods = ["全部时间", "过去一年", "过去一个月", "昨天"]

    init(isPushed: Bool = false) {
        self.isPushed = isPushed
    }

    /// 从排行榜链接中解析画廊 gid 和 token
    /// href 格式: https://e-hentai.org/g/12345/abcdef1234/ 或 /g/12345/abcdef1234/
    private static func parseGalleryHref(_ href: String?) -> (gid: Int64, token: String)? {
        guard let href else { return nil }
        // 匹配 /g/{gid}/{token}/ 模式
        let pattern = #"/g/(\d+)/([0-9a-f]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: href, range: NSRange(href.startIndex..., in: href)),
              match.numberOfRanges >= 3 else { return nil }
        guard let gidRange = Range(match.range(at: 1), in: href),
              let tokenRange = Range(match.range(at: 2), in: href),
              let gid = Int64(href[gidRange]) else { return nil }
        return (gid, String(href[tokenRange]))
    }

    var body: some View {
        if isPushed {
            topListContent
        } else {
            NavigationStack {
                topListContent
            }
        }
    }

    private var topListContent: some View {
        VStack(spacing: 0) {
            // 类别选择
            Picker("类别", selection: $selectedCategory) {
                ForEach(Array(vm.categoryNames.enumerated()), id: \.offset) { i, name in
                    Text(name).tag(i)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .disabled(vm.categoryNames.isEmpty)

            // 时间维度用琥珀分段控件。类别项数多且名字长，仍用系统 Picker——
            // 塞进等宽分段会挤成一堆截断的字。
            EhSegmented(
                items: periods.indices.map { ($0, periods[$0]) },
                selection: $selectedPeriod
            )
            .padding(.horizontal, EhSpacing.page)
            .padding(.bottom, 10)
            .disabled(vm.categoryNames.isEmpty)

            if vm.isLoading {
                ProgressView("加载排行榜...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = vm.errorMessage {
                EhStateView(
                    kind: .error(title: "排行榜加载失败", message: error),
                    primaryAction: ("重试", { Task { await vm.load() } })
                )
            } else {
                let items = vm.items(for: selectedCategory, period: selectedPeriod)
                List(items.indices, id: \.self) { idx in
                    let item = items[idx]
                    if let parsed = Self.parseGalleryHref(item.href) {
                        NavigationLink {
                            GalleryDetailView(gallery: GalleryInfo(
                                gid: parsed.gid,
                                token: parsed.token,
                                title: item.text
                            ))
                            .id(parsed.gid)
                        } label: {
                            TopListRow(rank: idx + 1, item: item)
                        }
                    } else {
                        TopListRow(rank: idx + 1, item: item)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("排行榜")
        .onChange(of: vm.categoryNames) { _, names in
            if selectedCategory >= names.count {
                selectedCategory = 0
            }
        }
        .task { await vm.load() }
    }
}

struct TopListRow: View {
    let rank: Int
    let item: TopListItem

    var body: some View {
        HStack(spacing: EhSpacing.row) {
            // 26pt 固定宽的排名列：名次要能在竖直方向连成一列扫下来，
            // 宽度随位数变化就对不齐了
            Text("\(rank)")
                .font(EhFont.mono(15, weight: rank <= 3 ? .bold : .regular))
                .foregroundStyle(rankColor)
                .frame(width: 26, alignment: .trailing)

            Text(item.text)
                .font(EhFont.body)
                .foregroundStyle(EhColor.label)
                .lineLimit(2)

            Spacer(minLength: 4)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { EhHairline(inset: 26 + EhSpacing.row) }
    }

    /// 前三名统一用琥珀。金/银/铜三色在深色底上彼此难分，
    /// 而「是不是前三」本身才是这里要传达的信息。
    private var rankColor: Color {
        rank <= 3 ? EhColor.accent : EhColor.tertiaryLabel
    }
}

// MARK: - ViewModel

@Observable
class TopListViewModel {
    var isLoading = false
    var errorMessage: String?
    var detail: TopListDetail?

    var categoryNames: [String] {
        detail?.lists.map { $0.name } ?? []
    }

    func load() async {
        guard !isLoading else { return }
        await MainActor.run {
            isLoading = true
            errorMessage = nil
        }

        do {
            let url = EhURL.topListUrl()
            let parsed = try await EhAPI.shared.getTopList(url: url)
            await MainActor.run {
                self.detail = parsed
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = EhError.localizedMessage(for: error)
                self.isLoading = false
            }
        }
    }

    func items(for categoryIndex: Int, period: Int) -> [TopListItem] {
        guard let detail, categoryIndex >= 0, categoryIndex < detail.lists.count else { return [] }
        let category = detail.lists[categoryIndex]
        switch period {
        case 1: return category.pastYear
        case 2: return category.pastMonth
        case 3: return category.yesterday
        default: return category.allTime
        }
    }
}

#Preview {
    TopListView()
}
