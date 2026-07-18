import SwiftUI

struct OutputControlPresentation: Equatable {
    let showsVolume: Bool
    let enablesVolume: Bool
    let showsMute: Bool
    let enablesMute: Bool

    init(capabilities: OutputControlCapabilities) {
        showsVolume = capabilities.canReadVolume
        enablesVolume = capabilities.canReadVolume && capabilities.canSetVolume
        showsMute = capabilities.canReadMute
        enablesMute = capabilities.canReadMute && capabilities.canSetMute
    }

    var hasAnyReadableControl: Bool { showsVolume || showsMute }
}

/// Top-level section that lists every available output device with its own
/// hardware volume slider and mute toggle. Mirrors FineTune's device-level
/// volume sliders, shown above per-app mixers in both the desktop window and
/// the menu-bar popup. Each row binds to the per-device volume state in the
/// store so multi-output setups can adjust each selected source independently.
/// The slider is flexible (no fixed width) so the section adapts to the parent
/// container — popup or desktop — without overflowing.
struct OutputVolumeSection: View {
    @ObservedObject var store: AudioControlStore
    var layout: Layout = .desktop

    enum Layout {
        case desktop
        case compact

        var iconSize: CGFloat { self == .desktop ? 14 : 11 }
        var rowHeight: CGFloat { self == .desktop ? 36 : 28 }
        var rowSpacing: CGFloat { self == .desktop ? 6 : 3 }
        var muteSize: CGFloat { self == .desktop ? 22 : 20 }
        var percentageWidth: CGFloat { self == .desktop ? 40 : 32 }
        var labelFont: Font { self == .desktop ? .callout.weight(.medium) : .caption2.weight(.medium) }
        var percentageFont: Font { self == .desktop ? .callout.monospacedDigit().weight(.medium) : .caption2.monospacedDigit().weight(.medium) }
        var sliderControlSize: ControlSize { self == .desktop ? .regular : .mini }
    }

    private var volumeStep: Double { store.settings.customization.volumeStep.fraction }

    var body: some View {
        VStack(alignment: .leading, spacing: layout.rowSpacing) {
            ForEach(store.devices) { device in
                deviceRow(for: device)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Output device volumes")
    }

    private func deviceRow(for device: AudioDeviceSnapshot) -> some View {
        let state = store.deviceVolumeStates[device.id] ?? OutputVolumeState(deviceName: device.name)
        let presentation = OutputControlPresentation(capabilities: state.capabilities)

        return HStack(spacing: layout == .desktop ? 10 : 6) {
            if presentation.showsMute {
                Button {
                    store.toggleDeviceMuteIntent(for: device.id)
                } label: {
                    Image(systemName: state.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: layout.iconSize))
                        .foregroundStyle(state.isMuted ? Color.red : Color.accentColor)
                        .frame(width: layout.muteSize, height: layout.muteSize)
                }
                .buttonStyle(.plain)
                .disabled(!presentation.enablesMute)
                .help(muteHelp(device: device, state: state, enabled: presentation.enablesMute))
                .accessibilityLabel(state.isMuted ? "Unmute \(device.name)" : "Mute \(device.name)")
                .accessibilityHint(presentation.enablesMute ? "" : "Mute is read-only for this device")
            }

            Text(device.name)
                .font(layout.labelFont)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: layout == .desktop ? 100 : 60, maxWidth: layout == .desktop ? 140 : 90, alignment: .leading)

            if presentation.showsVolume {
                volumeControl(
                    device: device,
                    state: state,
                    enabled: presentation.enablesVolume
                )

                Text("\(Int((state.volume * 100).rounded()))%")
                    .font(layout.percentageFont)
                    .foregroundStyle(.secondary)
                    .frame(width: layout.percentageWidth, alignment: .trailing)
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                Text(presentation.hasAnyReadableControl ? "Volume unavailable" : "Controls unavailable")
                    .font(layout.percentageFont)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(minHeight: layout.rowHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(device.name) output controls")
        .accessibilityValue(accessibilityValue(state: state, presentation: presentation))
    }

    @ViewBuilder
    private func volumeControl(
        device: AudioDeviceSnapshot,
        state: OutputVolumeState,
        enabled: Bool
    ) -> some View {
        let slider = Slider(value: Binding(
            get: { state.volume },
            set: { store.setDeviceVolumeIntent($0, for: device.id) }
        ), in: 0...1)
        .controlSize(layout.sliderControlSize)
        .frame(maxWidth: .infinity)
        .disabled(!enabled)
        .help(enabled ? "Adjust \(device.name) volume" : "Volume is read-only for this device")

        if enabled {
            slider.scrollWheelSteps { logicalSteps in
                let next = ScrollWheelStepModel.nextValue(
                    current: state.volume,
                    logicalSteps: logicalSteps,
                    step: volumeStep
                )
                store.setDeviceVolumeIntent(next, for: device.id)
            }
        } else {
            slider
        }
    }

    private func muteHelp(device: AudioDeviceSnapshot, state: OutputVolumeState, enabled: Bool) -> String {
        guard enabled else { return "Mute is read-only for \(device.name)" }
        return state.isMuted ? "Unmute \(device.name)" : "Mute \(device.name)"
    }

    private func accessibilityValue(
        state: OutputVolumeState,
        presentation: OutputControlPresentation
    ) -> String {
        var values: [String] = []
        if presentation.showsVolume {
            values.append("\(Int((state.volume * 100).rounded())) percent")
        }
        if presentation.showsMute {
            values.append(state.isMuted ? "muted" : "not muted")
        }
        return values.isEmpty ? "Controls unavailable" : values.joined(separator: ", ")
    }
}
