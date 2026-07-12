import SwiftUI

struct AppRowView: View {
    let row: DisplayableAppRow
    let rowHeight: Double
    let isSelected: Bool
    let onSelect: () -> Void
    let onVolume: (Double) -> Void
    let onMute: (Bool) -> Void
    let onBoost: (BoostLevel) -> Void
    let onPin: (Bool) -> Void
    let onIgnore: () -> Void
    var devices: [AudioDeviceSnapshot] = []
    var onRoute: (DeviceRoute) -> Void = { _ in }
    var volumeStep: Double = 0.05

    /// The selected device UID when it is no longer in the available list, so the
    /// picker can keep showing a "Missing Device" row for it.
    private var missingSelectedID: String? {
        guard case let .selectedDevice(id) = row.settings.route,
              !devices.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                HStack(spacing: 8) {
                        Image(systemName: row.isActive ? "speaker.wave.2.fill" : "speaker")
                            .foregroundStyle(row.isActive ? .blue : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.displayName)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(row.isActive ? "Active process" : "Inactive process")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                }

                Spacer()

                Button(action: onSelect) {
                    Label(isSelected ? "Hide EQ" : "EQ", systemImage: "slider.vertical.3")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help(isSelected ? "Hide this app's EQ bands" : "Edit this app's EQ bands")

                Picker("Boost", selection: Binding(
                    get: { row.settings.boost },
                    set: { newBoost in onBoost(newBoost) }
                )) {
                    ForEach(BoostLevel.allCases) { boost in
                        Text(boost.label).tag(boost)
                    }
                }
                .labelsHidden()
                .frame(width: 72)

                Toggle("Mute", isOn: Binding(
                    get: { row.settings.isMuted },
                    set: { muted in onMute(muted) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)

                Button {
                    onPin(!row.isPinned)
                } label: {
                    Image(systemName: row.isPinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.borderless)
                .help(row.isPinned ? "Unpin" : "Pin")

                Button(role: .destructive, action: onIgnore) {
                    Image(systemName: "eye.slash")
                }
                .buttonStyle(.borderless)
                .help("Ignore app")
            }

            HStack(spacing: 10) {
                Text("Volume")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)
                Slider(value: Binding(
                    get: { row.settings.volume },
                    set: { volume in onVolume(volume) }
                ), in: 0...1)
                .scrollWheelStep(step: volumeStep) { deltaY in
                    onVolume(ScrollWheelStepModel.nextValue(current: row.settings.volume, deltaY: deltaY, step: volumeStep))
                }
                Text("\(Int(row.settings.volume * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 44, alignment: .trailing)
            }
            if !devices.isEmpty {
                HStack(spacing: 10) {
                    Text("Output")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .leading)
                    Picker("Output", selection: Binding(
                        get: { row.settings.route },
                        set: { route in onRoute(route) }
                    )) {
                        Text(DeviceRoute.followDefault.label(devices: devices))
                            .tag(DeviceRoute.followDefault)
                        ForEach(devices) { device in
                            Text(device.name).tag(DeviceRoute.selectedDevice(device.id))
                        }
                        // Preserve a stored-but-missing selection so it stays visible.
                        if let missingSelectedID {
                            Text("Missing Device").tag(DeviceRoute.selectedDevice(missingSelectedID))
                        }
                    }
                    .labelsHidden()
                }
            }
            ProgressView(value: row.level)
                .controlSize(.small)
        }
        .padding(10)
        .frame(minHeight: rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
        )
    }
}
