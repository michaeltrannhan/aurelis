import SwiftUI

/// Top-level section that lists every available output device with its own
/// hardware volume slider and mute toggle. Mirrors FineTune's device-level
/// volume sliders, shown above per-app mixers in both the desktop window and
/// the menu-bar popup. Each row binds to the per-device volume state in the
/// store so multi-output setups can adjust each selected source independently.
struct OutputVolumeSection: View {
    @ObservedObject var store: AudioControlStore
    var layout: Layout = .desktop

    enum Layout {
        case desktop
        case compact

        var sliderWidth: CGFloat { self == .desktop ? 180 : 130 }
        var iconSize: CGFloat { self == .desktop ? 14 : 12 }
        var rowHeight: CGFloat { self == .desktop ? 38 : 32 }
        var horizontalPadding: CGFloat { self == .desktop ? 12 : 8 }
        var verticalPadding: CGFloat { self == .desktop ? 6 : 4 }
        var headerPadding: CGFloat { self == .desktop ? 10 : 6 }
    }

    private var volumeStep: Double { store.settings.customization.volumeStep.fraction }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            ForEach(store.devices) { device in
                deviceRow(for: device)
            }
        }
        .padding(.horizontal, layout.horizontalPadding)
        .padding(.vertical, layout.verticalPadding)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Output device volumes")
    }

    private var header: some View {
        HStack {
            Text("OUTPUT DEVICES")
                .font(.caption.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(store.devices.count)")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.bottom, layout.headerPadding)
    }

    private func deviceRow(for device: AudioDeviceSnapshot) -> some View {
        let state = store.deviceVolumeStates[device.id] ?? OutputVolumeState(deviceName: device.name)

        return HStack(spacing: 10) {
            Button {
                store.toggleDeviceMuteIntent(for: device.id)
            } label: {
                Image(systemName: state.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: layout.iconSize))
                    .foregroundStyle(state.isMuted ? Color.red : Color.accentColor)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(state.isMuted ? "Unmute \(device.name)" : "Mute \(device.name)")
            .accessibilityLabel(state.isMuted ? "Unmute \(device.name)" : "Mute \(device.name)")

            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .font(layout == .desktop ? .callout.weight(.medium) : .caption.weight(.medium))
                    .lineLimit(1)
                if device.isDefault {
                    Text("Default")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(minWidth: layout == .desktop ? 120 : 80, maxWidth: .infinity, alignment: .leading)

            Slider(value: Binding(
                get: { state.volume },
                set: { store.setDeviceVolumeIntent($0, for: device.id) }
            ), in: 0...1)
            .frame(width: layout.sliderWidth)
            .scrollWheelStep(step: volumeStep) { deltaY in
                let next = ScrollWheelStepModel.nextValue(current: state.volume, deltaY: deltaY, step: volumeStep)
                store.setDeviceVolumeIntent(next, for: device.id)
            }

            Text("\(Int((state.volume * 100).rounded()))%")
                .font(.callout.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .frame(minHeight: layout.rowHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(device.name) volume")
        .accessibilityValue("\(Int((state.volume * 100).rounded())) percent\(state.isMuted ? ", muted" : "")")
    }
}
