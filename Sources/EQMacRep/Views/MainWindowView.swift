import SwiftUI

struct MainWindowView: View {
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var store: AudioControlStore
    @State private var selectedAppID: AudioAppIdentity?

    private var selectedRow: DisplayableAppRow? {
        guard let selectedAppID else { return nil }
        return store.displayRows.first { $0.identity == selectedAppID }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationTitle("EQMacRep")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    try? store.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }

                Button {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .preferredColorScheme(store.settings.customization.appearance.colorScheme)
        .task {
            try? store.refresh()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusHeader

            if store.displayRows.isEmpty {
                ContentUnavailableView("No Apps", systemImage: "speaker.slash", description: Text("Refresh or enable inactive apps in Settings."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(store.displayRows) { row in
                            AppRowView(
                                row: row,
                                rowHeight: 74,
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
                                onIgnore: { try? store.ignore(row.identity) }
                            )
                        }
                    }
                    .padding(.trailing, 4)
                }
            }
        }
        .padding(16)
        .navigationSplitViewColumnWidth(min: 380, ideal: 430, max: 520)
    }

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Processes", systemImage: "speaker.wave.2")
                    .font(.headline)
                Spacer()
                Text("\(store.displayRows.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(store.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let row = selectedRow {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    selectedProcessHeader(row)
                    EQPanelView(row: row, onClose: { selectedAppID = nil }) { band, gain in
                        try? store.setEQGain(gain, band: band, for: row.identity)
                    }
                }
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
            }
        } else {
            ContentUnavailableView(
                "Select a Process",
                systemImage: "slider.vertical.3",
                description: Text("Choose EQ on a process row to edit its 10-band equalizer in this larger window.")
            )
        }
    }

    private func selectedProcessHeader(_ row: DisplayableAppRow) -> some View {
        HStack(spacing: 12) {
            Image(systemName: row.isActive ? "speaker.wave.2.fill" : "speaker")
                .font(.title2)
                .foregroundStyle(row.isActive ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.displayName)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                Text(row.isActive ? "Active process" : "Inactive process")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if row.isPinned {
                Label("Pinned", systemImage: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func select(_ identity: AudioAppIdentity) {
        selectedAppID = identity
    }
}
