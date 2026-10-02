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
