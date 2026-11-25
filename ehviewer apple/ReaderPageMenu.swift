//
//  ReaderPageMenu.swift
//  ehviewer apple
//
//  阅读器的单页操作 — 对齐 Android GalleryActivity.showPageDialog
//
//  Android 长按页面会弹一个四项菜单：刷新本页 / 分享 / 保存 / 保存到…
//  iOS 端此前一项都没有：一张图加载坏了只能退出重进，想留一张也没有出口。
//

import SwiftUI

#if os(iOS)
import UIKit
#endif

/// 应用屏幕方向锁定。对齐 Android setRequestedOrientation：
/// 0=跟随系统 / 1=竖屏 / 2=横屏。
///
/// 权威值是 AppSettings.screenRotation，AppDelegate 的
/// supportedInterfaceOrientationsFor 已经在读它。这里只负责让系统**立刻**
/// 重新问一次并转过去——不然设置改了要等下一次转屏才生效。
@MainActor
func applyScreenRotation(_ mode: Int) {
    #if os(iOS)
    let mask: UIInterfaceOrientationMask
    switch mode {
    case 1:  mask = .portrait
    case 2:  mask = .landscape
    default: mask = .allButUpsideDown
    }
    guard let scene = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .first(where: { $0.activationState == .foregroundActive })
    else { return }
    scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    #endif
}
