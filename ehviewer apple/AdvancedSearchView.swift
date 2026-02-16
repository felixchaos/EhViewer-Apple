//
//  AdvancedSearchView.swift
//  ehviewer apple
//
//  搜索面板 — 100% 复刻 Android SearchLayout + AdvanceSearchTable + CategoryTable
//

import SwiftUI
import EhModels

// MARK: - 搜索模式

enum SearchMode: Int, CaseIterable {
    case normal = 0
    case subscription = 1
    case uploader = 2
    case tag = 3

    var label: String {
        switch self {
        case .normal:       return "Normal search"
        case .subscription: return "Subscription search"
        case .uploader:     return "Specify uploader"
        case .tag:          return "Specify tag"
        }
    }

    var listMode: Int {
        switch self {
        case .normal:       return 0
        case .subscription: return 5
        case .uploader:     return 1
        case .tag:          return 2
        }
    }
}

// MARK: - 分类定义

private struct CategoryItem: Identifiable {
    let id = UUID()
    let category: EhCategory
    let name: String
    let color: Color
}

private let categoryGrid: [[CategoryItem]] = [
    [CategoryItem(category: .doujinshi, name: "Doujinshi", color: Color(red: 0.957, green: 0.263, blue: 0.212)),
     CategoryItem(category: .manga,     name: "Manga",     color: Color(red: 1.0,   green: 0.596, blue: 0.0))],
    [CategoryItem(category: .artistCG,  name: "Artist CG", color: Color(red: 0.984, green: 0.753, blue: 0.176)),
     CategoryItem(category: .gameCG,    name: "Game CG",   color: Color(red: 0.298, green: 0.686, blue: 0.314))],
    [CategoryItem(category: .western,   name: "Western",   color: Color(red: 0.545, green: 0.765, blue: 0.290)),
     CategoryItem(category: .nonH,      name: "Non-H",     color: Color(red: 0.129, green: 0.588, blue: 0.953))],
    [CategoryItem(category: .imageSet,  name: "Image Set", color: Color(red: 0.247, green: 0.318, blue: 0.710)),
     CategoryItem(category: .cosplay,   name: "Cosplay",   color: Color(red: 0.612, green: 0.153, blue: 0.690))],
    [CategoryItem(category: .asianPorn, name: "Asian Porn", color: Color(red: 0.585, green: 0.459, blue: 0.804)),
     CategoryItem(category: .misc,      name: "Misc",      color: Color(red: 0.941, green: 0.384, blue: 0.573))],
]

// MARK: - AdvancedSearchState

@Observable
class AdvancedSearchState {
    var searchMode: SearchMode = .normal
    var selectedCategories: Int = EhCategory.all.rawValue
    var enableAdvance = false

    var searchGalleryName = true
    var searchGalleryTags = true
    var searchGalleryDescription = false
    var searchTorrentFilenames = false
    var onlyShowWithTorrents = false
    var searchLowPowerTags = false
    var searchDownvotedTags = false
    var searchExpungedGalleries = false
    var disableLanguageFilter = false
    var disableUploaderFilter = false
    var disableTagFilter = false

    var enableMinRating = false
    var minRating = 2

    var enablePageRange = false
    var pageFrom = ""
    var pageTo = ""

    var isEnabled: Bool { enableAdvance }

    func isCategorySelected(_ cat: EhCategory) -> Bool {
        selectedCategories & cat.rawValue != 0
    }

    func toggleCategory(_ cat: EhCategory) {
        selectedCategories ^= cat.rawValue
    }

    func longPressCategory(_ cat: EhCategory) {
        if isCategorySelected(cat) {
            selectedCategories = cat.rawValue
        } else {
            selectedCategories = EhCategory.all.rawValue & ~cat.rawValue
        }
    }

    var advanceSearchValue: Int {
        guard enableAdvance else { return -1 }
        var value = 0
        if searchGalleryName { value |= 0x001 }
        if searchGalleryTags { value |= 0x002 }
        if searchGalleryDescription { value |= 0x004 }
        if searchTorrentFilenames { value |= 0x008 }
        if onlyShowWithTorrents { value |= 0x010 }
        if searchLowPowerTags { value |= 0x020 }
        if searchDownvotedTags { value |= 0x040 }
        if searchExpungedGalleries { value |= 0x080 }
        if disableLanguageFilter { value |= 0x100 }
        if disableUploaderFilter { value |= 0x200 }
        if disableTagFilter { value |= 0x400 }
        return value
    }

    var categoryValue: Int { selectedCategories == EhCategory.all.rawValue ? 0 : selectedCategories }

    var minRatingValue: Int {
        guard enableAdvance, enableMinRating else { return -1 }
        return minRating
    }

    var pageFromValue: Int {
        guard enableAdvance, enablePageRange else { return -1 }
        return Int(pageFrom) ?? -1
    }

    var pageToValue: Int {
        guard enableAdvance, enablePageRange else { return -1 }
        return Int(pageTo) ?? -1
    }

    func restore(advanceSearch: Int, minRating: Int, pageFrom: Int, pageTo: Int) {
        if advanceSearch >= 0 {
            enableAdvance = true
            searchGalleryName = advanceSearch & 0x001 != 0
            searchGalleryTags = advanceSearch & 0x002 != 0
            searchGalleryDescription = advanceSearch & 0x004 != 0
            searchTorrentFilenames = advanceSearch & 0x008 != 0
            onlyShowWithTorrents = advanceSearch & 0x010 != 0
            searchLowPowerTags = advanceSearch & 0x020 != 0
            searchDownvotedTags = advanceSearch & 0x040 != 0
            searchExpungedGalleries = advanceSearch & 0x080 != 0
            disableLanguageFilter = advanceSearch & 0x100 != 0
            disableUploaderFilter = advanceSearch & 0x200 != 0
            disableTagFilter = advanceSearch & 0x400 != 0
        } else {
            enableAdvance = false
        }
        if minRating >= 2 && minRating <= 5 {
            enableMinRating = true
            self.minRating = minRating
        } else {
            enableMinRating = false
        }
        if pageFrom > 0 || pageTo > 0 {
            enablePageRange = true
            self.pageFrom = pageFrom > 0 ? String(pageFrom) : ""
            self.pageTo = pageTo > 0 ? String(pageTo) : ""
        } else {
            enablePageRange = false
        }
    }

    func reset() {
        searchMode = .normal
        selectedCategories = EhCategory.all.rawValue
        enableAdvance = false
        searchGalleryName = true
        searchGalleryTags = true
        searchGalleryDescription = false
        searchTorrentFilenames = false
        onlyShowWithTorrents = false
        searchLowPowerTags = false
        searchDownvotedTags = false
        searchExpungedGalleries = false
        disableLanguageFilter = false
        disableUploaderFilter = false
        disableTagFilter = false
        enableMinRating = false
        minRating = 2
        enablePageRange = false
        pageFrom = ""
        pageTo = ""
    }
}

// MARK: - AdvancedSearchView

struct AdvancedSearchView: View {
    @Bindable var state: AdvancedSearchState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    normalSearchCard
                    if state.enableAdvance {
                        advanceOptionsCard
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("搜索选项")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
                #if os(iOS)
                ToolbarItem(placement: .bottomBar) {
                    Button(role: .destructive) {
                        state.reset()
                    } label: {
                        Label("重置所有选项", systemImage: "arrow.counterclockwise")
                    }
                    .tint(.red)
                }
                #else
                ToolbarItem(placement: .automatic) {
                    Button(role: .destructive) {
                        state.reset()
                    } label: {
                        Label("重置所有选项", systemImage: "arrow.counterclockwise")
                    }
                    .tint(.red)
                }
                #endif
            }
        }
        #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
    }

    // MARK: - Card 1: Normal Search

    private var normalSearchCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Normal Search")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            categoryTable.padding(.horizontal, 8)

            Divider().padding(.vertical, 8)

            searchModeGrid.padding(.horizontal, 16)

            Divider().padding(.vertical, 8)

            HStack {
                Spacer()
                Toggle("Enable advance options", isOn: $state.enableAdvance)
                    .toggleStyle(.switch)
                    .font(.subheadline)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Category Table

    private var categoryTable: some View {
        VStack(spacing: 4) {
            ForEach(Array(categoryGrid.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 4) {
                    ForEach(row) { item in
                        categoryButton(item)
                    }
                }
            }
        }
    }

    private func categoryButton(_ item: CategoryItem) -> some View {
        let isSelected = state.isCategorySelected(item.category)
        return Text(item.name)
            .font(.caption.bold())
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundStyle(isSelected ? .white : .primary)
            .background(isSelected ? item.color : Color(.systemGray5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onTapGesture { state.toggleCategory(item.category) }
            .onLongPressGesture { state.longPressCategory(item.category) }
    }

    // MARK: - Search Mode

    private var searchModeGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
            GridRow {
                searchModeRadio(.normal)
                searchModeRadio(.subscription)
            }
            GridRow {
                searchModeRadio(.uploader)
                searchModeRadio(.tag)
            }
        }
    }

    private func searchModeRadio(_ mode: SearchMode) -> some View {
        Button {
            state.searchMode = mode
        } label: {
            HStack(spacing: 6) {
                Image(systemName: state.searchMode == mode ? "largecircle.fill.circle" : "circle")
                    .font(.body)
                    .foregroundColor(state.searchMode == mode ? .accentColor : .secondary)
                Text(mode.label)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Card 2: Advance Options

    private var advanceOptionsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Advance Options")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            VStack(spacing: 0) {
                advRow {
                    advCheck("Search Gallery Name", isOn: $state.searchGalleryName)
                    advCheck("Search Gallery Tags", isOn: $state.searchGalleryTags)
                }
                advRow {
                    advCheck("Search Gallery Description", isOn: $state.searchGalleryDescription)
                    advCheck("Search Torrent Filenames", isOn: $state.searchTorrentFilenames)
                }
                advRow {
                    advCheck("Only Show With Torrents", isOn: $state.onlyShowWithTorrents)
                    advCheck("Search Low-Power Tags", isOn: $state.searchLowPowerTags)
                }
                advRow {
                    advCheck("Search Downvoted Tags", isOn: $state.searchDownvotedTags)
                    advCheck("Search Expunged Galleries", isOn: $state.searchExpungedGalleries)
                }

                Divider().padding(.vertical, 4)

                HStack {
                    advCheck("Minimum Rating:", isOn: $state.enableMinRating)
                    Spacer()
                    if state.enableMinRating {
                        Picker("", selection: $state.minRating) {
                            Text("2 stars").tag(2)
                            Text("3 stars").tag(3)
                            Text("4 stars").tag(4)
                            Text("5 stars").tag(5)
                        }
                        .labelsHidden()
                        #if os(iOS)
                        .pickerStyle(.menu)
                        #endif
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)

                HStack {
                    advCheck("Pages:", isOn: $state.enablePageRange)
                    if state.enablePageRange {
                        Spacer(minLength: 8)
                        TextField("from", text: $state.pageFrom)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                        Text("to")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("to", text: $state.pageTo)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)

                Divider().padding(.vertical, 4)

                Text("Disable default filters for:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 2)

                HStack(spacing: 4) {
                    advCheck("Language", isOn: $state.disableLanguageFilter)
                    advCheck("Uploader", isOn: $state.disableUploaderFilter)
                    advCheck("Tags", isOn: $state.disableTagFilter)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Helpers

    private func advRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 4) { content() }
            .padding(.horizontal, 16)
            .padding(.vertical, 3)
    }

    private func advCheck(_ title: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: isOn.wrappedValue ? "checkmark.square.fill" : "square")
                    .font(.body)
                    .foregroundColor(isOn.wrappedValue ? .accentColor : .secondary)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - macOS compat

#if os(macOS)
extension NSColor {
    static var systemGroupedBackground: NSColor { .windowBackgroundColor }
    static var secondarySystemGroupedBackground: NSColor { .controlBackgroundColor }
    static var systemGray5: NSColor { .separatorColor }
}
#endif

#Preview {
    AdvancedSearchView(state: AdvancedSearchState())
}
