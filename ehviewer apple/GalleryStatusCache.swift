//
//  GalleryStatusCache.swift
//  ehviewer apple
//
//  「这一本下过没有 / 收藏没有」的快查表
//
//  列表行要显示已下载、已收藏两个标记（对齐 Android item_gallery_list.xml 的
//  downloaded / favourited 两个 ImageView）。权威数据一个在 DownloadManager
//  这个 actor 里、一个在数据库里，而行的 body 每次求值都要问一次——
//  在 body 里 await 不可能，每行查一次库也太贵。
//
//  这里存两份 gid 集合。它自己订阅收藏/下载变化的通知，所以任何页面加了收藏
//  或发起下载，所有正在显示的列表行都会跟着变——不需要各页面自己去刷新。
//

import Foundation
import EhDownload
import EhDatabase
import EhModels

@Observable
@MainActor
final class GalleryStatusCache {
    static let shared = GalleryStatusCache()

    private var downloadedGids: Set<Int64> = []
    private var favoritedGids: Set<Int64> = []
    private(set) var isLoaded = false

    private init() {
        NotificationCenter.default.addObserver(
            forName: .galleryFavoriteChanged, object: nil, queue: .main
        ) { [weak self] note in
            guard let gid = note.userInfo?["gid"] as? Int64 else { return }
            let favorited = note.userInfo?["favorited"] as? Bool ?? false
            MainActor.assumeIsolated {
                guard let self else { return }
                if favorited { self.favoritedGids.insert(gid) }
                else { self.favoritedGids.remove(gid) }
            }
        }
        NotificationCenter.default.addObserver(
            forName: .galleryDownloadChanged, object: nil, queue: .main
        ) { [weak self] note in
            guard let gid = note.userInfo?["gid"] as? Int64 else { return }
            let downloading = note.userInfo?["downloading"] as? Bool ?? true
            MainActor.assumeIsolated {
                guard let self else { return }
                if downloading { self.downloadedGids.insert(gid) }
                else { self.downloadedGids.remove(gid) }
            }
        }
    }

    func isDownloaded(gid: Int64) -> Bool { downloadedGids.contains(gid) }
    func isFavorited(gid: Int64) -> Bool { favoritedGids.contains(gid) }

    /// 已收藏 = 云端收藏夹里有，或本地收藏里有。
    /// 对齐 Android：本地收藏和云端收藏在列表上是同一个心形标记。
    func isFavorited(_ gallery: GalleryInfo) -> Bool {
        gallery.favoriteSlot >= 0 || favoritedGids.contains(gallery.gid)
    }

    /// App 启动时灌一次。
    func reload() async {
        let tasks = await DownloadManager.shared.getAllTasks()
        // 只要建过任务就算「下载过」——半途暂停的也在本地留了页，
        // 列表里标出来比假装没有更有用
        downloadedGids = Set(tasks.map { $0.gallery.gid })
        favoritedGids = Set((try? EhDatabase.shared.getAllLocalFavorites())?.map(\.gid) ?? [])
        isLoaded = true
    }
}
