import AppKit
import SwiftUI

/// Native slider tracking, keyboard input and accessibility, with an opaque
/// track. macOS's standard SwiftUI slider does not apply tint to its track.
struct VolumeSlider: NSViewRepresentable {
    @Binding var value: Double
    var isMuted = false
    var volumeStep: Double? = nil
    var onEditingChanged: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NativeVolumeSlider {
        let slider = NativeVolumeSlider()
        slider.cell = VolumeSliderCell()
        slider.minValue = 0
        slider.maxValue = 1
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        slider.onEditingChanged = { [weak coordinator = context.coordinator] editing in
            coordinator?.parent.onEditingChanged(editing)
        }
        return slider
    }

    func updateNSView(_ slider: NativeVolumeSlider, context: Context) {
        context.coordinator.parent = self
        slider.doubleValue = value
        slider.isEnabled = context.environment.isEnabled
        if !slider.isEnabled { slider.finishWheelEditing() }
        slider.volumeStep = volumeStep
        (slider.cell as? VolumeSliderCell)?.isMuted = isMuted
        slider.needsDisplay = true
    }

    static func dismantleNSView(_ slider: NativeVolumeSlider, coordinator: Coordinator) {
        slider.finishWheelEditing()
        slider.onEditingChanged = nil
        slider.target = nil
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: VolumeSlider
        init(_ parent: VolumeSlider) { self.parent = parent }

        @objc func changed(_ slider: NSSlider) {
            parent.value = slider.doubleValue
        }
    }
}

final class NativeVolumeSlider: NSSlider {
    var onEditingChanged: ((Bool) -> Void)?
    var volumeStep: Double?
    private var wheelAccumulator = ScrollWheelAccumulator()
    private var isWheelEditing = false
    private var wheelEndTask: Task<Void, Never>?

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        finishWheelEditing()
        onEditingChanged?(true)
        defer { onEditingChanged?(false) }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return }
        finishWheelEditing()
        onEditingChanged?(true)
        defer { onEditingChanged?(false) }
        super.keyDown(with: event)
    }

    override func accessibilityPerformIncrement() -> Bool {
        guard isEnabled else { return false }
        finishWheelEditing()
        onEditingChanged?(true)
        defer { onEditingChanged?(false) }
        let previous = doubleValue
        _ = super.accessibilityPerformIncrement()
        return doubleValue != previous
    }

    override func accessibilityPerformDecrement() -> Bool {
        guard isEnabled else { return false }
        finishWheelEditing()
        onEditingChanged?(true)
        defer { onEditingChanged?(false) }
        let previous = doubleValue
        _ = super.accessibilityPerformDecrement()
        return doubleValue != previous
    }

    override func scrollWheel(with event: NSEvent) {
        guard isEnabled, let volumeStep else {
            nextResponder?.scrollWheel(with: event)
            return
        }
        if event.phase.contains(.began) { wheelAccumulator.reset() }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            finishWheelEditing()
            return
        }
        guard event.momentumPhase.isEmpty else { return }
        let steps = wheelAccumulator.consume(
            deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas
        )
        guard steps != 0 else { return }
        if !isWheelEditing {
            isWheelEditing = true
            onEditingChanged?(true)
        }
        doubleValue = ScrollWheelStepModel.nextValue(current: doubleValue, logicalSteps: steps, step: volumeStep)
        sendAction(action, to: target)
        wheelEndTask?.cancel()
        wheelEndTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) }
            catch { return }
            self?.finishWheelEditing()
        }
    }

    func finishWheelEditing() {
        wheelEndTask?.cancel()
        wheelEndTask = nil
        wheelAccumulator.reset()
        guard isWheelEditing else { return }
        isWheelEditing = false
        onEditingChanged?(false)
    }
}

final class VolumeSliderCell: NSSliderCell {
    var isMuted = false

    override func drawKnob(_ knobRect: NSRect) {
        let size = min(14, knobRect.height)
        let thumb = NSRect(x: knobRect.midX - size / 2, y: knobRect.midY - size / 2, width: size, height: size)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: thumb).fill()
        NSColor(calibratedWhite: 0.2, alpha: 0.3).setStroke()
        let outline = NSBezierPath(ovalIn: thumb)
        outline.lineWidth = 0.5
        outline.stroke()
    }

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let knob = knobRect(flipped: flipped)
        let inset = knob.width / 2
        let rail = NSRect(
            x: rect.minX + inset,
            y: rect.midY - 3,
            width: max(0, rect.width - inset * 2),
            height: 6
        )
        let dark = controlView?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let railColor = dark
            ? NSColor(calibratedRed: 0x64 / 255, green: 0x74 / 255, blue: 0x8B / 255, alpha: 1)
            : NSColor(calibratedRed: 0x94 / 255, green: 0xA3 / 255, blue: 0xB8 / 255, alpha: 1)
        railColor.setFill()
        NSBezierPath(roundedRect: rail, xRadius: 3, yRadius: 3).fill()

        let fraction = CGFloat(min(max(doubleValue, minValue), maxValue) - minValue) / CGFloat(maxValue - minValue)
        var filled = rail
        filled.size.width *= fraction
        let accent: NSColor
        if !isEnabled || isMuted {
            accent = dark ? .init(calibratedWhite: 0.8, alpha: 1) : .darkGray
        } else {
            accent = dark
                ? NSColor(calibratedRed: 0x22 / 255, green: 0xD3 / 255, blue: 0xEE / 255, alpha: 1)
                : NSColor(calibratedRed: 0x08 / 255, green: 0x78 / 255, blue: 0x86 / 255, alpha: 1)
        }
        accent.setFill()
        NSBezierPath(roundedRect: filled, xRadius: 3, yRadius: 3).fill()
    }
}
