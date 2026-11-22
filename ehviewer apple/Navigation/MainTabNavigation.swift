import Foundation
import EhModels

// Stable app destinations. The legacy labels remain notification payloads and UI titles.
enum MainTab: String, CaseIterable {
    case home = "首页"
    case subscription = "订阅"
    case popular = "热门"
    case toplist = "排行榜"
    case favorites = "收藏"
    case downloads = "下载"
    case history = "历史"
    case settings = "设置"
    case more = "更多"
    case profile = "我的"

    static let bottomTabs: [Self] = [.home, .favorites, .downloads, .history, .profile]
    static let sidebarTabs = allCases.filter { $0 != .more }
    static let moreTabs = sidebarTabs.filter { !bottomTabs.contains($0) }

    fileprivate var browseSource: BrowseSource? {
        switch self {
        case .home: .home
        case .subscription: .subscription
        case .popular: .popular
        case .toplist: .toplist
        default: nil
        }
    }

    static func fromLaunchPage(_ page: Int) -> Self {
        // Popular and Top List are browse sources within Home, not compact tab stacks.
        switch page {
        case 3: .favorites
        case 4: .downloads
        case 5: .history
        default: .home
        }
    }

    static func adaptiveContentTabs(visitedExtras: Set<Self>, selected: Self) -> [Self] {
        bottomTabs + allCases.filter {
            !bottomTabs.contains($0) && (visitedExtras.contains($0) || $0 == selected)
        }
    }
}

enum BrowseSource: String, CaseIterable, Hashable {
    case home, search, subscription, popular, toplist
}

/// The active browse source is independent of how the window presents its navigation.
struct BrowseHomeRoute: Equatable {
    private(set) var origin: BrowseSource
    private(set) var isShowingSearch = false

    init(origin: BrowseSource) {
        precondition(origin != .search)
        self.origin = origin
    }

    var selection: BrowseSource { isShowingSearch ? .search : origin }

    mutating func select(_ source: BrowseSource) {
        guard source != selection else { return }
        if source != .search { origin = source }
        isShowingSearch = source == .search
    }

    mutating func setSearchResultsVisible(_ visible: Bool) {
        isShowingSearch = visible
    }
}

/// Shared navigation policy; iOS sidebar shortcuts and compact chrome use the same Browse stack.
struct MainTabNavigation {
    private(set) var selection: MainTab
    var browse: BrowseHomeRoute
    private let usesHomeBrowseContainer: Bool
    private var visitedExtras: Set<MainTab> = []

    init(launchPage: Int, usesHomeBrowseContainer: Bool = true) {
        self.usesHomeBrowseContainer = usesHomeBrowseContainer
        switch launchPage {
        case 1:
            browse = BrowseHomeRoute(origin: .popular)
            selection = usesHomeBrowseContainer ? .home : .popular
        case 2:
            browse = BrowseHomeRoute(origin: .toplist)
            selection = usesHomeBrowseContainer ? .home : .toplist
        default:
            browse = BrowseHomeRoute(origin: .home)
            selection = .fromLaunchPage(launchPage)
        }
    }

    var retainedTabs: [MainTab] {
        MainTab.adaptiveContentTabs(visitedExtras: visitedExtras, selected: selection)
    }

    var sidebarSelection: MainTab? {
        guard usesHomeBrowseContainer, selection == .home else { return selection }
        // Search is its own visible Browse destination and has no sidebar shortcut.
        return MainTab.sidebarTabs.first { $0.browseSource == browse.selection }
    }

    mutating func selectFromSidebar(_ tab: MainTab) {
        if usesHomeBrowseContainer, tab == .home {
            // The sidebar row mirrors the Home source chip; the bottom control is the whole stack.
            browse.select(.home)
        }
        select(tab)
    }

    mutating func select(_ tab: MainTab) {
        if usesHomeBrowseContainer, tab != .home, let source = tab.browseSource {
            browse.select(source)
            selection = .home
            return
        }
        selection = tab
        if !MainTab.bottomTabs.contains(tab) { visitedExtras.insert(tab) }
    }

    static func clipboardGallery(from notification: Notification) -> GalleryInfo? {
        guard let gid = notification.userInfo?["gid"] as? Int64,
              let token = notification.userInfo?["token"] as? String else { return nil }
        return GalleryInfo(gid: gid, token: token)
    }
}
