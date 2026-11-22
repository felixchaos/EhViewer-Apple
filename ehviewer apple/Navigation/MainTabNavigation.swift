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

/// Shared navigation policy; both the sidebar and compact chrome select the same routes.
struct MainTabNavigation {
    private(set) var selection: MainTab
    let initialBrowseSource: BrowseSource
    private var visitedExtras: Set<MainTab> = []

    init(launchPage: Int, usesHomeBrowseContainer: Bool = true) {
        switch launchPage {
        case 1:
            initialBrowseSource = .popular
            selection = usesHomeBrowseContainer ? .home : .popular
        case 2:
            initialBrowseSource = .toplist
            selection = usesHomeBrowseContainer ? .home : .toplist
        default:
            initialBrowseSource = .home
            selection = .fromLaunchPage(launchPage)
        }
    }

    var retainedTabs: [MainTab] {
        MainTab.adaptiveContentTabs(visitedExtras: visitedExtras, selected: selection)
    }

    mutating func select(_ tab: MainTab) {
        selection = tab
        if !MainTab.bottomTabs.contains(tab) { visitedExtras.insert(tab) }
    }

    static func clipboardGallery(from notification: Notification) -> GalleryInfo? {
        guard let gid = notification.userInfo?["gid"] as? Int64,
              let token = notification.userInfo?["token"] as? String else { return nil }
        return GalleryInfo(gid: gid, token: token)
    }
}
