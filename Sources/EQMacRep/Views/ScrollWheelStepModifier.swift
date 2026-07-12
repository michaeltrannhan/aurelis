import SwiftUI

/// Pure scroll-wheel volume stepping. Scrolling up (deltaY < 0) raises volume,
/// down lowers it; the result is clamped to the unit range.
enum ScrollWheelStepModel {
    static func nextValue(current: Double, deltaY: Double, step: Double) -> Double {
        let direction = deltaY < 0 ? 1.0 : -1.0
        return AppCustomization.clampedVolume(current + direction * step, fallback: current)
    }
}

/// Attaches a scroll-event monitor to a view so trackpad/mouse scrolls over the
/// volume slider step the value. Uses a local NSEvent monitor scoped to hover.
struct ScrollWheelStepModifier: ViewModifier {
    let step: Double
    let onStep: (Double) -> Void

    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovering = $0 }
            .background(ScrollWheelCatcher(isActive: isHovering) { deltaY in
                onStep(deltaY)
            })
    }
}

private struct ScrollWheelCatcher: NSViewRepresentable {
    var isActive: Bool
    var onScroll: (Double) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = TrackingView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? TrackingView)?.onScroll = onScroll
        (nsView as? TrackingView)?.isActive = isActive
    }

    final class TrackingView: NSView {
        var onScroll: ((Double) -> Void)?
        var isActive = false

        override func scrollWheel(with event: NSEvent) {
            guard isActive else {
                super.scrollWheel(with: event)
                return
            }
            onScroll?(event.scrollingDeltaY)
        }
    }
}

extension View {
    func scrollWheelStep(step: Double, onStep: @escaping (Double) -> Void) -> some View {
        modifier(ScrollWheelStepModifier(step: step, onStep: onStep))
    }
}
