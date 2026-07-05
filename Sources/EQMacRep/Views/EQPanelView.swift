import SwiftUI

struct EQPanelView: View {
    let row: DisplayableAppRow
    let onGain: (Int, Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Equalizer")
                    .font(.subheadline.weight(.semibold))
                Text(row.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(alignment: .bottom, spacing: 10) {
                ForEach(0..<EQCurve.bandCount, id: \.self) { index in
                    VStack(spacing: 6) {
                        Text(String(format: "%+.0f", row.settings.eq.gains[index]))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Slider(
                            value: Binding(
                                get: { row.settings.eq.gains[index] },
                                set: { onGain(index, $0) }
                            ),
                            in: -row.settings.eq.range.rawValue...row.settings.eq.range.rawValue,
                            step: 0.5
                        )
                        .rotationEffect(.degrees(-90))
                        .frame(width: 24, height: 120)
                        Text(EQCurve.frequencies[index])
                            .font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 8)
        }
    }
}
