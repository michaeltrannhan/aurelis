import AuralisWidgetShared
import SwiftUI
import WidgetKit

/// Preserves the installed EQ widget kind while giving every advertised family
/// a usable app remote. Ten-band EQ remains available in the large family.
struct AuralisEQWidgetView: View {
    let entry: AuralisEntry

    private var presentation: WidgetMixerPresentation {
        WidgetMixerPresentation(snapshot: entry.snapshot, date: entry.date, maximumAppCount: 2)
    }

    private var app: WidgetSnapshot.AppSummary? {
        entry.snapshot.apps.first(where: \.isActive)
            ?? entry.snapshot.apps.first(where: \.isPinned)
            ?? entry.snapshot.apps.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                AuralisWidgetMark().frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Quick Remote").font(.caption.weight(.semibold))
                    if !presentation.controlsEnabled {
                        Text("Open Auralis").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                WidgetOpenLink()
            }
            if let app {
                if entry.family == .systemSmall {
                    compactRemote(app)
                } else if entry.family == .systemLarge {
                    WidgetAppRow(app: app, volumeStep: entry.snapshot.volumeStep,
                                 controlsEnabled: presentation.controlsEnabled)
                    WidgetEQChart(app: app, controlsEnabled: presentation.controlsEnabled)
                    Text("Process EQ · 0.5 dB steps").font(.caption2).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(app.displayName).font(.headline).lineLimit(1)
                            Text(app.isMuted ? "Muted" : "\(Int((app.volume * 100).rounded()))%")
                                .font(.system(size: 25, weight: .semibold, design: .rounded).monospacedDigit())
                            WidgetVolumeRail(volume: app.volume, isMuted: app.isMuted)
                            Text(app.routeLabel).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        VStack(spacing: 6) {
                            appControls(app)
                            boostButton(app)
                        }
                    }
                }
            } else {
                Text(presentation.controlsEnabled ? "Play audio to control an app" : "Open Auralis to use controls")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .tint(WidgetPalette.cyan)
    }

    private func compactRemote(_ app: WidgetSnapshot.AppSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(app.displayName).font(.caption.weight(.medium)).lineLimit(1)
            HStack {
                Text(app.isMuted ? "Muted" : "\(Int((app.volume * 100).rounded()))%")
                    .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                Spacer(minLength: 0)
                boostButton(app)
            }
            WidgetVolumeRail(volume: app.volume, isMuted: app.isMuted)
            appControls(app)
        }
    }

    private func appControls(_ app: WidgetSnapshot.AppSummary) -> some View {
        HStack(spacing: 4) {
            Button(intent: AdjustAppVolumeIntent(appID: app.id, delta: -entry.snapshot.volumeStep)) {
                controlIcon("minus")
            }
            .accessibilityLabel(WidgetMixerPresentation.volumeLabel(name: app.displayName, direction: -1))
            Button(intent: ToggleAppMutedIntent(appID: app.id)) {
                controlIcon(app.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .accessibilityLabel(WidgetMixerPresentation.muteLabel(name: app.displayName, isMuted: app.isMuted))
            Button(intent: AdjustAppVolumeIntent(appID: app.id, delta: entry.snapshot.volumeStep)) {
                controlIcon("plus")
            }
            .accessibilityLabel(WidgetMixerPresentation.volumeLabel(name: app.displayName, direction: 1))
        }
        .buttonStyle(.plain)
        .disabled(!presentation.controlsEnabled)
    }

    private func controlIcon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.caption.weight(.semibold))
            .frame(width: 30, height: 28)
            .background(WidgetPalette.panel, in: RoundedRectangle(cornerRadius: 7))
    }

    private func boostButton(_ app: WidgetSnapshot.AppSummary) -> some View {
        Button(intent: CycleAppBoostIntent(appID: app.id)) {
            Text("\(Int(app.boost))×").font(.caption.weight(.semibold))
                .frame(minWidth: 32, minHeight: 28)
                .background(WidgetPalette.panel, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain).disabled(!presentation.controlsEnabled)
        .accessibilityLabel(WidgetMixerPresentation.boostLabel(name: app.displayName))
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
                    .foregroundStyle(abs(gain) < 0.05 ? Color.secondary : WidgetPalette.cyan)
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
                    .offset(y: 12)
                Circle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(Circle().fill(WidgetPalette.cyan).frame(width: 6, height: 6))
                    .frame(width: 12, height: 12)
                    .offset(y: (1 - normalized) * 18)
            }
            .frame(height: 30)

            HStack(spacing: 4) {
                gainButton(index: index, direction: -1, systemName: "minus")
                gainButton(index: index, direction: 1, systemName: "plus")
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, minHeight: 80)
        .background(WidgetPalette.panel, in: RoundedRectangle(cornerRadius: 9))
    }

    private func gainButton(
        index: Int,
        direction: Double,
        systemName: String
    ) -> some View {
        Button(intent: AdjustEQBandGainAppIntent(
            appID: app.id,
            band: index,
            delta: direction * 0.5
        )) {
            Image(systemName: systemName)
                .font(.system(size: 8, weight: .bold))
                .frame(maxWidth: .infinity)
                .frame(height: 20)
                .background(WidgetPalette.cyan.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
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

}

/// Frequency labels shared with `EQCurve.frequencies` in the app. Defined here
/// (not imported) so the widget target stays self-contained.
enum EQCurveFrequencies {
    static let values = ["31", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
}
