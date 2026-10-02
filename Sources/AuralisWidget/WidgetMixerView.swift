import AuralisWidgetShared
import SwiftUI
import WidgetKit

/// Each family prioritizes controls that fit its available space. Commands use
/// the existing AppIntent transport; the widget never owns audio work.
struct AuralisMixerWidgetView: View {
    let entry: AuralisEntry

    private var presentation: WidgetMixerPresentation {
        WidgetMixerPresentation(snapshot: entry.snapshot, date: entry.date, maximumAppCount: 2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: entry.family == .systemLarge ? 10 : (entry.family == .systemMedium ? 4 : 6)) {
            header
            if entry.family == .systemSmall {
                smallOutput
            } else {
                outputRow
                if entry.family == .systemLarge {
                    outputChoices
                    presets
                    quickActions
                }
                appRows
            }
            Spacer(minLength: 0)
        }
        .padding(entry.family == .systemMedium ? 8 : 12)
        .tint(WidgetPalette.cyan)
    }

    private var header: some View {
        HStack(spacing: 6) {
            AuralisWidgetMark().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.family == .systemSmall ? "Auralis" : "Auralis Mixer")
                    .font(.caption.weight(.semibold))
                Text(presentation.controlsEnabled ? presentation.activeCountText : "Open Auralis")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            WidgetOpenLink().frame(height: entry.family == .systemMedium ? 22 : 28)
        }
    }

    @ViewBuilder private var smallOutput: some View {
        if let device = presentation.defaultDevice {
            Text(device.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack(alignment: .firstTextBaseline) {
                Text("\(Int((device.volume * 100).rounded()))%")
                    .font(.system(size: 25, weight: .semibold, design: .rounded).monospacedDigit())
                Spacer(minLength: 0)
                if device.isMuted { Text("Muted").font(.caption2).foregroundStyle(.secondary) }
            }
            WidgetVolumeRail(volume: device.volume, isMuted: device.isMuted)
            WidgetOutputControls(device: device, volumeStep: entry.snapshot.volumeStep,
                                 controlsEnabled: presentation.controlsEnabled)
        } else {
            emptyOutput
        }
    }

    @ViewBuilder private var outputRow: some View {
        if let device = presentation.defaultDevice {
            HStack(spacing: 8) {
                Image(systemName: "hifispeaker.fill").foregroundStyle(WidgetPalette.cyan)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(device.name).lineLimit(1)
                        Spacer(minLength: 2)
                        Text("\(Int((device.volume * 100).rounded()))%")
                            .monospacedDigit()
                    }.font(.caption2.weight(.medium))
                    WidgetVolumeRail(volume: device.volume, isMuted: device.isMuted)
                }
                WidgetOutputControls(device: device, volumeStep: entry.snapshot.volumeStep,
                                     controlsEnabled: presentation.controlsEnabled)
            }
            .padding(entry.family == .systemMedium ? 4 : 6)
            .background(WidgetPalette.panel, in: RoundedRectangle(cornerRadius: 9))
        } else {
            emptyOutput
        }
    }

    private var emptyOutput: some View {
        Text(presentation.controlsEnabled ? "No output connected" : "Open Auralis to use controls")
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
    }

    private var appRows: some View {
        VStack(spacing: 4) {
            ForEach(presentation.apps) { app in
                WidgetAppRow(app: app, volumeStep: entry.snapshot.volumeStep,
                             controlsEnabled: presentation.controlsEnabled)
            }
            if presentation.apps.isEmpty {
                Text(presentation.controlsEnabled ? "Play audio to see your apps" : "Your apps appear when Auralis is running")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var outputChoices: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle("OUTPUTS")
            HStack(spacing: 5) {
                ForEach(Array(presentation.devices.prefix(3))) { device in
                    Button(intent: SetDefaultOutputDeviceIntent(deviceID: device.id)) {
                        Label(device.name, systemImage: device.isDefault ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 10, weight: .medium)).lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .background(WidgetPalette.panel, in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(device.isDefault ? WidgetPalette.cyan : Color.primary)
                    .disabled(!presentation.controlsEnabled || device.isDefault)
                    .accessibilityLabel("Use \(device.name) as output")
                }
            }
        }
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle("OUTPUT PRESETS")
            HStack(spacing: 5) {
                ForEach(Array(presentation.globalProfiles.prefix(3))) { profile in
                    Button(intent: AssignAudioPresetToCurrentOutputIntent(profileID: profile.id)) {
                        Label(profile.name, systemImage: presentation.isPresetActive(profile) ? "checkmark.circle.fill" : "square.stack.3d.up")
                            .font(.system(size: 10, weight: .medium)).lineLimit(1)
                            .padding(.horizontal, 8).frame(height: 28)
                            .background(WidgetPalette.panel, in: Capsule())
                    }
                    .buttonStyle(.plain).disabled(!presentation.controlsEnabled)
                    .accessibilityLabel("Use \(profile.name) for the current output")
                }
                if presentation.globalProfiles.isEmpty {
                    Link("Create presets in Auralis", destination: AuralisDeepLink.openMixer).font(.caption)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var quickActions: some View {
        HStack(spacing: 5) {
            Button(intent: SetAllAppsMutedIntent(muted: true)) { actionLabel("Mute all", "speaker.slash.fill") }
            Button(intent: SetAllAppsMutedIntent(muted: false)) { actionLabel("Unmute", "speaker.wave.2.fill") }
            Button(intent: SetAllAppsVolumeIntent(volume: 0.5)) { actionLabel("All 50%", "dial.medium") }
        }
        .buttonStyle(.plain)
        .disabled(!presentation.controlsEnabled || !presentation.hasActiveApps)
    }

    private func actionLabel(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.system(size: 10, weight: .medium))
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(WidgetPalette.panel, in: RoundedRectangle(cornerRadius: 7))
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
    }
}

struct WidgetOutputControls: View {
    let device: WidgetSnapshot.DeviceSummary
    let volumeStep: Double
    let controlsEnabled: Bool

    var body: some View {
        HStack(spacing: 3) {
            Button(intent: AdjustOutputDeviceVolumeIntent(deviceID: device.id, delta: -volumeStep)) {
                Image(systemName: "minus")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .disabled(!controlsEnabled)
            .accessibilityLabel(WidgetMixerPresentation.volumeLabel(name: device.name, direction: -1))

            Button(intent: ToggleOutputDeviceMutedIntent(deviceID: device.id)) {
                Image(systemName: device.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(device.isMuted ? Color.red : WidgetPalette.cyan)
                    .frame(width: 28, height: 28)
            }
            .disabled(!controlsEnabled)
            .accessibilityLabel(WidgetMixerPresentation.muteLabel(name: device.name, isMuted: device.isMuted))

            Button(intent: AdjustOutputDeviceVolumeIntent(deviceID: device.id, delta: volumeStep)) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .disabled(!controlsEnabled)
            .accessibilityLabel(WidgetMixerPresentation.volumeLabel(name: device.name, direction: 1))
        }
        .buttonStyle(.plain)
    }

}

/// One app row in the mixer widget. Visual parity with `AppRowView.desktopBody`
/// (icon, name, route label, level meter, mute, volume %, boost) but with
/// widget-safe controls.
struct WidgetAppRow: View {
    let app: WidgetSnapshot.AppSummary
    let volumeStep: Double
    let controlsEnabled: Bool

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(WidgetPalette.cyan.opacity(0.16))
                AuralisAudioGlyph()
            }
            .frame(width: 24, height: 26)

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
                Text(app.isMuted ? "Muted · \(app.routeLabel)" : app.routeLabel)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            WidgetLevelMeter(level: controlsEnabled ? app.level : 0, isMuted: app.isMuted)
                .frame(width: 8, height: 22)

            Button(intent: ToggleAppMutedIntent(appID: app.id)) {
                Image(systemName: app.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(app.isMuted ? Color.red : Color.secondary)
                    .frame(width: 24, height: 26)
            }
            .disabled(!controlsEnabled)
            .help(app.isMuted ? "Unmute" : "Mute")
            .accessibilityLabel(
                WidgetMixerPresentation.muteLabel(name: app.displayName, isMuted: app.isMuted)
            )

            Button(intent: AdjustAppVolumeIntent(appID: app.id, delta: -volumeStep)) {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 24, height: 26)
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

            Button(intent: AdjustAppVolumeIntent(appID: app.id, delta: volumeStep)) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 24, height: 26)
            }
            .disabled(!controlsEnabled)
            .help("Volume up")
            .accessibilityLabel(
                WidgetMixerPresentation.volumeLabel(name: app.displayName, direction: 1)
            )

            Button(intent: CycleAppBoostIntent(appID: app.id)) {
                Text(boostLabel)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(app.boost > 1 ? WidgetPalette.cyan : Color.primary)
                    .padding(.horizontal, 5)
                    .frame(height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(app.boost > 1 ? WidgetPalette.cyan.opacity(0.12) : Color.secondary.opacity(0.09))
                    )
            }
            .disabled(!controlsEnabled)
            .help("Cycle boost")
            .accessibilityLabel(WidgetMixerPresentation.boostLabel(name: app.displayName))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(app.displayName)
        .accessibilityValue(WidgetMixerPresentation.appValue(app))
    }

    private var boostLabel: String {
        app.boost == 1 ? "1×" : "\(Int(app.boost))×"
    }


}

/// Vertical 8-segment level meter matching `AudioLevelMeter` in `AppRowView`.
struct WidgetLevelMeter: View {
    let level: Double
    let isMuted: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let thresholds = [0.01, 0.03, 0.10, 0.20, 0.32, 0.50, 0.70, 0.90]

    var body: some View {
        VStack(spacing: 1) {
            ForEach(thresholds.indices.reversed(), id: \.self) { index in
                Capsule().fill(color(index).opacity(level >= thresholds[index] ? 1 : 0.18))
            }
        }
        .animation(reduceMotion ? nil : .linear(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }

    private func color(_ index: Int) -> Color {
        if isMuted { return .secondary }
        if index >= 7 { return .red }
        if index >= 5 { return .yellow }
        return .green
    }
}
