import SwiftUI

/// Desktop mixer layout inspired by FineTune's GPLv3 expandable app rows.
/// https://github.com/ronitsingh10/FineTune
struct MainWindowView: View {
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var store: AudioControlStore
    @State private var selectedAppID: AudioAppIdentity?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 820, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(store.settings.customization.appearance.colorScheme)
        .task { store.refreshIntent() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.16))
                Image(systemName: "waveform.circle.fill").font(.title2).foregroundStyle(Color.accentColor)
            }
            .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text("EQMacRep Mixer").font(.title3.weight(.semibold))
                Text(store.statusMessage).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Label("\(store.displayRows.filter(\.isActive).count) active", systemImage: "speaker.wave.2.fill")
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.quaternary, in: Capsule())
            Button { store.refreshIntent() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).help("Refresh audio apps")
            Button {
                openSettings(); NSApp.activate(ignoringOtherApps: true)
            } label: { Image(systemName: "gearshape") }
                .buttonStyle(.plain).help("Settings")
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
    }

    @ViewBuilder private var content: some View {
        VStack(spacing: 0) {
            if !store.permissionState.allowsProcessTaps {
                PermissionStatusView(store: store, compact: false)
                    .padding(.horizontal, 22)
                    .padding(.top, 18)
                    .padding(.bottom, 8)
            }

            if store.displayRows.isEmpty {
                ContentUnavailableView("No Apps", systemImage: "speaker.slash", description: Text("Refresh or enable inactive apps in Settings."))
            } else {
                mixerRows
            }
        }
    }

    private var mixerRows: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                sectionHeader
                ForEach(store.displayRows) { row in
                    VStack(spacing: 0) {
                        AppRowView(
                            row: row,
                            rowHeight: 54,
                            isSelected: selectedAppID == row.identity,
                            onSelect: { select(row.identity) },
                            onVolume: { store.setVolumeIntent($0, for: row.identity) },
                            onVolumeEditingChanged: { editing in
                                editing ? store.beginVolumeEditing(for: row.identity) : store.endVolumeEditing(for: row.identity)
                            },
                            onMute: { store.setMutedIntent($0, for: row.identity) },
                            onBoost: { store.setBoostIntent($0, for: row.identity) },
                            onPin: { store.pinIntent($0, identity: row.identity) },
                            onIgnore: { store.ignoreIntent(row.identity) },
                            devices: store.devices,
                            onRoute: { store.setRouteIntent($0, for: row.identity) },
                            volumeStep: store.settings.customization.volumeStep.fraction,
                            layout: .desktop
                        )
                        if selectedAppID == row.identity {
                            EQPanelView(
                                row: row,
                                style: .desktop,
                                onClose: { closeEQ(row) },
                                onGain: { band, gain in store.setEQGainIntent(gain, band: band, for: row.identity) },
                                onGainEditingChanged: { band, editing in
                                    editing ? store.beginEQEditing(band: band, for: row.identity) : store.endEQEditing(band: band, for: row.identity)
                                },
                                onReset: { store.resetEQIntent(for: row.identity) }
                            )
                            .padding(.horizontal, 12).padding(.bottom, 10)
                            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                        }
                    }
                    .background(selectedAppID == row.identity ? Color.accentColor.opacity(0.035) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(18)
        }
    }

    private var sectionHeader: some View {
        HStack {
            Text("APPLICATIONS").font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(.secondary)
            Spacer()
            Text("Volume   Boost   Output   EQ").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12).padding(.bottom, 6)
    }

    private var footer: some View {
        HStack {
            Text("Click an EQ button to expand its 10-band equalizer")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("Scroll over sliders for precise adjustment")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 22).padding(.vertical, 10)
    }

    private func select(_ identity: AudioAppIdentity) {
        withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
            if let selectedAppID, selectedAppID != identity { store.endContinuousEdits(for: selectedAppID) }
            selectedAppID = selectedAppID == identity ? nil : identity
        }
    }

    private func closeEQ(_ row: DisplayableAppRow) {
        store.endContinuousEdits(for: row.identity)
        withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) { selectedAppID = nil }
    }
}
