//
//  QuickSearchView.swift
//  ehviewer apple
//
//  快速搜索管理视图
//

import SwiftUI
import EhModels
import EhDatabase
import EhSettings

struct QuickSearchView: View {
    @State private var vm = QuickSearchViewModel()
    @State private var showAddSheet = false
    @Binding var selectedSearch: QuickSearchRecord?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if vm.searches.isEmpty {
                    ContentUnavailableView("暂无快速搜索",
                        systemImage: "magnifyingglass",
                        description: Text("点击右上角添加常用搜索词"))
                } else {
                    searchList
                }
            }
            .navigationTitle("快速搜索")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AddQuickSearchSheet(vm: vm)
            }
        }
        .task {
            vm.loadSearches()
        }
    }

    private var searchList: some View {
        List {
            ForEach(vm.searches, id: \.id) { search in
                Button {
                    selectedSearch = search
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(search.name ?? Self.translateKeyword(search.keyword) ?? "未命名")
                                .font(.body)
                                .foregroundStyle(.primary)

                            if let keyword = search.keyword, !keyword.isEmpty {
                                Text(keyword)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
            .onDelete { indexSet in
                vm.delete(at: indexSet)
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
    }

    /// 将搜索关键词中的英文标签翻译为中文
    /// 例: `f:"big breasts$"` → `女性:巨乳`
    static func translateKeyword(_ keyword: String?) -> String? {
        guard let keyword = keyword, !keyword.isEmpty else { return nil }
        let db = EhTagDatabase.shared
        guard db.isLoaded else { return keyword }

        // 将搜索词拆分为独立的标签/词，逐个翻译后重组
        // 搜索词格式: `f:"big breasts$"` 或 `artist:name` 或纯文本
        var result: [String] = []
        var remaining = keyword.trimmingCharacters(in: .whitespaces)

        while !remaining.isEmpty {
            remaining = remaining.trimmingCharacters(in: .init(charactersIn: " "))
            guard !remaining.isEmpty else { break }

            // 尝试匹配 prefix:"tag$" 或 prefix:tag 或 "tag$" 或纯词
            let translated = extractAndTranslateNextToken(&remaining, db: db)
            result.append(translated)
        }

        let joined = result.joined(separator: " ")
        return joined.isEmpty ? keyword : joined
    }

    /// 从搜索字符串开头提取并翻译一个标签
    private static func extractAndTranslateNextToken(_ text: inout String, db: EhTagDatabase) -> String {
        // 查找 namespace 前缀 (f:, m:, a:, ... 或 female:, male:, ...)
        var prefix = ""
        var namespace = ""
        if let colonIdx = text.firstIndex(of: ":"), colonIdx < text.index(text.startIndex, offsetBy: min(15, text.count)) {
            let prefixPart = String(text[..<colonIdx])
            // 检查是否是有效的命名空间前缀
            let shortPrefix = prefixPart + ":"
            if EhTagDatabase.prefixToNamespace[shortPrefix] != nil {
                prefix = shortPrefix
                namespace = EhTagDatabase.prefixToNamespace[shortPrefix] ?? ""
                text = String(text[text.index(after: colonIdx)...])
            } else if EhTagDatabase.namespaceToPrefix[prefixPart] != nil {
                namespace = prefixPart
                prefix = EhTagDatabase.namespaceToPrefix[prefixPart] ?? ""
                text = String(text[text.index(after: colonIdx)...])
            }
        }

        // 提取标签内容
        var tag: String
        if text.hasPrefix("\"") {
            // 带引号: 提取到匹配的 " 或 $"
            text.removeFirst() // 移除开头的 "
            if let endQuoteIdx = text.firstIndex(of: "\"") {
                tag = String(text[..<endQuoteIdx])
                text = String(text[text.index(after: endQuoteIdx)...])
            } else {
                tag = text
                text = ""
            }
        } else {
            // 无引号: 取到下一个空格
            if let spaceIdx = text.firstIndex(of: " ") {
                tag = String(text[..<spaceIdx])
                text = String(text[spaceIdx...])
            } else {
                tag = text
                text = ""
            }
        }

        // 清理标签: 去掉尾部 $
        tag = tag.trimmingCharacters(in: .init(charactersIn: "$"))

        guard !tag.isEmpty else { return prefix.isEmpty ? "" : prefix }

        // 尝试翻译
        let lookupKey = namespace.isEmpty ? tag : "\(namespace):\(tag)"
        if let translation = db.getTranslation(lookupKey) {
            // 翻译命名空间前缀
            let nsDisplay = translateNamespace(namespace)
            if nsDisplay.isEmpty {
                return translation
            }
            return "\(nsDisplay):\(translation)"
        }

        // 无翻译: 返回原始内容
        if prefix.isEmpty {
            return tag
        }
        return "\(prefix)\(tag)"
    }

    /// 翻译命名空间为中文
    private static func translateNamespace(_ namespace: String) -> String {
        switch namespace {
        case "female": return "女性"
        case "male": return "男性"
        case "artist": return "艺术家"
        case "cosplayer": return "Coser"
        case "character": return "角色"
        case "group": return "团体"
        case "language": return "语言"
        case "misc", "": return ""
        case "mixed": return "混合"
        case "other": return "其他"
        case "parody": return "原作"
        case "reclass": return "重分类"
        case "rows": return "行名"
        default: return namespace
        }
    }
}

// MARK: - Quick Search Drawer Content (对齐 Android QuickSearchScene / drawer_list.xml)

struct QuickSearchDrawerContent: View {
    @State private var vm = QuickSearchViewModel()
    @Binding var selectedSearch: QuickSearchRecord?
    let currentKeyword: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 顶部标题栏 (对齐 Android drawer header)
            HStack {
                Text("快速搜索")
                    .font(.headline)
                Spacer()
                // 收藏当前搜索词 (对齐 Android: 抽屉顶部添加按钮)
                Button {
                    let record = QuickSearchRecord(
                        name: nil,
                        mode: 0,
                        category: 0,
                        keyword: currentKeyword
                    )
                    vm.addSearch(record)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
                .disabled(currentKeyword.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // 搜索词列表
            if vm.searches.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("暂无快速搜索")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Text("点击 + 收藏当前搜索词")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(vm.searches, id: \.id) { search in
                        Button {
                            selectedSearch = search
                            onDismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(search.name ?? QuickSearchView.translateKeyword(search.keyword) ?? "未命名")
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                if let keyword = search.keyword, !keyword.isEmpty,
                                   search.name != nil {
                                    Text(QuickSearchView.translateKeyword(keyword) ?? keyword)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { vm.delete(at: $0) }
                }
                .listStyle(.plain)
            }
        }
        .task { vm.loadSearches() }
    }
}

// MARK: - Add Quick Search Sheet

struct AddQuickSearchSheet: View {
    @Bindable var vm: QuickSearchViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var keyword = ""
    @State private var minRating = 0
    @State private var selectedCategories: Set<EhCategory> = []

    private let allCategories: [EhCategory] = [
        .doujinshi, .manga, .artistCG, .gameCG, .western,
        .nonH, .imageSet, .cosplay, .asianPorn, .misc
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("名称 (可选)", text: $name)
                    TextField("搜索关键词", text: $keyword)
                }

                Section("最低评分") {
                    Picker("最低评分", selection: $minRating) {
                        Text("不限").tag(0)
                        ForEach(2...5, id: \.self) { rating in
                            HStack {
                                ForEach(0..<rating, id: \.self) { _ in
                                    Image(systemName: "star.fill")
                                        .foregroundStyle(.orange)
                                }
                            }
                            .tag(rating)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("分类筛选") {
                    ForEach(allCategories, id: \.rawValue) { category in
                        Toggle(category.name, isOn: Binding(
                            get: { selectedCategories.contains(category) },
                            set: { isOn in
                                if isOn {
                                    selectedCategories.insert(category)
                                } else {
                                    selectedCategories.remove(category)
                                }
                            }
                        ))
                    }
                }
            }
            .navigationTitle("添加快速搜索")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save()
                        dismiss()
                    }
                    .disabled(keyword.isEmpty)
                }
            }
        }
    }

    private func save() {
        let categoryMask = selectedCategories.reduce(0) { $0 | $1.rawValue }
        let record = QuickSearchRecord(
            name: name.isEmpty ? nil : name,
            mode: 0,
            category: categoryMask,
            keyword: keyword
        )
        vm.addSearch(record)
    }
}

// MARK: - ViewModel

@Observable
class QuickSearchViewModel {
    var searches: [QuickSearchRecord] = []

    func loadSearches() {
        do {
            searches = try EhDatabase.shared.getAllQuickSearches()
        } catch {
            debugLog("Failed to load quick searches: \(error)")
        }
    }

    func addSearch(_ record: QuickSearchRecord) {
        do {
            try EhDatabase.shared.insertQuickSearch(record)
            loadSearches()
        } catch {
            debugLog("Failed to add quick search: \(error)")
        }
    }

    func delete(at offsets: IndexSet) {
        for index in offsets {
            guard let id = searches[index].id else { continue }
            do {
                try EhDatabase.shared.deleteQuickSearch(id: id)
            } catch {
                debugLog("Failed to delete quick search: \(error)")
            }
        }
        searches.remove(atOffsets: offsets)
    }
}

#Preview {
    QuickSearchView(selectedSearch: .constant(nil))
}
