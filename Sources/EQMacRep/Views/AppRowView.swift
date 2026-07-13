import SwiftUI
import AppKit

// UI structure adapted from FineTune's GPLv3 AppRow/AppRowControls.
// https://github.com/ronitsingh10/FineTune

struct AppRowView: View {
    enum Layout {
        case desktop
        case compact
    }

    let row: DisplayableAppRow
    let rowHeight: Double
    let isSelected: Bool
    let onSelect: () -> Void
    let onVolume: (Double) -> Void
    var onVolumeEditingChanged: (Bool) -> Void = { _ in }
    let onMute: (Bool) -> Void
    let onBoost: (BoostLevel) -> Void
    let onPin: (Bool) -> Void
    let onIgnore: () -> Void
    var devices: [AudioDeviceSnapshot] = []
    var onRoute: (DeviceRoute) -> Void = { _ in }
    var volumeStep: Double = 0.05
    var layout: Layout = .desktop

    @State private var isOutputPickerPresented = false

    private var volumePercentage: Int {
        Int((row.settings.volume * 100).rounded())
    }

    private var activityLabel: String {
        if row.settings.isMuted { return "Muted" }
        return row.isActive ? "Active" : "Inactive"
    }

    private var activityColor: Color {
        if row.settings.isMuted { return .red }
        return row.isActive ? .green : .secondary
    }

    private var routeSummary: MultiOutputRouteSummary {
        MultiOutputRoutePickerModel.summary(for: row.settings.route, devices: devices)
    }

    private var routeDetailLabel: String {
        routeSummary.detail
    }

    /// The full route label is useful in the desktop mixer, but the menu-bar row
    /// should name the actual destination without repeating "Follow Default".
    private var compactRouteLabel: String {
        routeSummary.title
    }

    var body: some View {
        if layout == .compact {
            compactBody
        } else {
            desktopBody
        }
    }

    private var desktopBody: some View {
        HStack(spacing: 12) {
            AudioLevelMeter(level: row.level, isMuted: row.settings.isMuted)
            appIcon.frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayName).font(.body.weight(.medium)).lineLimit(1)
                Text(routeDetailLabel)
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)

            Button { onMute(!row.settings.isMuted) } label: {
                Image(systemName: row.settings.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(row.settings.isMuted ? Color.red : Color.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain).help(row.settings.isMuted ? "Unmute" : "Mute")

            Slider(value: Binding(get: { row.settings.volume }, set: { onVolume($0) }), in: 0...1, onEditingChanged: onVolumeEditingChanged)
                .frame(width: 190)
                .scrollWheelStep(step: volumeStep) { deltaY in
                    onVolume(ScrollWheelStepModel.nextValue(current: row.settings.volume, deltaY: deltaY, step: volumeStep))
                }
            Text("\(Int((row.settings.volume * 100).rounded()))%")
                .font(.callout.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)

            boostMenu(compact: false)

            outputPickerButton()

            Button(action: onSelect) {
                Image(systemName: isSelected ? "xmark" : "slider.vertical.3")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain).help(isSelected ? "Close Equalizer" : "Equalizer")
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .frame(minHeight: rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor).opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .contextMenu {
            Button(row.isPinned ? "Unpin" : "Pin") { onPin(!row.isPinned) }
            Button("Ignore App", role: .destructive, action: onIgnore)
        }
    }

    @ViewBuilder private var appIcon: some View {
        if let bundleID = row.identity.rawValue.hasPrefix("name:") ? nil : row.identity.rawValue,
           let icon = AppIconProvider.icon(forBundleID: bundleID) {
            Image(nsImage: icon)
                .resizable().aspectRatio(contentMode: .fit)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.16))
                Image(systemName: "waveform").foregroundStyle(Color.accentColor)
            }
        }
    }

    private func outputPickerButton(compact: Bool = false) -> some View {
        Button {
            isOutputPickerPresented.toggle()
        } label: {
            if compact {
                HStack(spacing: 3) {
                    Image(systemName: "headphones")
                    Text(compactRouteLabel)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if routeSummary.missingCount > 0 {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            } else {
                Image(systemName: "headphones")
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .overlay(alignment: .topTrailing) {
                        HStack(spacing: 1) {
                            if routeSummary.isMultiOutput {
                                Text("\(routeSummary.selectedCount)")
                                    .font(.system(size: 8, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.white)
                                    .padding(.horizontal, 4)
                                    .frame(minHeight: 12)
                                    .background(Color.accentColor, in: Capsule())
                            }
                            if routeSummary.missingCount > 0 {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.orange)
                            }
                        }
                        .offset(x: 6, y: -3)
                        .accessibilityHidden(true)
                    }
            }
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: !compact, vertical: true)
        .accessibilityLabel("Output route")
        .accessibilityValue(routeSummary.accessibilityValue)
        .help("Output: \(routeDetailLabel)")
        .popover(isPresented: $isOutputPickerPresented, arrowEdge: .bottom) {
            MultiOutputRoutePicker(
                route: row.settings.route,
                devices: devices,
                onApply: onRoute,
                onDismiss: { isOutputPickerPresented = false }
            )
        }
    }

    private func boostMenu(compact: Bool) -> some View {
        Menu {
            ForEach(BoostLevel.allCases) { boost in
                Button {
                    onBoost(boost)
                } label: {
                    if boost == row.settings.boost {
                        Label(boostOptionLabel(boost), systemImage: "checkmark")
                    } else {
                        Text(boostOptionLabel(boost))
                    }
                }
            }
        } label: {
            HStack(spacing: compact ? 3 : 4) {
                Text(compact ? boostDisplayLabel(row.settings.boost) : boostButtonLabel)
                    .font(.caption.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(row.settings.boost == .x1 ? Color.primary : Color.accentColor)
            .padding(.horizontal, compact ? 6 : 8)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(row.settings.boost == .x1 ? Color.secondary.opacity(0.09) : Color.accentColor.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(row.settings.boost == .x1 ? Color.secondary.opacity(0.16) : Color.accentColor.opacity(0.28))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Boost")
        .accessibilityValue(boostAccessibilityValue)
        .help(row.settings.boost == .x1 ? "Boost is off" : "Boost: \(boostDisplayLabel(row.settings.boost))")
    }

    private var boostButtonLabel: String {
        row.settings.boost == .x1 ? "Boost Off" : "Boost \(boostDisplayLabel(row.settings.boost))"
    }

    private var boostAccessibilityValue: String {
        row.settings.boost == .x1 ? "Off, normal gain" : "\(Int(row.settings.boost.rawValue)) times"
    }

    private func boostOptionLabel(_ boost: BoostLevel) -> String {
        boost == .x1 ? "Off (1×)" : boostDisplayLabel(boost)
    }

    private func boostDisplayLabel(_ boost: BoostLevel) -> String {
        "\(Int(boost.rawValue))×"
    }

    private var compactBody: some View {
        VStack(spacing: 2) {
            HStack(spacing: 8) {
                appIcon
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(row.displayName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if row.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityLabel("Pinned")
                        }
                    }

                    HStack(spacing: 4) {
                        Circle()
                            .fill(activityColor)
                            .frame(width: 5, height: 5)
                            .accessibilityHidden(true)
                        Text(activityLabel)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(activityColor)
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                        outputPickerButton(compact: true)
                            .layoutPriority(-1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 4)

                Button {
                    onMute(!row.settings.isMuted)
                } label: {
                    Image(systemName: row.settings.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(row.settings.isMuted ? Color.red : Color.secondary)
                        .frame(width: 28, height: 28)
                        .background(
                            row.settings.isMuted ? Color.red.opacity(0.10) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(row.settings.isMuted ? "Unmute \(row.displayName)" : "Mute \(row.displayName)")
                .help(row.settings.isMuted ? "Unmute" : "Mute")

                Button(action: onSelect) {
                    Image(systemName: "slider.vertical.3")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .frame(width: 28, height: 28)
                        .background(
                            isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isSelected ? "Hide equalizer for \(row.displayName)" : "Show equalizer for \(row.displayName)")
                .help(isSelected ? "Hide EQ" : "Show EQ")
            }

            HStack(spacing: 7) {
                CompactAudioLevelMeter(level: row.level, isMuted: row.settings.isMuted)

                Slider(value: Binding(
                    get: { row.settings.volume },
                    set: { onVolume($0) }
                ), in: 0...1, onEditingChanged: onVolumeEditingChanged)
                .controlSize(.mini)
                .scrollWheelStep(step: volumeStep) { deltaY in
                    onVolume(ScrollWheelStepModel.nextValue(current: row.settings.volume, deltaY: deltaY, step: volumeStep))
                }
                .accessibilityLabel("Volume for \(row.displayName)")

                Text("\(volumePercentage)%")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)

                boostMenu(compact: true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(minHeight: rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(isSelected ? Color.accentColor.opacity(0.13) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(isSelected ? Color.accentColor.opacity(0.45) : Color.clear)
        )
        .contextMenu {
            Picker("Boost", selection: Binding(get: { row.settings.boost }, set: { onBoost($0) })) {
                ForEach(BoostLevel.allCases) { Text(boostOptionLabel($0)).tag($0) }
            }
            if !devices.isEmpty {
                Menu("Output") {
                    Button("Follow Default") { onRoute(.followDefault) }
                    ForEach(devices) { device in
                        Button(device.name) { onRoute(.selectedDevice(device.id)) }
                    }
                }
            }
            Divider()
            Button(row.isPinned ? "Unpin" : "Pin") { onPin(!row.isPinned) }
            Button("Ignore App", role: .destructive, action: onIgnore)
        }
    }
}

/// Rows update frequently as live levels arrive, so avoid asking Launch Services
/// to resolve and load the same icon on every SwiftUI body evaluation.
@MainActor
private enum AppIconProvider {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(forBundleID bundleID: String) -> NSImage? {
        if let cached = cache.object(forKey: bundleID as NSString) {
            return cached
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(icon, forKey: bundleID as NSString)
        return icon
    }
}

/// Horizontal live-level capsule sized for the menu-bar volume line. The old
/// four-point-wide linear ProgressView rendered as a crushed horizontal track.
private struct CompactAudioLevelMeter: View {
    let level: Double
    let isMuted: Bool

    private var normalizedLevel: Double {
        min(max(level.isFinite ? level : 0, 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(isMuted ? Color.secondary : Color.green)
                    .frame(width: proxy.size.width * normalizedLevel)
            }
        }
        .frame(width: 24, height: 5)
        .animation(.linear(duration: 0.08), value: normalizedLevel)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio level")
        .accessibilityValue(isMuted ? "Muted" : "\(Int((normalizedLevel * 100).rounded())) percent")
    }
}

private struct AudioLevelMeter: View {
    let level: Double
    let isMuted: Bool
    private let thresholds = [0.01, 0.03, 0.10, 0.20, 0.32, 0.50, 0.70, 0.90]

    var body: some View {
        VStack(spacing: 1) {
            ForEach(thresholds.indices.reversed(), id: \.self) { index in
                Capsule().fill(color(index).opacity(level >= thresholds[index] ? 1 : 0.18))
            }
        }
        .frame(width: 10, height: 34)
        .animation(.linear(duration: 0.08), value: level)
    }

    private func color(_ index: Int) -> Color {
        if isMuted { return .secondary }
        if index >= 7 { return .red }
        if index >= 5 { return .yellow }
        return .green
    }
}
