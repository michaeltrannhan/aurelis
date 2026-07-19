import AuralisWidgetShared
import SwiftUI
import WidgetKit

/// systemLarge widget view: a focused 10-band EQ for the first active app.
/// macOS doesn't provide an extra-large widget family, so the ten bands use a
/// two-row layout instead of squeezing every control into one 344-point row.
struct AuralisEQWidgetView: View {
    let entry: AuralisEntry

    private var presentation: WidgetMixerPresentation {
        WidgetMixerPresentation(snapshot: entry.snapshot, date: entry.date, maximumAppCount: 2)
    }

    private var controlsEnabled: Bool {
        presentation.controlsEnabled
    }

    private var eqApp: WidgetSnapshot.AppSummary? {
        entry.snapshot.apps.first(where: \.isActive) ?? entry.snapshot.apps.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
            if let app = eqApp {
                WidgetEQChart(app: app, controlsEnabled: controlsEnabled)
            } else {
                Spacer(minLength: 0)
                Text("No audio app to equalize")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer(minLength: 0)
            }
            footer
        }
        .padding(10)
    }

    private var header: some View {
        HStack(spacing: 8) {
            AuralisWidgetMark()
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("Auralis EQ")
                    .font(.subheadline.weight(.semibold))
                Text(controlsEnabled ? entry.snapshot.statusMessage : "Open Auralis to use controls")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(intent: RefreshAppIntent()) {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(!controlsEnabled)
            .accessibilityLabel("Refresh audio apps")
        }
    }

    private var footer: some View {
        HStack {
            Text("0.5 dB steps · Fine-tune in the app")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            Link(destination: URL(string: "auralis://open")!) {
                Label("Open", systemImage: "arrow.up.right.square")
                    .font(.caption2.weight(.semibold))
            }
        }
    }
}

/// Ten compact band cards arranged as two rows of five. Each card retains a
/// vertical gain indicator and exposes widget-safe step buttons.
struct WidgetEQChart: View {
    let app: WidgetSnapshot.AppSummary
    let controlsEnabled: Bool
    private let frequencies = EQCurveFrequencies.values
    private let columns = Array(
        repeating: GridItem(.flexible(minimum: 0), spacing: 6),
        count: 5
    )
    private let range: Double

    init(app: WidgetSnapshot.AppSummary, controlsEnabled: Bool) {
        self.app = app
        self.controlsEnabled = controlsEnabled
        self.range = app.eqRange > 0 ? app.eqRange : 12
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                AuralisAudioGlyph()
                    .scaleEffect(0.72)
                    .frame(width: 14, height: 14)
                Text(app.displayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("±\(Int(range)) dB")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }

            LazyVGrid(columns: columns, alignment: .center, spacing: 8) {
                ForEach(0..<min(app.eqGains.count, frequencies.count), id: \.self) { index in
                    bandColumn(index: index)
                }
            }
        }
    }

    private func bandColumn(index: Int) -> some View {
        let gain = app.eqGains[index]
        let normalized = min(max((gain + range) / (range * 2), 0), 1)
        return VStack(spacing: 4) {
            HStack(spacing: 2) {
                Text(frequencies[index])
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(String(format: "%+.1f", gain))
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(abs(gain) < 0.05 ? Color.secondary : Color.accentColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            ZStack(alignment: .top) {
                Capsule()
                    .fill(Color(nsColor: .separatorColor).opacity(0.55))
                    .frame(width: 3)
                Rectangle()
                    .fill(Color.secondary.opacity(0.28))
                    .frame(width: 14, height: 1)
                    .offset(y: 18)
                Circle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(Circle().fill(Color.accentColor).frame(width: 6, height: 6))
                    .frame(width: 12, height: 12)
                    .offset(y: (1 - normalized) * 30)
            }
            .frame(height: 42)

            HStack(spacing: 4) {
                gainButton(index: index, gain: gain, direction: -1, systemName: "minus")
                gainButton(index: index, gain: gain, direction: 1, systemName: "plus")
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, minHeight: 92)
        .background(Color.black.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
    }

    private func gainButton(
        index: Int,
        gain: Double,
        direction: Double,
        systemName: String
    ) -> some View {
        Button(intent: SetEQBandGainAppIntent(
            appID: app.id,
            band: index,
            gain: steppedGain(gain, direction: direction)
        )) {
            Image(systemName: systemName)
                .font(.system(size: 8, weight: .bold))
                .frame(maxWidth: .infinity)
                .frame(height: 20)
                .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!controlsEnabled)
        .opacity(controlsEnabled ? 1 : 0.45)
        .accessibilityLabel(
            WidgetMixerPresentation.eqBandLabel(
                appName: app.displayName,
                frequency: frequencies[index],
                direction: direction < 0 ? -1 : 1
            )
        )
    }

    private func steppedGain(_ gain: Double, direction: Double) -> Double {
        min(max(gain + direction * 0.5, -range), range)
    }
}

/// Frequency labels shared with `EQCurve.frequencies` in the app. Defined here
/// (not imported) so the widget target stays self-contained.
enum EQCurveFrequencies {
    static let values = ["31", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
}
