//
//  ZoomableImageView.swift
//  ehviewer apple
//
//  可缩放图片视图 — 对齐 Android GalleryView 的缩放/平移逻辑
//  使用 UIScrollView (iOS) / NSScrollView (macOS) 实现原生级缩放体验
//

import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// MARK: - iOS 实现

#if os(iOS)
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    let scaleMode: ScaleMode
    let startPosition: StartPosition
    /// 是否允许在 1x 缩放时拦截水平滑动 (翻页模式需要 false 以允许 TabView 翻页)
    var allowsHorizontalScrollAtMinZoom: Bool = false
    /// 单击回调 — 传入点击位置(相对于视口)和视口尺寸，由调用方判断触发区域
    /// 对齐 Android GalleryView: 单击和双击互斥，双击优先 (require(toFail:))
    var onSingleTap: ((CGPoint, CGSize) -> Void)?
    /// 缩放状态变化回调 — 通知外层当前是否处于放大状态
    var onZoomChanged: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onSingleTap: onSingleTap, onZoomChanged: onZoomChanged)
    }

    func makeUIView(context: Context) -> ZoomableScrollView {
        let scrollView = ZoomableScrollView(frame: .zero)
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 5.0
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.bounces = true
        scrollView.alwaysBounceHorizontal = false
        scrollView.isDirectionalLockEnabled = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.scaleMode = scaleMode
        scrollView.startPosition = startPosition
        scrollView.allowsHorizontalScrollAtMinZoom = allowsHorizontalScrollAtMinZoom
        // 初始禁用滚动，防止内层 panGesture 拦截父级 ScrollView 的翻页手势
        // layoutSubviews 完成后会根据内容溢出情况正确设置
        scrollView.isScrollEnabled = false

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleToFill  // 手动设置 frame，不依赖 contentMode
        imageView.clipsToBounds = false
        imageView.tag = 1001
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView
        context.coordinator.scrollView = scrollView
        context.coordinator.allowsHorizontalScrollAtMinZoom = allowsHorizontalScrollAtMinZoom

        // 双击缩放手势 (对齐 Android GalleryView 双击缩放)
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        // 单击手势 — 始终添加 (对齐 Android: 单击/双击互斥，由调用方根据位置判断区域动作)
        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)  // 双击优先: 必须等双击失败后才触发单击
        scrollView.addGestureRecognizer(singleTap)

        return scrollView
    }

    func updateUIView(_ scrollView: ZoomableScrollView, context: Context) {
        guard let imageView = scrollView.viewWithTag(1001) as? UIImageView else { return }

        let imageChanged = imageView.image !== image
        let scaleModeChanged = scrollView.scaleMode != scaleMode
        let startPositionChanged = scrollView.startPosition != startPosition

        if imageChanged {
            imageView.image = image
            scrollView.zoomScale = scrollView.minimumZoomScale
            scrollView.needsStartPositionApply = true
        }

        if scaleModeChanged {
            scrollView.scaleMode = scaleMode
            scrollView.needsStartPositionApply = true
        }

        if startPositionChanged {
            scrollView.startPosition = startPosition
            scrollView.needsStartPositionApply = true
        }

        if imageChanged || scaleModeChanged || startPositionChanged {
            scrollView.lastLayoutBoundsSize = .zero
        }

        context.coordinator.allowsHorizontalScrollAtMinZoom = allowsHorizontalScrollAtMinZoom
        context.coordinator.onSingleTap = onSingleTap
        context.coordinator.onZoomChanged = onZoomChanged

        // 同步 allowsHorizontalScrollAtMinZoom 到 ZoomableScrollView
        scrollView.allowsHorizontalScrollAtMinZoom = allowsHorizontalScrollAtMinZoom

        // 仅在需要重新布局时才调用 setNeedsLayout，避免不必要的重绘
        if imageChanged || scaleModeChanged || startPositionChanged {
            scrollView.setNeedsLayout()
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        weak var scrollView: ZoomableScrollView?
        var onSingleTap: ((CGPoint, CGSize) -> Void)?
        var onZoomChanged: ((Bool) -> Void)?
        var allowsHorizontalScrollAtMinZoom: Bool = false
        private var lastIsZoomed: Bool = false

        init(onSingleTap: ((CGPoint, CGSize) -> Void)?, onZoomChanged: ((Bool) -> Void)?) {
            self.onSingleTap = onSingleTap
            self.onZoomChanged = onZoomChanged
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            // 始终钳制水平偏移，防止任何横向漂移/黑边 (对齐 Android GalleryView: 不允许水平越界)
            let contentW = scrollView.contentSize.width
            let boundsW = scrollView.bounds.width
            guard contentW > 0 && boundsW > 0 else { return }

            var targetX = scrollView.contentOffset.x
            if contentW <= boundsW + 1 {
                // 内容宽度 ≤ 视口: 锁定到居中位置，完全禁止水平移动
                targetX = max(0, (contentW - boundsW) / 2)
            } else {
                // 内容宽度 > 视口 (放大时): 钳制到有效范围 [0, maxOffset]，防止过度滚动
                let maxX = contentW - boundsW
                targetX = min(max(0, targetX), maxX)
            }
            if abs(scrollView.contentOffset.x - targetX) > 0.1 {
                scrollView.contentOffset.x = targetX
            }
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard let imageView else { return }
            // 居中图片 (对齐 Android GalleryView.layout)
            let boundsSize = scrollView.bounds.size
            var frameToCenter = imageView.frame

            if frameToCenter.size.width < boundsSize.width {
                frameToCenter.origin.x = (boundsSize.width - frameToCenter.size.width) / 2
            } else {
                frameToCenter.origin.x = 0
            }

            if frameToCenter.size.height < boundsSize.height {
                frameToCenter.origin.y = (boundsSize.height - frameToCenter.size.height) / 2
            } else {
                frameToCenter.origin.y = 0
            }

            imageView.frame = frameToCenter

            if let zoomScrollView = scrollView as? ZoomableScrollView {
                zoomScrollView.clampHorizontalOffset()
                zoomScrollView.updateScrollEnabled()

                let isZoomed = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
                // 通知外层缩放状态变化
                if isZoomed != lastIsZoomed {
                    lastIsZoomed = isZoomed
                    onZoomChanged?(isZoomed)
                }
            }
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            if let zoomScrollView = scrollView as? ZoomableScrollView {
                zoomScrollView.updateScrollEnabled()

                let isZoomed = scale > scrollView.minimumZoomScale + 0.01
                if isZoomed != lastIsZoomed {
                    lastIsZoomed = isZoomed
                    onZoomChanged?(isZoomed)
                }
            }
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }

            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
                // 已放大 → 缩小回 1x (对齐 Android GalleryView: 双击回 fitScale)
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                // 在点击位置放大到 2.5x (对齐 Android GalleryView 双击缩放目标)
                let pointInView = gesture.location(in: imageView)
                let targetScale: CGFloat = 2.5
                let zoomWidth = scrollView.bounds.width / targetScale
                let zoomHeight = scrollView.bounds.height / targetScale
                let zoomRect = CGRect(
                    x: pointInView.x - zoomWidth / 2,
                    y: pointInView.y - zoomHeight / 2,
                    width: zoomWidth,
                    height: zoomHeight
                )
                scrollView.zoom(to: zoomRect, animated: true)
            }
        }

        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }
            // 传入点击位置(相对于 scrollView 视口)和视口尺寸
            // 对齐 Android GalleryView.onSingleTapConfirmed: 由外层根据坐标判断区域
            let location = gesture.location(in: scrollView)
            let size = scrollView.bounds.size
            onSingleTap?(location, size)
        }

    }
}

/// 自定义 UIScrollView — 实现完整的 ScaleMode 布局逻辑 (对齐 Android ImageView.setScaleOffset)
/// 在 fit/fitWidth 模式的 1x 缩放时不拦截水平手势，让父 ScrollView 正常翻页
class ZoomableScrollView: UIScrollView {
    /// 用于检测 bounds 是否变化，避免冗余布局
    var lastLayoutBoundsSize: CGSize = .zero
    /// 缩放模式 (对齐 Android ImageView.SCALE_*)
    var scaleMode: ScaleMode = .fit
    /// 起始位置 (对齐 Android ImageView.START_POSITION_*)
    var startPosition: StartPosition = .center
    /// 是否需要在下次布局时应用起始位置
    var needsStartPositionApply = true
    /// 是否允许 1x 缩放时水平滚动 (垂直滚动模式需要)
    var allowsHorizontalScrollAtMinZoom: Bool = false

    /// 根据当前缩放、内容溢出状态更新 isScrollEnabled / bounces
    /// — 1x + 无溢出: 禁用滚动，让父 ScrollView 处理翻页手势
    /// — 放大 / 内容溢出: 启用滚动，允许用户平移查看
    func updateScrollEnabled() {
        let isZoomed = zoomScale > minimumZoomScale + 0.01
        let contentOverflows = contentSize.width > bounds.width + 1 ||
                               contentSize.height > bounds.height + 1
        let shouldScroll = isZoomed || contentOverflows || allowsHorizontalScrollAtMinZoom
        isScrollEnabled = shouldScroll
        // Fix: 显式禁用 panGestureRecognizer — isScrollEnabled = false 并不一定禁用它
        // 活跃的 panGesture 会吞掉手势，阻止外层 SwiftUI ScrollView 识别翻页滑动
        panGestureRecognizer.isEnabled = shouldScroll
        bounces = !isZoomed
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }

        // 每次布局都钳制水平偏移，阻止 UIScrollView bounce 导致的横向黑边
        clampHorizontalOffset()

        // 仅在 1x (未缩放) 且 bounds 发生变化时重新计算
        guard zoomScale <= minimumZoomScale + 0.01 else {
            centerImageView()
            return
        }
        guard bounds.size != lastLayoutBoundsSize else { return }
        lastLayoutBoundsSize = bounds.size

        guard let imageView = viewWithTag(1001) as? UIImageView,
              let image = imageView.image else { return }
        let imgSize = image.size
        guard imgSize.width > 0, imgSize.height > 0 else { return }

        let wScale = bounds.width / imgSize.width
        let hScale = bounds.height / imgSize.height

        // 对齐 Android ImageView.setScaleOffset: 根据 scaleMode 计算缩放比例
        var fitScale: CGFloat
        switch scaleMode {
        case .origin:
            fitScale = 1.0
        case .fitWidth:
            fitScale = wScale
        case .fitHeight:
            fitScale = hScale
        case .fit:
            fitScale = min(wScale, hScale)
        case .fixed:
            fitScale = 1.0
        }

        let scaledW = imgSize.width * fitScale
        let scaledH = imgSize.height * fitScale

        // 设置 imageView 尺寸
        imageView.frame = CGRect(x: 0, y: 0, width: scaledW, height: scaledH)
        contentSize = CGSize(width: scaledW, height: scaledH)

        // 居中或边缘对齐 (对齐 Android ImageView.adjustPosition)
        centerImageView()

        // 应用起始位置 (对齐 Android ImageView startPosition)
        if needsStartPositionApply {
            applyStartPosition(scaledW: scaledW, scaledH: scaledH)
            needsStartPositionApply = false
        }

        // 布局完成后更新滚动状态 — 确保 1x 缩放时不拦截父 ScrollView 的翻页手势
        updateScrollEnabled()
    }

    /// 居中图片: 小于屏幕时居中，大于屏幕时对齐边缘 (对齐 Android ImageView.adjustPosition)
    private func centerImageView() {
        guard let imageView = viewWithTag(1001) as? UIImageView else { return }
        var f = imageView.frame
        f.origin.x = f.width < bounds.width ? (bounds.width - f.width) / 2 : 0
        f.origin.y = f.height < bounds.height ? (bounds.height - f.height) / 2 : 0
        imageView.frame = f
    }

    /// 钳制水平偏移到有效范围，防止横向漂移/黑边 (对齐 Android: 图片不允许水平越界)
    func clampHorizontalOffset() {
        let contentW = contentSize.width
        let boundsW = bounds.width
        guard contentW > 0 && boundsW > 0 else { return }

        var targetX = contentOffset.x
        if contentW <= boundsW + 1 {
            // 内容宽度 ≤ 视口: 锁定居中
            targetX = max(0, (contentW - boundsW) / 2)
        } else {
            // 放大时: 钳制到 [0, maxOffset]
            let maxX = contentW - boundsW
            targetX = min(max(0, targetX), maxX)
        }
        if abs(contentOffset.x - targetX) > 0.1 {
            contentOffset.x = targetX
        }
    }

    /// 设置初始滚动偏移 (对齐 Android ImageView startPosition 逻辑)
    private func applyStartPosition(scaledW: CGFloat, scaledH: CGFloat) {
        let maxOffsetX = max(0, scaledW - bounds.width)
        let maxOffsetY = max(0, scaledH - bounds.height)

        var offset: CGPoint
        switch startPosition {
        case .topLeft:
            offset = CGPoint(x: 0, y: 0)
        case .topRight:
            offset = CGPoint(x: maxOffsetX, y: 0)
        case .bottomLeft:
            offset = CGPoint(x: 0, y: maxOffsetY)
        case .bottomRight:
            offset = CGPoint(x: maxOffsetX, y: maxOffsetY)
        case .center:
            offset = CGPoint(x: maxOffsetX / 2, y: maxOffsetY / 2)
        }
        contentOffset = offset
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if let panGesture = gestureRecognizer as? UIPanGestureRecognizer {
            let velocity = panGesture.velocity(in: self)

            if zoomScale <= minimumZoomScale + 0.01 {
                // 1x 缩放时:
                // 允许从屏幕左边缘开始的右滑手势 (返回导航)
                if let window = self.window {
                    let locationInWindow = panGesture.location(in: window)
                    if locationInWindow.x < 30 && velocity.x > 0 && abs(velocity.x) > abs(velocity.y) {
                        return false
                    }
                }

                // 只在 fit/fitWidth 模式下拦截水平手势 (这些模式下图片宽度 ≤ 屏幕宽度，无需水平滚动)
                // 拦截后 → 手势传给父 ScrollView → 实现翻页
                if abs(velocity.x) > abs(velocity.y) && (scaleMode == .fit || scaleMode == .fitWidth) {
                    return false
                }
            } else {
                // 放大时: 图片已到达边缘且继续向外拖动 → 不拦截，让父 ScrollView 翻页
                // 对齐 Android GalleryView: 放大时到达边缘可以翻页
                let isHorizontalPan = abs(velocity.x) > abs(velocity.y)
                if isHorizontalPan {
                    let atLeftEdge = contentOffset.x <= 0
                    let atRightEdge = contentOffset.x >= contentSize.width - bounds.width - 1
                    let panningLeft = velocity.x > 0   // 手指向右划 = 内容向左
                    let panningRight = velocity.x < 0  // 手指向左划 = 内容向右

                    // 在左边缘且向右划 → 上一页；在右边缘且向左划 → 下一页
                    if (atLeftEdge && panningLeft) || (atRightEdge && panningRight) {
                        return false
                    }
                }
            }
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

#else

// MARK: - macOS 实现

struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage
    let scaleMode: ScaleMode
    let startPosition: StartPosition
    var allowsHorizontalScrollAtMinZoom: Bool = false
    var onSingleTap: ((CGPoint, CGSize) -> Void)?
    var onZoomChanged: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onSingleTap: onSingleTap, onZoomChanged: onZoomChanged)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 1.0
        scrollView.maxMagnification = 5.0
        scrollView.backgroundColor = .black

        let imageView = NSImageView(image: image)
        imageView.imageScaling = .scaleNone  // 手动控制尺寸，不依赖 AppKit 自动缩放
        scrollView.documentView = imageView
        context.coordinator.imageView = imageView
        context.coordinator.scrollView = scrollView
        context.coordinator.scaleMode = scaleMode

        // 单击手势
        let singleTap = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap(_:)))
        singleTap.numberOfClicksRequired = 1
        scrollView.addGestureRecognizer(singleTap)

        // 双击手势
        let doubleTap = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfClicksRequired = 2
        singleTap.delaysPrimaryMouseButtonEvents = true
        scrollView.addGestureRecognizer(doubleTap)

        // 监听窗口 resize → 重新布局图片
        scrollView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.frameDidChange(_:)),
            name: NSView.frameDidChangeNotification,
            object: scrollView
        )

        // 监听缩放变化 → 同步 isZoomed 状态
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.magnificationDidChange(_:)),
            name: NSScrollView.didEndLiveMagnifyNotification,
            object: scrollView
        )

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let imageView = scrollView.documentView as? NSImageView else { return }
        let needsLayout = imageView.image !== image || context.coordinator.scaleMode != scaleMode
        if imageView.image !== image {
            imageView.image = image
            scrollView.magnification = 1.0
        }
        context.coordinator.scaleMode = scaleMode
        context.coordinator.onSingleTap = onSingleTap
        context.coordinator.onZoomChanged = onZoomChanged
        if needsLayout {
            Self.layoutImageStatic(in: scrollView, imageView: imageView, scaleMode: scaleMode)
            context.coordinator.lastViewSize = scrollView.bounds.size
        }
    }

    /// 对齐 Android ImageView.setScaleOffset 的缩放布局
    static func layoutImageStatic(in scrollView: NSScrollView, imageView: NSImageView, scaleMode: ScaleMode) {
        guard let image = imageView.image else { return }
        let imgSize = image.size
        let viewSize = scrollView.bounds.size
        guard imgSize.width > 0, imgSize.height > 0, viewSize.width > 0, viewSize.height > 0 else { return }

        let wScale = viewSize.width / imgSize.width
        let hScale = viewSize.height / imgSize.height

        var fitScale: CGFloat
        switch scaleMode {
        case .origin:    fitScale = 1.0
        case .fitWidth:  fitScale = wScale
        case .fitHeight: fitScale = hScale
        case .fit:       fitScale = min(wScale, hScale)
        case .fixed:     fitScale = 1.0
        }

        let scaledW = imgSize.width * fitScale
        let scaledH = imgSize.height * fitScale

        // 居中 (对齐 Android adjustPosition: 小于视口时居中)
        let x = max(0, (viewSize.width - scaledW) / 2)
        let y = max(0, (viewSize.height - scaledH) / 2)
        imageView.frame = CGRect(x: x, y: y, width: scaledW, height: scaledH)
    }

    class Coordinator: NSObject {
        weak var imageView: NSImageView?
        weak var scrollView: NSScrollView?
        var onSingleTap: ((CGPoint, CGSize) -> Void)?
        var onZoomChanged: ((Bool) -> Void)?
        var scaleMode: ScaleMode = .fit
        var lastViewSize: CGSize = .zero

        init(onSingleTap: ((CGPoint, CGSize) -> Void)?, onZoomChanged: ((Bool) -> Void)?) {
            self.onSingleTap = onSingleTap
            self.onZoomChanged = onZoomChanged
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        /// 窗口尺寸变化时重新布局图片
        @objc func frameDidChange(_ notification: Notification) {
            guard let scrollView, let imageView else { return }
            let newSize = scrollView.bounds.size
            guard newSize != lastViewSize, newSize.width > 0, newSize.height > 0 else { return }
            lastViewSize = newSize
            // 重新布局 (reset magnification 以适应新窗口尺寸)
            scrollView.magnification = 1.0
            ZoomableImageView.layoutImageStatic(in: scrollView, imageView: imageView, scaleMode: scaleMode)
            onZoomChanged?(false)
        }

        /// 缩放结束时同步 isZoomed 状态
        @objc func magnificationDidChange(_ notification: Notification) {
            guard let scrollView else { return }
            onZoomChanged?(scrollView.magnification > 1.1)
        }

        @objc func handleDoubleTap(_ gesture: NSClickGestureRecognizer) {
            guard let scrollView else { return }
            if scrollView.magnification > 1.1 {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.3
                    scrollView.animator().magnification = 1.0
                }
                onZoomChanged?(false)
            } else {
                let point = gesture.location(in: scrollView.documentView)
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.3
                    scrollView.animator().setMagnification(2.5, centeredAt: point)
                }
                onZoomChanged?(true)
            }
        }

        @objc func handleSingleTap(_ gesture: NSClickGestureRecognizer) {
            guard let scrollView else { return }
            let location = gesture.location(in: scrollView)
            let size = scrollView.bounds.size
            // macOS 坐标原点在左下角，翻转 Y 轴以匹配 iOS (左上角原点)
            let flippedLocation = CGPoint(x: location.x, y: size.height - location.y)
            onSingleTap?(flippedLocation, size)
        }
    }
}

#endif
