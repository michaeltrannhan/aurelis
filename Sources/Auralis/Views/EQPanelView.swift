import SwiftUI

/// Shared Process/Output equalizer. The response graph preserves the familiar
/// spectrum shape while giving every band a 28-point drag target and a precise
/// keyboard/step control in compact surfaces.
struct EQBandEditor: View {
    enum Style {
        case desktop
        case compact

        var graphHeight: CGFloat {
            switch self {
            case .desktop: 224
            case .compact: 172
            }
        }

        var padding: CGFloat {
            switch self {
            case .desktop: 16
            case .compact: 12
            }
        }
    }

    let stage: EQStage
    let targetName: String
    let curve: EQCurve
    var style: Style = .desktop
    let onClose: () -> Void
    let onGain: (Int, Double) -> Void
    var onGainEditingChanged: (Int, Bool) -> Void = { _, _ in }
    var onReset: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var selectedBand = 4
    @FocusState private var graphFocused: Bool

    private var accent: Color { AuralisColor.stageAccent(stage) }
    private var range: Double { curve.range.rawValue }
    private var activeBandCount: Int {
        curve.gains.filter { abs($0) >= 0.05 }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: style == .compact ? 10 : 14) {
            header
            responseGraph
            selectedBandControls
            footer
        }
        .padding(style.padding)
        .background(
            RoundedRectangle(cornerRadius: AuralisSpacing.panelRadius)
                .fill(AuralisColor.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AuralisSpacing.panelRadius)
                .stroke(
                    colorSchemeContrast == .increased
                        ? Color.primary.opacity(0.72)
                        : AuralisColor.hairline,
                    lineWidth: colorSchemeContrast == .increased ? 2 : 1
                )
        )
        .focusable()
        .focused($graphFocused)
        .onKeyPress(.leftArrow) {
            selectedBand = max(selectedBand - 1, 0)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            selectedBand = min(selectedBand + 1, EQCurve.bandCount - 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            adjustSelectedBand(by: 0.5)
            return .handled
        }
        .onKeyPress(.downArrow) {
            adjustSelectedBand(by: -0.5)
            return .handled
        }
        .onChange(of: targetName) { _, _ in selectedBand = 4 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(stage.title) for \(targetName)")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(accent)
                .frame(width: 4, height: style == .compact ? 30 : 36)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(stage.title) · \(targetName)")
                    .font(AuralisTypography.workspaceTitle(style == .compact ? 16 : 19))
                    .lineLimit(1)
                Text(stageExplanation)
                    .font(AuralisTypography.content(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(style == .compact ? 2 : 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("±\(Int(range)) dB")
                .font(AuralisTypography.metric(style == .compact ? 10 : 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .frame(minHeight: AuralisSpacing.controlMinHit)
                .background(AuralisColor.mutedPanel, in: Capsule())
                .accessibilityLabel("Gain range plus or minus \(Int(range)) decibels")

            Button("Done", action: onClose)
                .controlSize(.small)
                .frame(minHeight: AuralisSpacing.controlMinHit)
        }
    }

    private var stageExplanation: String {
        switch stage {
        case .process:
            "Shapes only this app before volume and routing."
        case .output:
            "Shapes this physical output for every routed app."
        }
    }

    private var responseGraph: some View {
        GeometryReader { proxy in
            let plot = plotRect(in: proxy.size)
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(AuralisColor.mutedPanel)

                graphGrid(in: plot)
                responsePath(in: plot)

                ForEach(0..<EQCurve.bandCount, id: \.self) { index in
                    bandNode(index, in: plot)
                }

                ForEach(visibleFrequencyIndices, id: \.self) { index in
                    Text(EQCurve.frequencies[index])
                        .font(AuralisTypography.metric(style == .compact ? 8 : 9))
                        .foregroundStyle(.secondary)
                        .position(
                            x: xPosition(for: index, in: plot),
                            y: plot.maxY + 14
                        )
                        .accessibilityHidden(true)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .coordinateSpace(name: "eq-response")
            .onTapGesture { graphFocused = true }
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: curve.gains
            )
        }
        .frame(height: style.graphHeight)
        .accessibilityHint("Left and right select a band. Up and down adjust by half a decibel.")
    }

    private func graphGrid(in plot: CGRect) -> some View {
        ZStack {
            ForEach([-1.0, 0.0, 1.0], id: \.self) { marker in
                let y = yPosition(for: marker * range, in: plot)
                Path { path in
                    path.move(to: CGPoint(x: plot.minX, y: y))
                    path.addLine(to: CGPoint(x: plot.maxX, y: y))
                }
                .stroke(
                    marker == 0 ? Color.primary.opacity(0.26) : AuralisColor.hairline,
                    style: StrokeStyle(
                        lineWidth: marker == 0 ? 1.25 : 1,
                        dash: marker == 0 ? [] : [3, 4]
                    )
                )

                Text(marker == 0 ? "0" : String(format: "%+.0f", marker * range))
                    .font(AuralisTypography.metric(8))
                    .foregroundStyle(.tertiary)
                    .position(x: 17, y: y)
            }
        }
        .accessibilityHidden(true)
    }

    private func responsePath(in plot: CGRect) -> some View {
        Path { path in
            for index in 0..<EQCurve.bandCount {
                let point = CGPoint(
                    x: xPosition(for: index, in: plot),
                    y: yPosition(for: curve.gains[index], in: plot)
                )
                if index == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
        }
        .stroke(
            accent,
            style: StrokeStyle(lineWidth: 2.25, lineCap: .round, lineJoin: .round)
        )
        .accessibilityHidden(true)
    }

    private func bandNode(_ index: Int, in plot: CGRect) -> some View {
        let bandGain = curve.gains[index]
        let isSelected = selectedBand == index
        return ZStack {
            Circle()
                .fill(AuralisColor.panel)
                .frame(width: isSelected ? 16 : 13, height: isSelected ? 16 : 13)
            Circle()
                .stroke(accent, lineWidth: isSelected ? 3 : 2)
                .frame(width: isSelected ? 16 : 13, height: isSelected ? 16 : 13)
            if abs(bandGain) >= 0.05 {
                Circle()
                    .fill(accent)
                    .frame(width: 6, height: 6)
            }
        }
        .frame(
            width: AuralisSpacing.controlMinHit,
            height: AuralisSpacing.controlMinHit
        )
        .contentShape(Rectangle())
        .position(
            x: xPosition(for: index, in: plot),
            y: yPosition(for: bandGain, in: plot)
        )
        .onTapGesture {
            selectedBand = index
            graphFocused = true
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("eq-response"))
                .onChanged { value in
                    selectedBand = index
                    graphFocused = true
                    onGainEditingChanged(index, true)
                    onGain(index, gain(atY: value.location.y, in: plot))
                }
                .onEnded { _ in
                    onGainEditingChanged(index, false)
                }
        )
        .accessibilityElement()
        .accessibilityLabel("\(EQCurve.frequencies[index]) hertz")
        .accessibilityValue("\(String(format: "%+.1f", bandGain)) decibels")
        .accessibilityHint("Adjusts in half-decibel steps")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction {
            selectedBand = index
            graphFocused = true
        }
        .accessibilityAdjustableAction { direction in
            let delta: Double
            switch direction {
            case .increment: delta = 0.5
            case .decrement: delta = -0.5
            @unknown default: return
            }
            adjustBand(index, by: delta)
        }
    }

    private var selectedBandControls: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(0..<EQCurve.bandCount, id: \.self) { index in
                    Button {
                        selectedBand = index
                        graphFocused = true
                    } label: {
                        if selectedBand == index {
                            Label(frequencyLabel(index), systemImage: "checkmark")
                        } else {
                            Text(frequencyLabel(index))
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(frequencyLabel(selectedBand))
                        .font(AuralisTypography.metric(11))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .frame(minWidth: 72, minHeight: AuralisSpacing.comfortableControlHit)
                .background(AuralisColor.mutedPanel, in: RoundedRectangle(cornerRadius: 7))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel("Selected equalizer band")

            Button {
                adjustSelectedBand(by: -0.5)
            } label: {
                Image(systemName: "minus")
                    .frame(
                        width: AuralisSpacing.comfortableControlHit,
                        height: AuralisSpacing.comfortableControlHit
                    )
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Decrease \(frequencyLabel(selectedBand))")

            Text(String(format: "%+.1f dB", curve.gains[selectedBand]))
                .font(AuralisTypography.metric(style == .compact ? 11 : 12))
                .foregroundStyle(abs(curve.gains[selectedBand]) < 0.05 ? Color.secondary : accent)
                .frame(minWidth: 70)
                .accessibilityLabel(
                    "\(frequencyLabel(selectedBand)), \(String(format: "%+.1f", curve.gains[selectedBand])) decibels"
                )

            Button {
                adjustSelectedBand(by: 0.5)
            } label: {
                Image(systemName: "plus")
                    .frame(
                        width: AuralisSpacing.comfortableControlHit,
                        height: AuralisSpacing.comfortableControlHit
                    )
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Increase \(frequencyLabel(selectedBand))")

            Spacer(minLength: 0)

            Button(style == .compact ? "0 dB" : "Set 0 dB") {
                setBand(selectedBand, to: 0)
            }
            .controlSize(.small)
            .disabled(abs(curve.gains[selectedBand]) < 0.05)
            .help("Set \(frequencyLabel(selectedBand)) to zero decibels")
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(
                activeBandCount == 0
                    ? "Flat — drag a band to shape \(targetName)."
                    : "\(activeBandCount) adjusted band\(activeBandCount == 1 ? "" : "s")"
            )
            .font(AuralisTypography.content(.caption))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Button("Reset to flat", action: onReset)
                .controlSize(.small)
                .disabled(activeBandCount == 0)
                .accessibilityHint(
                    activeBandCount == 0
                        ? "Already flat"
                        : "Reset \(stage.title) for \(targetName)"
                )
        }
    }

    private var visibleFrequencyIndices: [Int] {
        switch style {
        case .desktop:
            Array(0..<EQCurve.bandCount)
        case .compact:
            [0, 2, 4, 6, 8, 9]
        }
    }

    private func plotRect(in size: CGSize) -> CGRect {
        CGRect(
            x: 34,
            y: 14,
            width: max(size.width - 44, 1),
            height: max(size.height - 42, 1)
        )
    }

    private func xPosition(for index: Int, in plot: CGRect) -> CGFloat {
        guard EQCurve.bandCount > 1 else { return plot.midX }
        return plot.minX
            + plot.width * CGFloat(index) / CGFloat(EQCurve.bandCount - 1)
    }

    private func yPosition(for gain: Double, in plot: CGRect) -> CGFloat {
        let normalized = min(max((gain + range) / (range * 2), 0), 1)
        return plot.maxY - plot.height * normalized
    }

    private func gain(atY y: CGFloat, in plot: CGRect) -> Double {
        let ratio = 1 - min(max((y - plot.minY) / plot.height, 0), 1)
        let raw = Double(ratio) * range * 2 - range
        return (raw * 2).rounded() / 2
    }

    private func frequencyLabel(_ index: Int) -> String {
        "\(EQCurve.frequencies[index]) Hz"
    }

    private func adjustSelectedBand(by delta: Double) {
        adjustBand(selectedBand, by: delta)
    }

    private func adjustBand(_ index: Int, by delta: Double) {
        setBand(index, to: curve.gains[index] + delta)
    }

    private func setBand(_ index: Int, to gain: Double) {
        let clamped = min(max(gain, -range), range)
        onGainEditingChanged(index, true)
        onGain(index, clamped)
        onGainEditingChanged(index, false)
    }
}

extension EQBandEditor {
    init(
        store: AudioControlStore,
        row: DisplayableAppRow,
        style: Style,
        onClose: @escaping () -> Void
    ) {
        self.init(
            stage: .process,
            targetName: row.displayName,
            curve: row.settings.eq,
            style: style,
            onClose: onClose,
            onGain: { band, gain in
                store.setEQGainIntent(gain, band: band, for: row.identity)
            },
            onGainEditingChanged: { band, editing in
                store.setEQEditingIntent(editing, band: band, for: row.identity)
            },
            onReset: {
                store.resetEQIntent(for: row.identity)
            }
        )
    }

    init(
        store: AudioControlStore,
        device: AudioDeviceSnapshot,
        style: Style,
        onClose: @escaping () -> Void
    ) {
        self.init(
            stage: .output,
            targetName: device.name,
            curve: store.settings.deviceSettings[device.id]?.eq
                ?? EQCurve(range: store.settings.customization.eqGainRange),
            style: style,
            onClose: onClose,
            onGain: { band, gain in
                store.setOutputEQGainIntent(gain, band: band, for: device.id)
            },
            onGainEditingChanged: { band, editing in
                store.setOutputEQEditingIntent(editing, band: band, for: device.id)
            },
            onReset: {
                store.resetOutputEQIntent(for: device.id)
            }
        )
    }
}

/// Compatibility alias for older embedding sites.
typealias EQPanelView = EQBandEditor
