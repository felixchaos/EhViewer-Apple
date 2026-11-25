import SwiftUI

#if os(iOS)
import UIKit

/// Moves only the reader presentation. Its owner stays mounted, so the
/// existing list/detail and scroll position are what the drag reveals.
struct ReaderInteractiveBack: ViewModifier {
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGFloat = 0
    @State private var finishing = false

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .allowsHitTesting(!finishing)
            .gesture(ReaderBackEdgePan(onProgress: updateOffset, onFinish: finish))
    }

    private func updateOffset(_ distance: CGFloat) {
        guard !reduceMotion, !finishing else { return }
        withoutAnimation { offset = distance }
    }

    private func finish(_ commit: Bool, width: CGFloat) {
        guard !finishing else { return }
        guard !reduceMotion, width > 0 else {
            if commit {
                finishing = true
                onDismiss()
            }
            return
        }
        guard commit else {
            withAnimation(.easeOut(duration: 0.20)) { offset = 0 }
            return
        }

        finishing = true
        let remaining = max(0, width - offset)
        let duration = min(0.27, max(0.12, remaining / 1_850))
        withAnimation(.easeOut(duration: duration), completionCriteria: .removed) {
            offset = width
        } completion: {
            // Keep the reader offscreen; the cover's default vertical
            // dismissal must not pull it back into view after the drag.
            withoutAnimation { onDismiss() }
        }
    }

    private func withoutAnimation(_ changes: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, changes)
    }
}

private struct ReaderBackEdgePan: UIGestureRecognizerRepresentable {
    let onProgress: (CGFloat) -> Void
    let onFinish: (Bool, CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        guard let view = pan.view else { return }
        let distance = max(0, pan.translation(in: view).x)
        switch pan.state {
        case .began, .changed:
            onProgress(min(distance, view.bounds.width))
        case .ended:
            let commit = distance > 80 || pan.velocity(in: view).x > 500
            onFinish(commit, view.bounds.width)
        case .cancelled, .failed:
            onFinish(false, view.bounds.width)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let view = gestureRecognizer.view else { return false }
            let point = touch.location(in: view)
            return view.bounds.contains(point) && point.x < view.bounds.minX + 24
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return velocity.x > abs(velocity.y)
        }

        // For the same touch, page scrolling must wait for the edge pan to
        // decide its direction. A recognized Back must not also turn a page.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            guard let reader = gestureRecognizer.view, let target = other.view,
                  let scroll = target as? UIScrollView, other === scroll.panGestureRecognizer else { return false }
            return target.isDescendant(of: reader)
        }
    }
}
#endif
