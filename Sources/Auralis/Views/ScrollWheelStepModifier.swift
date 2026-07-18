import SwiftUI

/// Applies already-accumulated logical wheel steps to a unit-range value.
enum ScrollWheelStepModel {
    static func nextValue(current: Double, logicalSteps: Int, step: Double) -> Double {
        guard logicalSteps != 0, step.isFinite, step > 0 else { return current }
        return AppCustomization.clampedVolume(
            current + (Double(logicalSteps) * step),
            fallback: current
        )
    }
}

/// Converts discrete mouse-wheel events directly and accumulates the much
/// smaller deltas emitted by precision trackpads. Horizontal, zero, and
/// non-finite events never change volume.
struct ScrollWheelAccumulator: Equatable {
    var preciseThreshold: Double = 8
    private(set) var accumulatedDeltaY = 0.0

    mutating func consume(
        deltaX: Double,
        deltaY: Double,
        hasPreciseDeltas: Bool
    ) -> Int {
        guard deltaX.isFinite,
              deltaY.isFinite,
              deltaY != 0,
              abs(deltaY) > abs(deltaX) else { return 0 }

        if !hasPreciseDeltas {
            return deltaY < 0 ? 1 : -1
        }

        let threshold = preciseThreshold.isFinite && preciseThreshold > 0
            ? preciseThreshold
            : 8
        accumulatedDeltaY += deltaY
        let stepCount = Int(abs(accumulatedDeltaY) / threshold)
        guard stepCount > 0 else { return 0 }
        let rawDirection = accumulatedDeltaY < 0 ? -1.0 : 1.0
        accumulatedDeltaY -= rawDirection * Double(stepCount) * threshold
        return rawDirection < 0 ? stepCount : -stepCount
    }

    mutating func reset() {
        accumulatedDeltaY = 0
    }
}

/// Attaches a scroll-event monitor to a view so trackpad/mouse scrolls over the
/// volume slider step the value. Uses a local NSEvent monitor scoped to hover.
struct ScrollWheelStepModifier: ViewModifier {
    let onEditingChanged: (Bool) -> Void
    let onStep: (Int) -> Void

    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovering = $0 }
            .background(ScrollWheelCatcher(
                isActive: isHovering,
                onEditingChanged: onEditingChanged,
                onScroll: onStep
            ))
    }
}

private struct ScrollWheelCatcher: NSViewRepresentable {
    var isActive: Bool
    var onEditingChanged: (Bool) -> Void
    var onScroll: (Int) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = TrackingView()
        view.onEditingChanged = onEditingChanged
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? TrackingView)?.onScroll = onScroll
        (nsView as? TrackingView)?.onEditingChanged = onEditingChanged
        (nsView as? TrackingView)?.isActive = isActive
    }

    final class TrackingView: NSView {
        var onScroll: ((Int) -> Void)?
        var onEditingChanged: ((Bool) -> Void)?
        var isActive = false {
            didSet {
                if !isActive { finishEditing() }
            }
        }
        private var accumulator = ScrollWheelAccumulator()
        private var isEditing = false
        private var editingEndWorkItem: DispatchWorkItem?

        override func scrollWheel(with event: NSEvent) {
            guard isActive else {
                accumulator.reset()
                super.scrollWheel(with: event)
                return
            }

            if event.phase.contains(.began) { accumulator.reset() }
            let endsGesture = event.phase.contains(.ended) || event.phase.contains(.cancelled)
            defer {
                if endsGesture {
                    accumulator.reset()
                    finishEditing()
                }
            }

            // Momentum should not keep changing a setting after the user has
            // lifted their fingers from the trackpad.
            guard event.momentumPhase.isEmpty else { return }
            let logicalSteps = accumulator.consume(
                deltaX: event.scrollingDeltaX,
                deltaY: event.scrollingDeltaY,
                hasPreciseDeltas: event.hasPreciseScrollingDeltas
            )
            if logicalSteps != 0 {
                beginEditingIfNeeded()
                onScroll?(logicalSteps)
                scheduleEditingEnd()
            }
        }

        private func beginEditingIfNeeded() {
            guard !isEditing else { return }
            isEditing = true
            onEditingChanged?(true)
        }

        private func scheduleEditingEnd() {
            editingEndWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.finishEditing()
            }
            editingEndWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
        }

        private func finishEditing() {
            editingEndWorkItem?.cancel()
            editingEndWorkItem = nil
            guard isEditing else { return }
            isEditing = false
            onEditingChanged?(false)
        }
    }
}

extension View {
    func scrollWheelSteps(
        onEditingChanged: @escaping (Bool) -> Void = { _ in },
        onStep: @escaping (Int) -> Void
    ) -> some View {
        modifier(ScrollWheelStepModifier(
            onEditingChanged: onEditingChanged,
            onStep: onStep
        ))
    }
}
