//
//  DownloadStatusCache.swift
//  ehviewer apple
//
//  「这一本下过没有」的快查表
//
//  列表行要显示已下载标记（对齐 Android item_gallery_list.xml 的 downloaded
//  ImageView）。但行的 body 每次求值都可能问一次，而权威数据在
//  DownloadManager 这个 actor 里——在 body 里 await 是不可能的，
//  每行去查一次数据库也太贵。
//
//  这里存一份 gid 集合：启动时灌一次，之后由下载状态变化的通知增量维护。
//

import Foundation
import EhDownload
import EhModels

@Observable
@MainActor
final class DownloadStatusCache {
    static let shared = DownloadStatusCache()

    private var downloadedGids: Set<Int64> = []
    private var loaded = false

    private init() {}

    func isDownloaded(gid: Int64) -> Bool {
        downloadedGids.contains(gid)
    }

    /// 从下载队列灌一次。App 启动与下载列表刷新后调用。
    func reload() async {
        let tasks = await DownloadManager.shared.getAllTasks()
        // 只要建过任务就算「下载过」——半途暂停的也在本地留了页，
        // 列表里标出来比假装没有更有用
        downloadedGids = Set(tasks.map { $0.gallery.gid })
        loaded = true
    }

    func markDownloaded(gid: Int64) {
        downloadedGids.insert(gid)
    }

    func markRemoved(gid: Int64) {
        downloadedGids.remove(gid)
    }

    var isLoaded: Bool { loaded }
}
