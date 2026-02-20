//
//  EhDownloadWidgetBundle.swift
//  EhDownloadWidget
//
//  Widget Extension 入口 — 注册下载进度灵动岛 Live Activity
//

import SwiftUI
import WidgetKit

@main
struct EhDownloadWidgetBundle: WidgetBundle {
    var body: some Widget {
        DownloadLiveActivityWidget()
    }
}
