import SwiftUI

struct EQPanelView: View {
    enum Style {
        case desktop
        case compact
    }

    let row: DisplayableAppRow
    var style: Style = .desktop
    let onClose: () -> Void
    let onGain: (Int, Double) -> Void
    var onGainEditingChanged: (Int, Bool) -> Void = { _, _ in }
    var onReset: () -> Void = {}

    private var range: Double {
        row.settings.eq.range.rawValue
    }

    private var activeBandCount: Int {
        row.settings.eq.gains.filter { abs($0) >= 0.05 }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: style == .compact ? 10 : 12) {
            header
            if style == .desktop {
                desktopBandGrid
            } else {
                compactBandGrid
            }
            footer
        }
        .padding(style == .compact ? 10 : 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.accentColor.opacity(0.25), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var header: some View {
        if style == .compact {
            compactHeader
        } else {
            desktopHeader
        }
    }

    private var desktopHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "slider.vertical.3")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("10-Band EQ")
                    .font(.subheadline.weight(.semibold))
                Text(row.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text("+/-\(Int(range)) dB")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button("Done", action: onClose)
                .controlSize(.small)
        }
    }

    private var compactHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "slider.vertical.3")
                .font(.subheadline)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("10-Band EQ")
                    .font(.caption.weight(.semibold))
                Text(row.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            Text("±\(Int(range)) dB")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
                .fixedSize()

            Button(action: onClose) {
                Image(systemName: "checkmark")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Done")
            .accessibilityLabel("Done")
        }
    }

    private var desktopBandGrid: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(0..<EQCurve.bandCount, id: \.self) { index in
                VerticalEQBand(
                    frequency: EQCurve.frequencies[index],
                    gain: row.settings.eq.gains[index],
                    range: range,
                    trackHeight: 190,
                    onGain: { onGain(index, $0) },
                    onEditingChanged: { onGainEditingChanged(index, $0) }
                )
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 14)
        .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var compactBandGrid: some View {
        HStack(alignment: .top, spacing: 2) {
            ForEach(0..<EQCurve.bandCount, id: \.self) { index in
                VerticalEQBand(
                    frequency: EQCurve.frequencies[index],
                    gain: row.settings.eq.gains[index],
                    range: range,
                    trackHeight: 92,
                    compact: true,
                    onGain: { onGain(index, $0) },
                    onEditingChanged: { onGainEditingChanged(index, $0) }
                )
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(activeBandCount == 0 ? "Flat EQ" : "\(activeBandCount) adjusted band\(activeBandCount == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Reset Flat") {
                onReset()
            }
            .controlSize(.small)
            .disabled(activeBandCount == 0)
        }
    }
}

private struct VerticalEQBand: View {
    let frequency: String
    let gain: Double
    let range: Double
    let trackHeight: Double
    var compact: Bool = false
    let onGain: (Double) -> Void
    let onEditingChanged: (Bool) -> Void

    var body: some View {
        VStack(spacing: compact ? 5 : 8) {
            Text(String(format: "%+.1f", gain))
                .font(compact ? .system(size: 9, weight: .medium, design: .monospaced) : .caption2.monospacedDigit())
                .foregroundStyle(abs(gain) < 0.05 ? Color.secondary : Color.accentColor)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)
            GeometryReader { proxy in
                let usableHeight = max(proxy.size.height - 14, 1)
                let normalized = min(max((gain + range) / (range * 2), 0), 1)
                let thumbY = (1 - normalized) * usableHeight
                ZStack(alignment: .top) {
                    Capsule().fill(Color(nsColor: .separatorColor).opacity(0.55))
                        .frame(width: 4)
                        .frame(maxWidth: .infinity)
                    Rectangle().fill(Color.secondary.opacity(0.28))
                        .frame(width: 14, height: 1)
                        .frame(maxWidth: .infinity)
                        .offset(y: usableHeight / 2 + 7)
                    Circle()
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(Circle().fill(Color.accentColor).frame(width: 7, height: 7))
                        .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
                        .frame(width: 18, height: 18)
                        .frame(maxWidth: .infinity)
                        .offset(y: thumbY)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onEditingChanged(true)
                        let ratio = 1 - min(max((value.location.y - 7) / usableHeight, 0), 1)
                        let raw = (ratio * range * 2) - range
                        onGain((raw * 2).rounded() / 2)
                    }
                    .onEnded { _ in onEditingChanged(false) }
                )
            }
            .frame(height: trackHeight)
            Text(frequency)
                .font(compact ? .system(size: 9, weight: .semibold, design: .monospaced) : .caption.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
            Text("Hz")
                .font(compact ? .system(size: 8) : .caption2)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(frequency) hertz")
        .accessibilityValue("\(String(format: "%+.1f", gain)) decibels")
        .accessibilityHint("Adjusts in half-decibel steps")
        .accessibilityAdjustableAction { direction in
            let adjustment: Double
            switch direction {
            case .increment:
                adjustment = 0.5
            case .decrement:
                adjustment = -0.5
            @unknown default:
                return
            }

            onEditingChanged(true)
            onGain(min(max(gain + adjustment, -range), range))
            onEditingChanged(false)
        }
    }
}
