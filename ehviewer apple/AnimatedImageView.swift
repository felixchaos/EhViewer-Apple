//
//  AnimatedImageView.swift
//  ehviewer apple
//
//  GIF 动画图片视图 — 使用原生 UIImageView/NSImageView 播放动画帧
//  SwiftUI 的 Image(uiImage:) 不支持 GIF 动画，需要通过 UIViewRepresentable 桥接
//

import SwiftUI

#if os(iOS)
import UIKit

/// iOS: 使用 UIImageView 播放 GIF 动画
/// UIImage(data: gifData) 会自动解析 GIF 帧 → images 数组、duration
/// UIImageView 自动循环播放
struct AnimatedImageView: UIViewRepresentable {
    let image: UIImage
    var contentMode: UIView.ContentMode = .scaleAspectFit

    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView()
        imageView.contentMode = contentMode
        imageView.clipsToBounds = true
        imageView.image = image
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        if image.images != nil {
            imageView.startAnimating()
        }
        return imageView
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        if uiView.image !== image {
            uiView.image = image
            uiView.contentMode = contentMode
            if image.images != nil {
                uiView.startAnimating()
            } else {
                uiView.stopAnimating()
            }
        }
    }
}

#elseif os(macOS)
import AppKit

/// macOS: 使用 NSImageView 播放 GIF 动画
/// NSImage(data: gifData) 载入所有帧到 NSBitmapImageRep
/// NSImageView.animates = true 自动播放
struct AnimatedImageView: NSViewRepresentable {
    let image: NSImage
    var contentMode: NSImageScaling = .scaleProportionallyUpOrDown

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = contentMode
        imageView.animates = true
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return imageView
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        if nsView.image !== image {
            nsView.image = image
            nsView.imageScaling = contentMode
            nsView.animates = true
        }
    }
}

#endif

// MARK: - PlatformImage 动画检测

extension PlatformImage {
    /// 是否为动画图片 (多帧 GIF)
    var isAnimated: Bool {
        #if os(iOS)
        return images != nil && (images?.count ?? 0) > 1
        #elseif os(macOS)
        // NSImage: 检查 NSBitmapImageRep 是否有多帧
        for rep in representations {
            if let bitmapRep = rep as? NSBitmapImageRep {
                let frameCount = bitmapRep.value(forProperty: .frameCount) as? Int ?? 1
                if frameCount > 1 { return true }
            }
        }
        return false
        #endif
    }
}
