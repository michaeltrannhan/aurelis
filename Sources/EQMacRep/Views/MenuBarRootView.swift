import SwiftUI

struct MenuBarRootView: View {
    @ObservedObject var store: AudioControlStore
    @State private var selectedAppID: AudioAppIdentity?

    private var dimensions: PopupDimensions {
        store.settings.customization.popupDensity.dimensions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

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
                                onSelect: { selectedAppID = row.identity },
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
                }
                .frame(maxHeight: 360)
            }

            if let selectedAppID,
               let row = store.displayRows.first(where: { $0.identity == selectedAppID }) {
                Divider()
                EQPanelView(row: row) { band, gain in
                    try? store.setEQGain(gain, band: band, for: row.identity)
                }
            }
        }
        .padding(dimensions.contentPadding)
        .frame(width: dimensions.width)
        .preferredColorScheme(store.settings.customization.appearance.colorScheme)
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
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
    }
}

private extension AppAppearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
