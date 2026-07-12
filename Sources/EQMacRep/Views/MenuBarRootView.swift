import SwiftUI

struct MenuBarRootView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var store: AudioControlStore
    @State private var selectedAppID: AudioAppIdentity?
    @FocusState private var popupFocused: Bool
    private let nav = PopupKeyboardNavModel()

    private var dimensions: PopupDimensions {
        store.settings.customization.popupDensity.dimensions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !store.permissionState.allowsProcessTaps {
                permissionBanner
            }

            if store.displayRows.isEmpty {
                ContentUnavailableView("No Apps", systemImage: "speaker.slash", description: Text("Refresh or enable inactive apps in Settings."))
                    .frame(height: 160)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(store.displayRows) { row in
                            AppRowView(
                                row: row,
                                rowHeight: dimensions.rowHeight,
                                isSelected: selectedAppID == row.identity,
                                onSelect: { select(row.identity) },
                                onVolume: { try? store.setVolume($0, for: row.identity) },
                                onMute: { try? store.setMuted($0, for: row.identity) },
                                onBoost: { try? store.setBoost($0, for: row.identity) },
                                onPin: { pinned in
                                    if pinned {
                                        try? store.pin(row.identity)
                                    } else {
                                        try? store.unpin(row.identity)
                                    }
                                },
                                onIgnore: { try? store.ignore(row.identity) },
                                devices: store.devices,
                                onRoute: { try? store.setRoute($0, for: row.identity) },
                                volumeStep: store.settings.customization.volumeStep.fraction
                            )
                        }
                    }
                }
                .frame(maxHeight: dimensions.maxContentHeight)
            }

            if let selectedAppID,
               let row = store.displayRows.first(where: { $0.identity == selectedAppID }) {
                Divider()
                EQPanelView(row: row, onClose: { self.selectedAppID = nil }) { band, gain in
                    try? store.setEQGain(gain, band: band, for: row.identity)
                }
            } else if !store.displayRows.isEmpty {
                eqHint
            }
        }
        .padding(dimensions.contentPadding)
        .frame(width: dimensions.width)
        .preferredColorScheme(store.settings.customization.appearance.colorScheme)
        .focusable()
        .focused($popupFocused)
        .onAppear {
            nav.sync(apps: store.displayRows.map(\.identity), isEditing: false)
            popupFocused = true
        }
        .onChange(of: store.displayRows) { _, rows in
            nav.sync(apps: rows.map(\.identity), isEditing: false)
        }
        .onKeyPress(.downArrow) {
            if let next = nav.next(after: selectedAppID) { selectedAppID = next }
            return .handled
        }
        .onKeyPress(.upArrow) {
            if let previous = nav.previous(before: selectedAppID) { selectedAppID = previous }
            return .handled
        }
        .onKeyPress(.space) {
            toggleMuteForSelection()
            return .handled
        }
        .onKeyPress(.return) {
            toggleMuteForSelection()
            return .handled
        }
        .onKeyPress(.escape) {
            selectedAppID = nil
            return .handled
        }
    }

    private func toggleMuteForSelection() {
        guard let selectedAppID,
              let row = store.displayRows.first(where: { $0.identity == selectedAppID }) else { return }
        try? store.setMuted(!row.settings.isMuted, for: selectedAppID)
    }

    private func select(_ identity: AudioAppIdentity) {
        selectedAppID = selectedAppID == identity ? nil : identity
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("EQMacRep")
                    .font(.headline)
                Text(store.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                try? store.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh audio apps")
            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "macwindow")
            }
            .buttonStyle(.borderless)
            .help("Open main window")
            Button {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(store.permissionState.summary, systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
            Text("Grant Screen & System Audio Recording to control real app audio. Discovery still works without it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Request Access") {
                    store.requestAudioCapturePermission()
                }
                Button("Open Settings") {
                    store.openAudioCapturePrivacySettings()
                }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var eqHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.vertical.3")
                .foregroundStyle(.secondary)
            Text("Choose EQ on an app row to edit its 10 bands.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
        )
    }
}
