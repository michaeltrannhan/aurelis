import SwiftUI

/// Aurora pro console: header/output/search, horizontal output deck,
/// Playing/Pinned/All channels, and a stable selected-app inspector.
struct MainWindowView: View {
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var store: AudioControlStore
    @State private var selectedAppID: AudioAppIdentity?
    @State private var searchText = ""
    @State private var channelFilter: ChannelFilter = .playing
    @State private var pulseToken: UUID?
    @State private var showsInspectorSheet = false

    private enum ChannelFilter: String, CaseIterable, Identifiable {
        case playing, pinned, all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .playing: "Playing"
            case .pinned: "Pinned"
            case .all: "All"
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            let useSheetInspector = geo.size.width < AuralisSpacing.inspectorBreakpoint
            VStack(spacing: 0) {
                header
                Divider().opacity(0.35)
                signalPath
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                outputDeck
                    .padding(.horizontal, 18)
                Divider().opacity(0.25)
                content(useSheetInspector: useSheetInspector)
            }
            .frame(minWidth: 820, minHeight: 560)
            .background(
                LinearGradient(
                    colors: [AuralisColor.canvas, AuralisColor.canvas.opacity(0.92)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .preferredColorScheme(store.settings.customization.appearance.colorScheme)
            .sheet(isPresented: $showsInspectorSheet) {
                if let selected = selectedRow {
                    inspector(for: selected)
                        .frame(minWidth: 420, minHeight: 360)
                        .padding()
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Auralis")
                    .font(AuralisTypography.workspaceTitle(26))
                    .foregroundStyle(AuralisColor.harmonicViolet)
                Text(store.currentOutput?.name ?? "No output")
                    .font(AuralisTypography.metric(12))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Current output \(store.currentOutput?.name ?? "none")")
            }
            Spacer(minLength: 12)
            TextField("Search apps", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
                .font(AuralisTypography.content(.callout))
            Picker("Filter", selection: $channelFilter) {
                ForEach(ChannelFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
            ProfileMenuButton(store: store)
                .frame(width: 205)
            Button { store.refreshIntent() } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: AuralisSpacing.controlMinHit, height: AuralisSpacing.controlMinHit)
            }
            .buttonStyle(.plain)
            .help("Refresh audio apps")
            Button {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: AuralisSpacing.controlMinHit, height: AuralisSpacing.controlMinHit)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private var signalPath: some View {
        let row = selectedRow ?? store.displayRows.first(where: \.isActive) ?? store.displayRows.first
        let nodes = SignalPathBuilder.nodes(
            appName: row?.displayName ?? "App",
            volume: row?.settings.volume ?? 0,
            isMuted: row?.settings.isMuted ?? false,
            boost: row?.settings.boost ?? .x1,
            outputName: store.currentOutput?.name ?? "Output"
        )
        return SignalPathView(nodes: nodes, pulseToken: pulseToken)
            .onChange(of: store.commandCoordinator.lastReceipt?.id) { _, _ in
                guard let receipt = store.commandCoordinator.lastReceipt, receipt.accepted else { return }
                pulseToken = UUID()
            }
    }

    private var outputDeck: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(store.channels.outputOrder, id: \.self) { deviceID in
                    if let model = store.channels.outputModel(for: deviceID) {
                        OutputDeckCard(model: model)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .accessibilityLabel("Output deck")
    }

    @ViewBuilder
    private func content(useSheetInspector: Bool) -> some View {
        HStack(spacing: 0) {
            channelList
            if !useSheetInspector {
                Divider().opacity(0.3)
                if let selected = selectedRow {
                    inspector(for: selected)
                        .frame(width: 320)
                } else {
                    VStack {
                        Text("Select an app")
                            .font(AuralisTypography.workspaceTitle(16))
                            .foregroundStyle(.secondary)
                        Text("EQ and routing stay here.")
                            .font(AuralisTypography.content(.caption))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(width: 320)
                    .frame(maxHeight: .infinity)
                }
            }
        }
    }

    private var channelList: some View {
        VStack(spacing: 0) {
            if !store.permissionState.allowsProcessTaps {
                PermissionStatusView(store: store, compact: false)
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
            }
            let visibleIssues = AudioIssuePresentationModel.visibleIssues(
                store.issues,
                permissionState: store.permissionState,
                hidesAudioPermissionIssue: true
            )
            if !visibleIssues.isEmpty {
                AudioIssueListView(store: store, issues: visibleIssues)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
            }

            let rows = filteredRows
            if rows.isEmpty {
                MixerEmptyStateView(
                    state: MixerEmptyState(phase: store.mixerPhase),
                    onRefresh: { store.refreshIntent() },
                    onShowInactive: {
                        var settings = store.settings
                        settings.customization.showInactiveApps = true
                        store.settings = settings
                        store.refreshIntent()
                    }
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(rows) { row in
                            ConnectedAppRowView(
                                store: store,
                                row: row,
                                rowHeight: 54,
                                isSelected: selectedAppID == row.identity,
                                onSelect: { select(row.identity, useSheet: true) },
                                layout: .desktop
                            )
                            .padding(.horizontal, 12)
                        }
                    }
                    .padding(.vertical, 12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func inspector(for row: DisplayableAppRow) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(row.displayName)
                .font(AuralisTypography.workspaceTitle(18))
            EQPanelView(
                store: store,
                row: row,
                style: .desktop,
                onClose: { closeEQ(row) }
            )
            MultiOutputRoutePicker(
                route: row.settings.route,
                devices: store.devices,
                onApply: { route in
                    try await store.setRoute(route, for: row.identity)
                },
                onDismiss: {}
            )
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(AuralisColor.panel.opacity(0.55))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.displayName) inspector")
    }

    private var selectedRow: DisplayableAppRow? {
        guard let selectedAppID else { return nil }
        return store.displayRows.first { $0.identity == selectedAppID }
    }

    private var filteredRows: [DisplayableAppRow] {
        store.displayRows.filter { row in
            switch channelFilter {
            case .playing: row.isActive
            case .pinned: row.isPinned
            case .all: true
            }
        }.filter { row in
            guard !searchText.isEmpty else { return true }
            return row.displayName.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func select(_ identity: AudioAppIdentity, useSheet: Bool) {
        withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
            if let selectedAppID, selectedAppID != identity {
                store.endContinuousEdits(for: selectedAppID)
            }
            selectedAppID = selectedAppID == identity ? nil : identity
            showsInspectorSheet = useSheet && selectedAppID != nil
        }
    }

    private func closeEQ(_ row: DisplayableAppRow) {
        store.endContinuousEdits(for: row.identity)
        withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
            selectedAppID = nil
            showsInspectorSheet = false
        }
    }
}

private struct OutputDeckCard: View {
    @ObservedObject var model: OutputChannelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.name)
                .font(AuralisTypography.workspaceTitle(14))
                .lineLimit(1)
            Text(model.visibleMuted ? "Muted" : "\(Int((model.visibleVolume * 100).rounded()))%")
                .font(AuralisTypography.metric(12))
                .foregroundStyle(model.isDefault ? AuralisColor.signalCyan : .secondary)
        }
        .padding(12)
        .frame(width: 150, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AuralisColor.panel.opacity(model.isDefault ? 0.95 : 0.65))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            model.isDefault ? AuralisColor.signalCyan.opacity(0.55) : .clear,
                            lineWidth: 1
                        )
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.name), \(model.visibleMuted ? "muted" : "\(Int((model.visibleVolume * 100).rounded())) percent")\(model.isDefault ? ", current output" : "")")
    }
}
