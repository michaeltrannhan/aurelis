import AuralisWidgetShared
import SwiftUI
import WidgetKit

/// Mixer widget view. Renders rows that visually mirror `MainWindowView`'s
/// `AppRowView` but use widget-compatible interactive controls:
///
/// - Mute → `Toggle` (AppIntent)
/// - Volume slider → Up/Down `Button`s (AppIntent)
/// - Boost menu → cyclic `Button` (AppIntent)
/// - Output picker / EQ opener → `Link` into the app
///
/// The layout, colors, corner radii, and typography match the desktop window.
struct AuralisMixerWidgetView: View {
    let entry: AuralisEntry

    private var presentation: WidgetMixerPresentation {
        WidgetMixerPresentation(snapshot: entry.snapshot, date: entry.date, maximumAppCount: 3)
    }

    private var controlsEnabled: Bool {
        presentation.controlsEnabled
    }

    private var statusText: String {
        presentation.statusText
    }

    var body: some View {
        switch entry.family {
        case .systemSmall:
            smallBody
        default:
            mediumBody
        }
    }

    // MARK: - systemSmall

    private var smallBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "waveform.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                Text("Auralis")
                    .font(.headline)
                Spacer(minLength: 0)
            }
            Text(statusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Divider()

            if let device = presentation.defaultDevice {
                smallDeviceRow(device)
            } else {
                Text("No output device")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            Link(destination: URL(string: "auralis://open")!) {
                Label("Open Mixer", systemImage: "arrow.up.right.square")
                    .font(.caption2.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(4)
    }

    private func smallDeviceRow(_ device: WidgetSnapshot.DeviceSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: device.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(device.isMuted ? Color.red : Color.accentColor)
                    .font(.callout)
                Text(device.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(Int((device.volume * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Gauge(value: device.volume, in: 0...1) {
                EmptyView()
            }
            .gaugeStyle(.accessoryLinear)
            .tint(device.isMuted ? .secondary : .accentColor)
            Button(intent: SetOutputDeviceMutedIntent(deviceID: device.id, muted: !device.isMuted)) {
                Image(systemName: device.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(device.isMuted ? Color.red : Color.accentColor)
            }
            .disabled(!controlsEnabled)
            .help(device.isMuted ? "Unmute \(device.name)" : "Mute \(device.name)")
            .accessibilityLabel(
                WidgetMixerPresentation.muteLabel(name: device.name, isMuted: device.isMuted)
            )
        }
    }

    // MARK: - systemMedium

    private var mediumBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            mediumHeader
            Divider()
            mediumRows
            Spacer(minLength: 0)
            mediumFooter
        }
        .padding(6)
    }

    private var mediumHeader: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.16))
                Image(systemName: "waveform.circle.fill")
                    .font(.callout)
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("Auralis Mixer")
                    .font(.subheadline.weight(.semibold))
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(presentation.activeCountText)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
            Button(intent: RefreshAppIntent()) {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(!controlsEnabled)
            .help("Refresh audio apps")
            .accessibilityLabel("Refresh audio apps")
        }
    }

    private var mediumRows: some View {
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
                    .padding(.vertical, 8)
            }
        }
    }

    private var mediumFooter: some View {
        HStack {
            Text("Open app for full mixer")
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

/// One app row in the mixer widget. Visual parity with `AppRowView.desktopBody`
/// (icon, name, route label, level meter, mute, volume %, boost) but with
/// widget-safe controls.
struct WidgetAppRow: View {
    let app: WidgetSnapshot.AppSummary
    let volumeStep: Double
    let controlsEnabled: Bool
    let showEQButton: Bool

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.16))
                Image(systemName: "waveform")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Text(app.displayName)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    if app.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(app.routeLabel)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            WidgetLevelMeter(level: app.level, isMuted: app.isMuted)
                .frame(width: 8, height: 22)

            Button(intent: SetAppMutedIntent(appID: app.id, muted: !app.isMuted)) {
                Image(systemName: app.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(app.isMuted ? Color.red : Color.secondary)
                    .frame(width: 22, height: 22)
            }
            .disabled(!controlsEnabled)
            .help(app.isMuted ? "Unmute" : "Mute")
            .accessibilityLabel(
                WidgetMixerPresentation.muteLabel(name: app.displayName, isMuted: app.isMuted)
            )

            Button(intent: SetAppVolumeIntent(appID: app.id, volume: steppedVolume(-1))) {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 18, height: 22)
            }
            .disabled(!controlsEnabled)
            .help("Volume down")
            .accessibilityLabel(
                WidgetMixerPresentation.volumeLabel(name: app.displayName, direction: -1)
            )

            Text("\(Int((app.volume * 100).rounded()))%")
                .font(.caption2.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)

            Button(intent: SetAppVolumeIntent(appID: app.id, volume: steppedVolume(1))) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 18, height: 22)
            }
            .disabled(!controlsEnabled)
            .help("Volume up")
            .accessibilityLabel(
                WidgetMixerPresentation.volumeLabel(name: app.displayName, direction: 1)
            )

            Button(intent: SetBoostAppIntent(appID: app.id, boost: nextBoost)) {
                Text(boostLabel)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(app.boost > 1 ? Color.accentColor : Color.primary)
                    .padding(.horizontal, 5)
                    .frame(height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(app.boost > 1 ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.09))
                    )
            }
            .disabled(!controlsEnabled)
            .help("Cycle boost")
            .accessibilityLabel(WidgetMixerPresentation.boostLabel(name: app.displayName))

            if showEQButton {
                Link(destination: URL(string: "auralis://open")!) {
                    Image(systemName: "slider.vertical.3")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 22, height: 22)
                }
                .help("Open EQ in app")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(app.displayName)
        .accessibilityValue(WidgetMixerPresentation.appValue(app))
    }

    private var boostLabel: String {
        app.boost == 1 ? "1×" : "\(Int(app.boost))×"
    }

    private var nextBoost: Double {
        switch app.boost {
        case 1: 2
        case 2: 3
        case 3: 4
        default: 1
        }
    }

    private func steppedVolume(_ direction: Double) -> Double {
        min(max(app.volume + direction * volumeStep, 0), 1)
    }
}

/// Vertical 8-segment level meter matching `AudioLevelMeter` in `AppRowView`.
struct WidgetLevelMeter: View {
    let level: Double
    let isMuted: Bool
    private let thresholds = [0.01, 0.03, 0.10, 0.20, 0.32, 0.50, 0.70, 0.90]

    var body: some View {
        VStack(spacing: 1) {
            ForEach(thresholds.indices.reversed(), id: \.self) { index in
                Capsule().fill(color(index).opacity(level >= thresholds[index] ? 1 : 0.18))
            }
        }
        .animation(.linear(duration: 0.08), value: level)
    }

    private func color(_ index: Int) -> Color {
        if isMuted { return .secondary }
        if index >= 7 { return .red }
        if index >= 5 { return .yellow }
        return .green
    }
}
