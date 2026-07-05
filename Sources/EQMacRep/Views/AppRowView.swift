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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button(action: onSelect) {
                    HStack {
                        Image(systemName: row.isActive ? "speaker.wave.2.fill" : "speaker")
                            .foregroundStyle(row.isActive ? .blue : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.displayName)
                                .font(.subheadline.weight(.semibold))
                            Text(row.isActive ? "Active" : "Inactive")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)

                Spacer()

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

            HStack {
                Slider(value: Binding(
                    get: { row.settings.volume },
                    set: { volume in onVolume(volume) }
                ), in: 0...1)
                Text("\(Int(row.settings.volume * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 44, alignment: .trailing)
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
    }
}
