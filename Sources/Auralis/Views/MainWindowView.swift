import SwiftUI

/// Desktop mixer layout inspired by FineTune's GPLv3 expandable app rows.
/// https://github.com/ronitsingh10/FineTune
struct MainWindowView: View {
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var store: AudioControlStore
    @State private var selectedAppID: AudioAppIdentity?
    @State private var searchText = ""
    @State private var scope: AppScope = .playing
    @State private var isNarrowLayout = false
    @State private var showsInspector = false

    private enum AppScope: String, CaseIterable, Identifiable {
        case playing = "Playing"
        case pinned = "Pinned"
        case all = "All"
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(AuroraConsoleDesign.workbench)
        .preferredColorScheme(store.settings.customization.appearance.colorScheme)
        .sheet(isPresented: $showsInspector, onDismiss: dismissInspector) {
            if let row = selectedRow {
                NavigationStack {
                    EQPanelView(store: store, row: row, style: .desktop, onClose: dismissInspector)
                        .padding(20)
                        .navigationTitle(row.displayName)
                }
                .frame(minWidth: 520, minHeight: 430)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.16))
                Image(systemName: "waveform.circle.fill").font(.title2).foregroundStyle(Color.accentColor)
            }
            .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text("AURALIS / MIX")
                    .font(AuroraConsoleDesign.workspaceTitle())
                    .tracking(0.7)
                Text(currentOutputLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Label("\(store.displayRows.filter(\.isActive).count) playing", systemImage: "speaker.wave.2.fill")
                .font(AuroraConsoleDesign.data(11)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.quaternary, in: Capsule())
            ProfileMenuButton(store: store)
                .frame(width: 205)
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
        GeometryReader { proxy in
            let narrow = proxy.size.width < 960
            VStack(spacing: 0) {
            if !store.permissionState.allowsProcessTaps {
                PermissionStatusView(store: store, compact: false)
                    .padding(.horizontal, 22)
                    .padding(.top, 18)
                    .padding(.bottom, 8)
            }

            let visibleIssues = AudioIssuePresentationModel.visibleIssues(
                store.issues,
                permissionState: store.permissionState,
                hidesAudioPermissionIssue: true
            )
            if !visibleIssues.isEmpty {
                AudioIssueListView(store: store, issues: visibleIssues)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 8)
            }

                mixerRows
            }
            .onAppear { isNarrowLayout = narrow }
            .onChange(of: narrow) { _, value in
                isNarrowLayout = value
                if !value { showsInspector = false }
            }
        }
    }

    private var mixerRows: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                outputDeck
                AuroraSignalPath(
                    outputName: store.currentOutput?.name ?? "System Output",
                    volume: currentOutputVolume,
                    isMuted: currentOutputMuted
                )
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
                appToolbar
                if filteredRows.isEmpty {
                    emptyState
                } else {
                    sectionHeader
                    ForEach(filteredRows) { row in
                        desktopRow(row)
                    }
                }
            }
            .padding(18)
        }
    }

    @ViewBuilder
    private func desktopRow(_ row: DisplayableAppRow) -> some View {
        VStack(spacing: 0) {
            ConnectedAppRowView(
                store: store,
                row: row,
                rowHeight: 54,
                isSelected: selectedAppID == row.identity,
                onSelect: { select(row.identity) },
                layout: .desktop
            )
            if selectedAppID == row.identity && !isNarrowLayout {
                EQPanelView(
                    store: store,
                    row: row,
                    style: .desktop,
                    onClose: { closeEQ(row) }
                )
                .padding(.horizontal, 12).padding(.bottom, 10)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .background(
            selectedAppID == row.identity ? Color.accentColor.opacity(0.035) : Color.clear,
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    private var sectionHeader: some View {
        HStack {
            Text(scope.rawValue.uppercased())
                .font(AuroraConsoleDesign.data(11, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            Spacer()
            Text("VOLUME   BOOST   OUTPUT   INSPECT")
                .font(AuroraConsoleDesign.data(10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12).padding(.bottom, 6)
    }

    private var outputDeck: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(store.devices) { device in
                    Button {
                        store.setDefaultOutputDeviceIntent(device.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(device.isDefault ? "CURRENT OUTPUT" : "OUTPUT", systemImage: device.isDefault ? "checkmark.circle.fill" : "hifispeaker")
                                .font(AuroraConsoleDesign.data(9, weight: .bold))
                                .foregroundStyle(device.isDefault ? AuroraConsoleDesign.signalCyan : .secondary)
                            Text(device.name)
                                .font(AuroraConsoleDesign.workspaceTitle(16))
                                .lineLimit(1)
                        }
                        .padding(12)
                        .frame(width: 220, alignment: .leading)
                        .background(device.isDefault ? AuroraConsoleDesign.nightDeck : Color.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(device.isDefault ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                    .disabled(device.isDefault)
                    .accessibilityAddTraits(device.isDefault ? .isSelected : [])
                    .accessibilityLabel(device.isDefault ? "Current output, \(device.name)" : "Use \(device.name) as current output")
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
    }

    private var appToolbar: some View {
        HStack(spacing: 12) {
            Picker("App scope", selection: $scope) {
                ForEach(AppScope.allCases) { scope in Text(scope.rawValue).tag(scope) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)
            TextField("Search apps", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .accessibilityLabel("Search app channels")
            Spacer()
            Text("\(filteredRows.count) CHANNELS")
                .font(AuroraConsoleDesign.data(10, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 14) {
            ContentUnavailableView(
                emptyStateTitle,
                systemImage: emptyStateSymbol,
                description: Text(emptyStateDescription)
            )
            HStack {
                Button("Refresh", action: store.refreshIntent)
                if scope != .all { Button("Show inactive apps") { scope = .all } }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 240)
    }

    private var footer: some View {
        HStack {
            Text(isNarrowLayout ? "Inspectors open in a dedicated sheet" : "Select a channel to open its inspector")
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
            showsInspector = isNarrowLayout && selectedAppID != nil
        }
    }

    private func closeEQ(_ row: DisplayableAppRow) {
        store.endContinuousEdits(for: row.identity)
        withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) { selectedAppID = nil }
    }

    private var selectedRow: DisplayableAppRow? {
        selectedAppID.flatMap { identity in store.displayRows.first { $0.identity == identity } }
    }

    private var filteredRows: [DisplayableAppRow] {
        store.displayRows.filter { row in
            let inScope: Bool
            switch scope {
            case .playing: inScope = row.isActive
            case .pinned: inScope = row.isPinned
            case .all: inScope = true
            }
            return inScope && (searchText.isEmpty || row.displayName.localizedCaseInsensitiveContains(searchText))
        }
    }

    private var currentOutputLabel: String {
        if let output = store.currentOutput { return "Current output · \(output.name)" }
        return store.statusMessage
    }

    private var currentOutputVolume: Double {
        guard let output = store.currentOutput else { return 1 }
        return store.deviceVolumeStates[output.id]?.volume ?? 1
    }

    private var currentOutputMuted: Bool {
        guard let output = store.currentOutput else { return false }
        return store.deviceVolumeStates[output.id]?.isMuted ?? false
    }

    private var emptyStateTitle: String {
        if store.operationState.isRefreshing { return "Refreshing channels" }
        if !store.permissionState.allowsProcessTaps { return "Audio permission needed" }
        if !store.issues.isEmpty { return "Channel discovery needs attention" }
        return searchText.isEmpty ? "No " + scope.rawValue.lowercased() + " apps" : "No matching apps"
    }

    private var emptyStateSymbol: String {
        if store.operationState.isRefreshing { return "arrow.triangle.2.circlepath" }
        if !store.permissionState.allowsProcessTaps { return "lock.trianglebadge.exclamationmark" }
        return "speaker.slash"
    }

    private var emptyStateDescription: String {
        if !store.permissionState.allowsProcessTaps { return "Allow audio capture, then refresh to discover audible apps." }
        if store.operationState.isRefreshing { return "Auralis is checking active audio channels." }
        return "Start audio in an app, refresh, or show inactive apps."
    }

    private func dismissInspector() {
        if let selectedAppID { store.endContinuousEdits(for: selectedAppID) }
        showsInspector = false
        selectedAppID = nil
    }
}
