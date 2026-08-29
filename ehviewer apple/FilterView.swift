//
//  FilterView.swift
//  ehviewer apple
//
//  标签过滤管理视图
//

import SwiftUI
import EhDatabase

struct FilterView: View {
    @State private var vm = FilterViewModel()
    @State private var showAddSheet = false

    var body: some View {
        List {
            Section {
                Text("命中规则的画廊会从所有列表里挡掉——首页、搜索、订阅、排行都算。"
                     + "规则只在本机生效，不会同步到 E-Hentai 账号。")
                    .font(EhFont.caption)
                    .foregroundStyle(EhColor.secondaryLabel)
            }

            // 快速屏蔽 (对齐 Android BlackListActivity)
            Section("常用屏蔽") {
                ForEach(vm.quickBlockPresets, id: \.tag) { preset in
                    Button {
                        vm.toggleQuickBlock(tag: preset.tag)
                    } label: {
                        HStack(spacing: EhSpacing.row) {
                            Image(systemName: vm.isTagBlocked(preset.tag)
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(vm.isTagBlocked(preset.tag)
                                                 ? EhColor.accent : EhColor.tertiaryLabel)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.displayName).foregroundStyle(EhColor.label)
                                Text(preset.tag)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(EhColor.tertiaryLabel)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            // 按类型分组，而不是按「已启用 / 已禁用」分。
            //
            // 原来那样分有两个问题：同一条规则会在两个区之间跳来跳去，
            // 用户找不到刚才那条；而且要判断「我到底屏蔽了哪些标签」，
            // 得把两个区合起来看。按类型分组之后，「我屏蔽了哪些标签」
            // 一眼就能数清，启用与否由行上的开关表达。
            ForEach(Self.modeOrder, id: \.self) { mode in
                let rules = vm.filters.filter { $0.mode == mode }
                if !rules.isEmpty {
                    Section(Self.modeTitle(mode)) {
                        ForEach(rules, id: \.id) { filter in
                            FilterRow(filter: filter) { isOn in
                                vm.setEnabled(filter, isOn)
                            }
                        }
                        .onDelete { offsets in
                            vm.delete(rules: rules, at: offsets)
                        }
                    }
                }
            }

            if vm.filters.isEmpty {
                Section {
                    Text("还没有任何规则。右上角加一条，或者在画廊详情页长按标签选「屏蔽这个标签」。")
                        .font(EhFont.caption)
                        .foregroundStyle(EhColor.secondaryLabel)
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .navigationTitle("过滤器")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAddSheet = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("新增规则")
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddFilterSheet(vm: vm)
        }
        .task { vm.loadFilters() }
    }

    private static let modeOrder = [2, 3, 0, 1, 4, 5]

    static func modeTitle(_ mode: Int) -> String {
        switch mode {
        case 0: return "标题包含"
        case 1: return "上传者"
        case 2: return "标签"
        case 3: return "标签命名空间"
        case 4: return "上传者标签"
        case 5: return "语言"
        default: return "其它"
        }
    }
}

// MARK: - Filter Row

struct FilterRow: View {
    let filter: FilterRecord
    /// 开关真正生效的回调。
    ///
    /// 此前这里是 `Toggle("", isOn: .constant(filter.enable))` 配
    /// `.onChange(of: filter.enable)`：常量绑定不会变，onChange 观察的又是
    /// 模型值——点开关什么都不会发生。整个控件是死的。
    let onToggle: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { filter.enable }, set: { onToggle($0) })) {
            // 规则用等宽字体：过滤规则常含通配符与冒号，
            // 比例字体下 `l` `1` `I` 这类字符难以核对
            Text(filter.text ?? "")
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(filter.enable ? EhColor.label : EhColor.tertiaryLabel)
        }
        .tint(EhColor.accentFill)
    }
}

// MARK: - Add Filter Sheet

struct AddFilterSheet: View {
    @Bindable var vm: FilterViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var filterText = ""
    @State private var filterMode = 2  // 默认标签过滤

    private let filterModes: [(Int, String)] = [
        (0, "标题"),
        (1, "上传者"),
        (2, "标签"),
        (3, "标签命名空间"),
        (4, "上传者标签"),
        (5, "语言")
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("过滤内容") {
                    TextField("输入要过滤的文本", text: $filterText)

                    Picker("过滤类型", selection: $filterMode) {
                        ForEach(filterModes, id: \.0) { mode, name in
                            Text(name).tag(mode)
                        }
                    }
                }

                Section {
                    Text(filterDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("添加过滤器")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        vm.addFilter(text: filterText, mode: filterMode)
                        dismiss()
                    }
                    .disabled(filterText.isEmpty)
                }
            }
        }
    }

    private var filterDescription: String {
        switch filterMode {
        case 0: return "含有此文本的标题将被过滤"
        case 1: return "此上传者的画廊将被过滤"
        case 2: return "含有此标签的画廊将被过滤 (格式: namespace:tag)"
        case 3: return "含有此命名空间下任何标签的画廊将被过滤"
        case 4: return "含有此上传者标签的画廊将被过滤"
        case 5: return "此语言的画廊将被过滤"
        default: return ""
        }
    }
}

// MARK: - ViewModel

@Observable
class FilterViewModel {
    var filters: [FilterRecord] = []

    // 快速屏蔽预设 (对齐 Android BlackList)
    struct QuickBlockPreset {
        let displayName: String
        let tag: String
    }

    let quickBlockPresets: [QuickBlockPreset] = [
        QuickBlockPreset(displayName: "扶她 (Futanari)", tag: "female:futanari"),
        QuickBlockPreset(displayName: "R-18G (猎奇)", tag: "mixed:guro"),
        QuickBlockPreset(displayName: "人兽 (Bestiality)", tag: "female:bestiality"),
        QuickBlockPreset(displayName: "兽人 (Furry)", tag: "male:furry"),
        QuickBlockPreset(displayName: "NTR (寝取)", tag: "female:netorare"),
        QuickBlockPreset(displayName: "药物 (Drug)", tag: "female:drugs"),
    ]

    func isTagBlocked(_ tag: String) -> Bool {
        filters.contains { $0.mode == 2 && $0.text == tag && $0.enable }
    }

    /// 常用屏蔽是个开关，不是单向按钮：点第二下要能取消。
    /// 此前只有「屏蔽」按钮，屏蔽完变成一个对勾，想撤销得去下面的列表里找。
    func toggleQuickBlock(tag: String) {
        if let existing = filters.first(where: { $0.mode == 2 && $0.text == tag }) {
            if let id = existing.id { try? EhDatabase.shared.deleteFilter(id: id) }
            loadFilters()
            notifyChanged()
            EhToast.info("已取消屏蔽「\(tag)」")
        } else {
            addFilter(text: tag, mode: 2)
        }
    }

    func loadFilters() {
        do {
            filters = try EhDatabase.shared.getAllFilters()
        } catch {
            debugLog("Failed to load filters: \(error)")
        }
    }

    func addFilter(text: String, mode: Int) {
        let record = FilterRecord(mode: mode, text: text, enable: true)
        do {
            try EhDatabase.shared.insertFilter(record)
            loadFilters()
            notifyChanged()
            EhToast.success("已添加规则")
        } catch {
            EhToast.failure("添加规则失败")
            debugLog("Failed to add filter: \(error)")
        }
    }

    /// 原地改启用状态。此前是「删掉再插入」，id 会变、列表顺序会跳。
    func setEnabled(_ filter: FilterRecord, _ enabled: Bool) {
        var updated = filter
        updated.enable = enabled
        do {
            try EhDatabase.shared.updateFilter(updated)
            loadFilters()
            notifyChanged()
        } catch {
            EhToast.failure("改不动这条规则")
            debugLog("Failed to toggle filter: \(error)")
        }
    }

    func delete(rules: [FilterRecord], at offsets: IndexSet) {
        for index in offsets {
            guard let id = rules[index].id else { continue }
            try? EhDatabase.shared.deleteFilter(id: id)
        }
        loadFilters()
        notifyChanged()
    }

    /// 让过滤引擎重新加载 —— 不发这个通知，改完规则要重启 App 才生效
    private func notifyChanged() {
        NotificationCenter.default.post(name: .galleryFiltersChanged, object: nil)
    }


}

#Preview {
    NavigationStack {
        FilterView()
    }
}
