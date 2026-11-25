#if os(iOS)
import SwiftUI
import UIKit

/// Identifies this reader's vertical UIScrollView without changing its delegate,
/// page-ID binding or programmatic jumps by page number.
@MainActor
final class ReaderVerticalMediaScroll {
    weak var anchor: UIView?
    private var pendingZoom: (width: CGFloat, point: CGPoint)?

    /// The image position under a viewport point, expressed at fit width.
    struct ZoomAnchor {
        let viewport: CGPoint
        let fitPoint: CGPoint

        func offset(at scale: CGFloat) -> CGPoint {
            CGPoint(x: fitPoint.x * scale - viewport.x, y: fitPoint.y * scale - viewport.y)
        }
    }

    func zoomAnchor(at point: UnitPoint, scale: CGFloat) -> ZoomAnchor? {
        guard let scroll = containingScrollView() else { return nil }
        let viewport = CGPoint(x: scroll.bounds.width * point.x, y: scroll.bounds.height * point.y)
        let offset = scroll.contentOffset
        return ZoomAnchor(viewport: viewport,
                          fitPoint: CGPoint(x: (offset.x + viewport.x) / scale,
                                            y: (offset.y + viewport.y) / scale))
    }

    func prepareZoom(width: CGFloat, offset: CGPoint) {
        pendingZoom = (width, offset)
    }

    func applyZoomAfterLayout() {
        guard let pendingZoom, let scroll = containingScrollView(),
              abs(scroll.contentSize.width - pendingZoom.width) < 1 else { return }
        self.pendingZoom = nil
        let insets = scroll.adjustedContentInset
        let left = -insets.left
        let top = -insets.top
        let right = max(left, scroll.contentSize.width - scroll.bounds.width + insets.right)
        let bottom = max(top, scroll.contentSize.height - scroll.bounds.height + insets.bottom)
        let target = CGPoint(x: min(right, max(left, pendingZoom.point.x)),
                             y: min(bottom, max(top, pendingZoom.point.y)))
        scroll.setContentOffset(target, animated: false)
    }

    /// Returns true when the vertical scroll view handled the step, including at its ends.
    func step(forward: Bool, pageSpacing: CGFloat) -> Bool {
        guard let scroll = containingScrollView(), scroll.bounds.height > 0 else { return false }
        let insets = scroll.adjustedContentInset
        let top = -insets.top
        let bottom = max(top, scroll.contentSize.height - scroll.bounds.height + insets.bottom)
        let viewport = scroll.bounds.height - insets.top - insets.bottom
        guard viewport > 0 else { return false }
        let current = min(bottom, max(top, scroll.contentOffset.y))
        let stride = max(1, viewport - pageSpacing)
        let target = min(bottom, max(top, current + (forward ? stride : -stride)))
        if abs(target - current) > 0.5 {
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: target),
                                    animated: !UIAccessibility.isReduceMotionEnabled)
        }
        return true
    }

    func containingScrollView() -> UIScrollView? {
        guard let anchor, anchor.window != nil else { return nil }
        var view = anchor.superview
        while let current = view {
            if let scroll = current as? UIScrollView { return scroll }
            view = current.superview
        }
        return nil
    }
}

struct ReaderVerticalMediaScrollAnchor: UIViewRepresentable {
    let target: ReaderVerticalMediaScroll
    let onPinch: (UIGestureRecognizer.State, CGFloat, UnitPoint) -> Void

    func makeUIView(context: Context) -> AnchorView {
        let anchor = AnchorView()
        anchor.isUserInteractionEnabled = false
        anchor.isAccessibilityElement = false
        anchor.target = target
        anchor.onPinch = onPinch
        target.anchor = anchor
        return anchor
    }

    func updateUIView(_ anchor: AnchorView, context: Context) {
        anchor.onPinch = onPinch
        anchor.attachToCurrentScrollView()
    }

    static func dismantleUIView(_ anchor: AnchorView, coordinator: ()) {
        anchor.detach()
    }

    @MainActor
    final class AnchorView: UIView, UIGestureRecognizerDelegate {
        weak var target: ReaderVerticalMediaScroll?
        var onPinch: ((UIGestureRecognizer.State, CGFloat, UnitPoint) -> Void)?
        private weak var scroll: UIScrollView?
        private weak var pinch: UIPinchGestureRecognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attachToCurrentScrollView()
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            attachToCurrentScrollView()
        }

        func attachToCurrentScrollView() {
            guard let next = target?.containingScrollView() else {
                detach()
                return
            }
            guard scroll !== next else { return }
            detach()
            let recognizer = UIPinchGestureRecognizer(target: self, action: #selector(didPinch(_:)))
            recognizer.delegate = self
            next.addGestureRecognizer(recognizer)
            scroll = next
            pinch = recognizer
        }

        func detach() {
            if let pinch { scroll?.removeGestureRecognizer(pinch) }
            scroll = nil
            pinch = nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // Existing UIKit scrolling retains inertia. A two-finger gesture
            // must still be recognized when its translation starts as a pan.
            other === scroll?.panGestureRecognizer
        }

        @objc private func didPinch(_ gesture: UIPinchGestureRecognizer) {
            guard let scroll, scroll.bounds.width > 0, scroll.bounds.height > 0 else { return }
            let point = gesture.location(in: scroll)
            let anchor = UnitPoint(x: (point.x - scroll.bounds.minX) / scroll.bounds.width,
                                   y: (point.y - scroll.bounds.minY) / scroll.bounds.height)
            onPinch?(gesture.state, gesture.scale, anchor)
        }
    }
}
#endif
