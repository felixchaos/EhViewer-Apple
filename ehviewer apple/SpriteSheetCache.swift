//
//  SpriteSheetCache.swift
//  ehviewer apple
//
//  精灵图预览的共享解码与裁剪缓存
//
//  E-Hentai 的普通预览是「精灵图」：一张大图里横向排着约 20 个缩略图，
//  每个预览项只取其中一块。原先的实现有三个问题，叠加起来让「查看全部预览」很卡：
//
//    1. 每个格子各自把**整张**精灵图解码一遍 —— 20 个格子 = 20 次全图解码、20 份内存
//    2. 裁剪写在 `body` 里 —— SwiftUI 每次重新求值都要重做一次 CoreGraphics 裁剪
//    3. 解码在主线程 (`onAppear` 里同步 `PlatformImage(data:)`) —— 直接掉帧
//
//  这里按 URL 只解码一次，并把裁剪结果也缓存起来，`body` 只做一次字典查找。
//

import Foundation
import CoreGraphics
import ImageIO

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

actor SpriteSheetCache {
    static let shared = SpriteSheetCache()

    /// 已解码的整张精灵图 (按 URL)
    private let sheets = NSCache<NSString, CGImageBox>()
    /// 已裁剪的单个预览 (按 URL + 裁剪区域)
    private let crops = NSCache<NSString, PlatformImageBox>()
    /// 同一张精灵图的并发请求合并成一个任务，避免重复下载与解码
    private var inFlight: [String: Task<CGImage?, Never>] = [:]

    private init() {
        // 精灵图本身不大 (通常 < 1MB)，但解码后占内存，限制张数即可
        sheets.countLimit = 12
        // 裁剪结果很小，可以多留一些，滚动回头时无需重裁
        crops.countLimit = 600
    }

    /// 取一个预览格子对应的图片
    func thumbnail(
        urlString: String,
        offsetX: Int, offsetY: Int,
        clipWidth: Int, clipHeight: Int
    ) async -> PlatformImage? {
        let cropKey = "\(urlString)|\(offsetX),\(offsetY),\(clipWidth),\(clipHeight)" as NSString
        if let cached = crops.object(forKey: cropKey) {
            return cached.image
        }

        guard let sheet = await sheet(for: urlString) else { return nil }

        let rect = CGRect(x: offsetX, y: offsetY, width: clipWidth, height: clipHeight)
        // 越界保护：解析出的坐标偶尔会超出实际图片范围
        let bounds = CGRect(x: 0, y: 0, width: sheet.width, height: sheet.height)
        guard bounds.contains(rect), let cropped = sheet.cropping(to: rect) else { return nil }

        let image = Self.makeImage(from: cropped)
        crops.setObject(PlatformImageBox(image), forKey: cropKey)
        return image
    }

    // MARK: - 精灵图解码

    private func sheet(for urlString: String) async -> CGImage? {
        let key = urlString as NSString
        if let boxed = sheets.object(forKey: key) { return boxed.image }

        // 已有同 URL 的任务在跑就等它，不要重复发起
        if let running = inFlight[urlString] {
            return await running.value
        }

        let task = Task<CGImage?, Never> {
            guard let url = URL(string: urlString) else { return nil }
            var request = URLRequest(url: url)
            request.timeoutInterval = 30

            let data: Data
            if let cached = URLCache.shared.cachedResponse(for: request) {
                data = cached.data
            } else if let (fetched, response) = try? await URLSession.shared.data(for: request) {
                URLCache.shared.storeCachedResponse(
                    CachedURLResponse(response: response, data: fetched), for: request
                )
                data = fetched
            } else {
                return nil
            }

            // 解码放在 detached 任务里，绝不占用主线程
            return await Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
                return CGImageSourceCreateImageAtIndex(source, 0, [
                    kCGImageSourceShouldCache: true
                ] as CFDictionary)
            }.value
        }

        inFlight[urlString] = task
        let result = await task.value
        inFlight[urlString] = nil

        if let result {
            sheets.setObject(CGImageBox(result), forKey: key)
        }
        return result
    }

    private nonisolated static func makeImage(from cgImage: CGImage) -> PlatformImage {
        #if canImport(UIKit)
        return UIImage(cgImage: cgImage)
        #else
        return NSImage(cgImage: cgImage,
                       size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif
    }
}

// NSCache 只接受 class，这里给 CGImage / PlatformImage 套个盒子
private final class CGImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

private final class PlatformImageBox {
    let image: PlatformImage
    init(_ image: PlatformImage) { self.image = image }
}
