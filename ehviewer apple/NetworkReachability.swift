//
//  NetworkReachability.swift
//  ehviewer apple
//
//  判断当前是不是计费网络 — 供"移动网络下载前提醒"使用
//  (对齐 Android Settings.KEY_CELLULAR_NETWORK_WARNING)
//

import Foundation
import Network

enum NetworkReachability {

    private static let monitor: NWPathMonitor = {
        let monitor = NWPathMonitor()
        monitor.start(queue: DispatchQueue(label: "eh.reachability"))
        return monitor
    }()

    /// 蜂窝网络，或系统标记为「低数据模式 / 按流量计费」的网络
    ///
    /// 用 `isExpensive` 而不是只看接口类型：连着手机热点的 Wi-Fi 同样是花用户流量的，
    /// 只判断 `.cellular` 会漏掉这种最常见的情况。
    static var isConstrainedOrCellular: Bool {
        let path = monitor.currentPath
        guard path.status == .satisfied else { return false }
        return path.isExpensive || path.isConstrained
    }
}
