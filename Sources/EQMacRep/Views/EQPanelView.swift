import SwiftUI

struct EQPanelView: View {
    let row: DisplayableAppRow
    let onClose: () -> Void
    let onGain: (Int, Double) -> Void

    private var range: Double {
        row.settings.eq.range.rawValue
    }

    private var activeBandCount: Int {
        row.settings.eq.gains.filter { abs($0) >= 0.05 }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            bandGrid
            footer
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.accentColor.opacity(0.25), lineWidth: 1)
        )
    }

    private var header: some View {
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

    private var bandGrid: some View {
        VStack(spacing: 8) {
            ForEach(0..<EQCurve.bandCount, id: \.self) { index in
                EQBandRow(
                    frequency: EQCurve.frequencies[index],
                    gain: row.settings.eq.gains[index],
                    range: range,
                    onGain: { onGain(index, $0) }
                )
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(activeBandCount == 0 ? "Flat EQ" : "\(activeBandCount) adjusted band\(activeBandCount == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Reset Flat") {
                for index in 0..<EQCurve.bandCount {
                    onGain(index, 0)
                }
            }
            .controlSize(.small)
            .disabled(activeBandCount == 0)
        }
    }
}

private struct EQBandRow: View {
    let frequency: String
    let gain: Double
    let range: Double
    let onGain: (Double) -> Void

    private var normalizedGain: Double {
        guard range > 0 else { return 0 }
        return min(max(gain / range, -1), 1)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(frequency)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: .separatorColor).opacity(0.35))
                    .frame(height: 6)
                GeometryReader { geometry in
                    let center = geometry.size.width / 2
                    let width = abs(normalizedGain) * center
                    Capsule()
                        .fill(gain >= 0 ? Color.accentColor : Color.orange)
                        .frame(width: width, height: 6)
                        .offset(x: gain >= 0 ? center : center - width)
                }
                .frame(height: 6)
            }
            .frame(width: 72)

            Slider(
                value: Binding(
                    get: { gain },
                    set: { onGain($0) }
                ),
                in: -range...range,
                step: 0.5
            )
            .controlSize(.small)

            Stepper(
                value: Binding(
                    get: { gain },
                    set: { onGain($0) }
                ),
                in: -range...range,
                step: 0.5
            ) {
                Text(String(format: "%+.1f", gain))
                    .font(.caption.monospacedDigit())
                    .frame(width: 48, alignment: .trailing)
            }
            .labelsHidden()
            .frame(width: 74)

            Button {
                onGain(0)
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(abs(gain) < 0.05)
            .help("Reset \(frequency) Hz")
        }
    }
}
