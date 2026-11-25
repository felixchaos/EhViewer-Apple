#if os(iOS)
import SwiftUI
import UIKit

/// Identifies this reader's vertical UIScrollView without changing its delegate,
/// page-ID binding, gesture recognizers, or programmatic jumps by page number.
@MainActor
final class ReaderVerticalMediaScroll {
    weak var anchor: UIView?

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

    private func containingScrollView() -> UIScrollView? {
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

    func makeUIView(context: Context) -> UIView {
        let anchor = UIView()
        anchor.isUserInteractionEnabled = false
        anchor.isAccessibilityElement = false
        target.anchor = anchor
        return anchor
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
