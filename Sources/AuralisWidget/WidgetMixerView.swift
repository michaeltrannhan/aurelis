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
        WidgetMixerPresentation(
            snapshot: entry.snapshot,
            date: entry.date,
            maximumAppCount: 2
        )
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
        case .systemLarge:
            largeBody
        default:
            mediumBody
        }
    }

    // MARK: - systemSmall

    private var smallBody: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                AuralisWidgetMark()
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Auralis")
                        .font(.subheadline.weight(.semibold))
                    Text(compactConfigurationSummary)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Link(destination: AuralisDeepLink.openMixer) {
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.semibold))
                }
            }

            if let device = presentation.defaultDevice {
                smallDeviceRow(device)
            } else {
                Text("No output device")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)
            Text(controlsEnabled ? presentation.activeCountText : statusText)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(4)
    }

    private func smallDeviceRow(_ device: WidgetSnapshot.DeviceSummary) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 4) {
                Image(systemName: "hifispeaker.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.caption)
                Text(device.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(Int((device.volume * 100).rounded()))")
                    .font(.system(size: 27, weight: .semibold, design: .rounded).monospacedDigit())
                Text("%")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: device.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(device.isMuted ? Color.red : Color.accentColor)
            }

            WidgetOutputControls(
                device: device,
                volumeStep: entry.snapshot.volumeStep,
                controlsEnabled: controlsEnabled
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(device.name)
        .accessibilityValue(WidgetMixerPresentation.outputValue(device))
    }

    // MARK: - systemMedium

    private var mediumBody: some View {
        VStack(alignment: .leading, spacing: 5) {
            mediumHeader
            if let device = presentation.defaultDevice {
                mediumOutputRow(device)
            }
            mediumRows
            Spacer(minLength: 0)
        }
        .padding(5)
    }

    private var mediumHeader: some View {
        HStack(spacing: 8) {
            AuralisWidgetMark()
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

    private func mediumOutputRow(_ device: WidgetSnapshot.DeviceSummary) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "hifispeaker.fill")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 0) {
                Text(device.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(compactConfigurationSummary)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if presentation.devices.count > 1, let nextDevice {
                Button(intent: SetDefaultOutputDeviceIntent(deviceID: nextDevice.id)) {
                    Image(systemName: "arrow.triangle.swap")
                        .font(.system(size: 10, weight: .semibold))
                }
                .disabled(!controlsEnabled)
                .help("Switch output to \(nextDevice.name)")
            }

            Text("\(Int((device.volume * 100).rounded()))%")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .frame(width: 30, alignment: .trailing)

            WidgetOutputControls(
                device: device,
                volumeStep: entry.snapshot.volumeStep,
                controlsEnabled: controlsEnabled
            )
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    }

    private var mediumRows: some View {
        let apps = presentation.apps
        return VStack(spacing: 3) {
            ForEach(apps) { app in
                WidgetAppRow(
                    app: app,
                    volumeStep: entry.snapshot.volumeStep,
                    controlsEnabled: controlsEnabled
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

    private var nextDevice: WidgetSnapshot.DeviceSummary? {
        guard let current = presentation.defaultDevice,
              let index = presentation.devices.firstIndex(where: { $0.id == current.id }),
              presentation.devices.count > 1 else { return nil }
        return presentation.devices[(index + 1) % presentation.devices.count]
    }

    // MARK: - systemLarge

    private var largeBody: some View {
        VStack(alignment: .leading, spacing: 7) {
            largeHeader
            largeOutputDashboard
            largeProfiles
            largeQuickActions
            largeApps
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var largeHeader: some View {
        HStack(spacing: 8) {
            AuralisWidgetMark()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("Auralis Control Center")
                    .font(.subheadline.weight(.semibold))
                Text(activeProfileSummary)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(presentation.activeCountText)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(.quaternary, in: Capsule())
            Button(intent: RefreshAppIntent()) {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 22, height: 22)
            }
            .disabled(!controlsEnabled)
            .help("Refresh audio devices and apps")
        }
    }

    private var activeProfileSummary: String {
        guard let device = presentation.defaultDevice else { return statusText }
        return "Device context · \(device.name) · autosaved"
    }

    private var compactConfigurationSummary: String {
        presentation.defaultDevice.map { "Autosaved · \($0.name)" }
            ?? "Device context"
    }

    private var quickProfiles: [WidgetSnapshot.ProfileSummary] {
        presentation.globalProfiles
            .prefix(3)
            .map { $0 }
    }

    @ViewBuilder
    private var largeProfiles: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                sectionLabel("OUTPUT PRESET", systemImage: "square.stack.3d.up.fill")
                Spacer()
                if let local = presentation.localProfiles.first {
                    Label("Autosaved · \(local.name)", systemImage: "checkmark.icloud.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 5) {
                if quickProfiles.isEmpty {
                    Link(destination: AuralisDeepLink.openMixer) {
                        Label("Create presets in Auralis", systemImage: "plus")
                            .font(.caption2.weight(.semibold))
                    }
                } else {
                    ForEach(quickProfiles) { profile in
                        let isActive = presentation.isPresetActive(profile)
                        Button(
                            intent: AssignAudioPresetToCurrentOutputIntent(profileID: profile.id)
                        ) {
                            HStack(spacing: 3) {
                                Image(systemName: isActive
                                    ? "checkmark.circle.fill"
                                    : "square.stack.3d.up")
                                Text(profile.name)
                                    .lineLimit(1)
                            }
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 7)
                            .frame(height: 24)
                            .background(
                                isActive
                                    ? Color.accentColor.opacity(0.16)
                                    : Color.secondary.opacity(0.09),
                                in: Capsule()
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!controlsEnabled)
                        .help("Use \(profile.name) for the current output")
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var largeOutputDashboard: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("MASTER OUTPUT", systemImage: "hifispeaker.2.fill")
            if let device = presentation.defaultDevice {
                HStack(spacing: 9) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(Color.accentColor.opacity(0.14))
                        Image(systemName: device.isMuted ? "speaker.slash.fill" : "hifispeaker.fill")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(device.isMuted ? Color.red : Color.accentColor)
                    }
                    .frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Text(device.isMuted ? "Output muted" : "System output")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Text("\(Int((device.volume * 100).rounded()))")
                        .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                    Text("%")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    WidgetOutputControls(
                        device: device,
                        volumeStep: entry.snapshot.volumeStep,
                        controlsEnabled: controlsEnabled
                    )
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

                HStack(spacing: 5) {
                    ForEach(Array(presentation.devices.prefix(3))) { candidate in
                        Button(intent: SetDefaultOutputDeviceIntent(deviceID: candidate.id)) {
                            HStack(spacing: 3) {
                                Image(systemName: candidate.isDefault ? "checkmark.circle.fill" : "circle")
                                Text(candidate.name)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(candidate.isDefault ? Color.accentColor : Color.primary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 23)
                            .background(
                                candidate.isDefault
                                    ? Color.accentColor.opacity(0.12)
                                    : Color.secondary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!controlsEnabled || candidate.isDefault)
                        .help(candidate.isDefault
                            ? "\(candidate.name) is the current output"
                            : "Use \(candidate.name) as output")
                    }
                }
            } else {
                Text("No output devices")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
        }
    }

    private var largeQuickActions: some View {
        HStack(spacing: 5) {
            Button(intent: SetAllAppsMutedIntent(muted: true)) {
                largeActionLabel("Mute all", systemImage: "speaker.slash.fill")
            }
            .disabled(!controlsEnabled || !presentation.hasActiveApps)
            .buttonStyle(.plain)

            Button(intent: SetAllAppsMutedIntent(muted: false)) {
                largeActionLabel("Unmute", systemImage: "speaker.wave.2.fill")
            }
            .disabled(!controlsEnabled || !presentation.hasActiveApps)
            .buttonStyle(.plain)

            Button(intent: SetAllAppsVolumeIntent(volume: 0.5)) {
                largeActionLabel("All 50%", systemImage: "dial.medium")
            }
            .disabled(!controlsEnabled || !presentation.hasActiveApps)
            .buttonStyle(.plain)

            Link(destination: AuralisDeepLink.openMixer) {
                largeActionLabel("Open", systemImage: "arrow.up.right")
            }
            .buttonStyle(.plain)
        }
    }

    private func largeActionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 9, weight: .semibold))
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .frame(height: 25)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }

    private var largeApps: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                sectionLabel("LIVE APPLICATIONS", systemImage: "waveform")
                Spacer()
                Text("mute · volume · boost")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            ForEach(presentation.apps) { app in
                WidgetAppRow(
                    app: app,
                    volumeStep: entry.snapshot.volumeStep,
                    controlsEnabled: controlsEnabled
                )
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
            }
            if presentation.apps.isEmpty {
                Text("No active audio apps")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
        }
    }

    private func sectionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 9, weight: .bold))
            .tracking(0.7)
            .foregroundStyle(.secondary)
    }
}

private struct WidgetOutputControls: View {
    let device: WidgetSnapshot.DeviceSummary
    let volumeStep: Double
    let controlsEnabled: Bool

    var body: some View {
        HStack(spacing: 3) {
            Button(intent: SetOutputDeviceVolumeIntent(deviceID: device.id, volume: stepped(-1))) {
                Image(systemName: "minus")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18)
            }
            .disabled(!controlsEnabled)
            .accessibilityLabel(WidgetMixerPresentation.volumeLabel(name: device.name, direction: -1))

            Button(intent: SetOutputDeviceMutedIntent(deviceID: device.id, muted: !device.isMuted)) {
                Image(systemName: device.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(device.isMuted ? Color.red : Color.accentColor)
                    .frame(width: 20, height: 18)
            }
            .disabled(!controlsEnabled)
            .accessibilityLabel(WidgetMixerPresentation.muteLabel(name: device.name, isMuted: device.isMuted))

            Button(intent: SetOutputDeviceVolumeIntent(deviceID: device.id, volume: stepped(1))) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18)
            }
            .disabled(!controlsEnabled)
            .accessibilityLabel(WidgetMixerPresentation.volumeLabel(name: device.name, direction: 1))
        }
    }

    private func stepped(_ direction: Double) -> Double {
        min(max(device.volume + direction * volumeStep, 0), 1)
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
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.16))
                AuralisAudioGlyph()
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
