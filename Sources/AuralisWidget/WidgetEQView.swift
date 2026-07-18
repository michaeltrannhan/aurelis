import AuralisWidgetShared
import SwiftUI
import WidgetKit

/// systemLarge widget view: shows the mixer (compact rows) plus a 10-band EQ
/// chart for the first active app, with ±0.5 dB buttons per band. Visual parity
/// with `EQPanelView.desktopBandGrid` (vertical band thumbs) but with widget-
/// safe button controls instead of drag gestures.
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
        VStack(alignment: .leading, spacing: 6) {
            header
            Divider()
            mixerRows
            if let app = eqApp {
                Divider()
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
        .padding(6)
    }

    private var header: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.16))
                Image(systemName: "slider.vertical.3")
                    .font(.callout)
                    .foregroundStyle(Color.accentColor)
            }
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

    private var mixerRows: some View {
        let apps = presentation.apps
        return VStack(spacing: 4) {
            ForEach(apps) { app in
                WidgetAppRow(
                    app: app,
                    volumeStep: entry.snapshot.volumeStep,
                    controlsEnabled: controlsEnabled,
                    showEQButton: false
                )
            }
            if apps.isEmpty {
                Text("No audio apps")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 4)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Drag bands in the app for fine control")
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

/// 10-band EQ chart with ±0.5 dB buttons per band. Mirrors the visual style of
/// `EQPanelView`'s vertical band grid: thumb position on a vertical track,
/// frequency label below. The drag gesture is replaced by two buttons.
struct WidgetEQChart: View {
    let app: WidgetSnapshot.AppSummary
    let controlsEnabled: Bool
    private let frequencies = EQCurveFrequencies.values
    private let range: Double

    init(app: WidgetSnapshot.AppSummary, controlsEnabled: Bool) {
        self.app = app
        self.controlsEnabled = controlsEnabled
        self.range = app.eqRange > 0 ? app.eqRange : 12
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "slider.vertical.3")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
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

            HStack(alignment: .top, spacing: 2) {
                ForEach(app.eqGains.indices, id: \.self) { index in
                    bandColumn(index: index)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func bandColumn(index: Int) -> some View {
        let gain = app.eqGains[index]
        let normalized = min(max((gain + range) / (range * 2), 0), 1)
        return VStack(spacing: 3) {
            Text(String(format: "%+.1f", gain))
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(abs(gain) < 0.05 ? Color.secondary : Color.accentColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            ZStack(alignment: .top) {
                Capsule()
                    .fill(Color(nsColor: .separatorColor).opacity(0.55))
                    .frame(width: 3)
                Rectangle()
                    .fill(Color.secondary.opacity(0.28))
                    .frame(width: 12, height: 1)
                    .offset(y: 28)
                Circle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(Circle().fill(Color.accentColor).frame(width: 6, height: 6))
                    .frame(width: 14, height: 14)
                    .offset(y: (1 - normalized) * 52)
            }
            .frame(height: 60)

            HStack(spacing: 1) {
                Button(intent: SetEQBandGainAppIntent(
                    appID: app.id,
                    band: index,
                    gain: steppedGain(gain, direction: -1)
                )) {
                    Image(systemName: "minus")
                        .font(.system(size: 7, weight: .bold))
                }
                .disabled(!controlsEnabled)
                .accessibilityLabel(
                    WidgetMixerPresentation.eqBandLabel(
                        appName: app.displayName,
                        frequency: frequencies[index],
                        direction: -1
                    )
                )
                Button(intent: SetEQBandGainAppIntent(
                    appID: app.id,
                    band: index,
                    gain: steppedGain(gain, direction: 1)
                )) {
                    Image(systemName: "plus")
                        .font(.system(size: 7, weight: .bold))
                }
                .disabled(!controlsEnabled)
                .accessibilityLabel(
                    WidgetMixerPresentation.eqBandLabel(
                        appName: app.displayName,
                        frequency: frequencies[index],
                        direction: 1
                    )
                )
            }

            Text(frequencies[index])
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
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
