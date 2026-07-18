import SwiftUI

struct MenuBarRootView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var controls: ExternalControlsCoordinator
    @ObservedObject var store: AudioControlStore
    @State private var keyboardSelectionID: AudioAppIdentity?
    @State private var expandedAppID: AudioAppIdentity?
    @State private var showsFirstRun = false
    @State private var availableScreenHeight: CGFloat = 700
    @State private var nav = PopupKeyboardNavModel()
    @FocusState private var popupFocused: Bool

    private var dimensions: PopupDimensions {
        store.settings.customization.popupDensity.dimensions
    }

    private var hasExpandedEQ: Bool {
        guard let expandedAppID else { return false }
        return store.displayRows.contains { $0.identity == expandedAppID }
    }

    private var popupWidth: Double {
        hasExpandedEQ
            ? dimensions.width
            : store.settings.customization.popupDensity.collapsedWidth
    }

    private var visibleIssues: [AudioIssue] {
        AudioIssuePresentationModel.visibleIssues(
            store.issues,
            permissionState: store.permissionState,
            hidesAudioPermissionIssue: true
        )
    }

    private var scrollContentHeight: Double {
        PopupContentLayoutModel.contentHeight(
            dimensions: dimensions,
            rowCount: store.displayRows.count,
            includesPermissionBanner: !store.permissionState.allowsProcessTaps,
            issueCount: visibleIssues.count,
            includesExpandedEQ: hasExpandedEQ,
            availableScreenHeight: availableScreenHeight,
            deviceCount: store.devices.count
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()

            OutputVolumeSection(store: store, layout: .compact)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if !store.permissionState.allowsProcessTaps {
                            permissionBanner
                        }

                        if !visibleIssues.isEmpty {
                            AudioIssueListView(store: store, issues: visibleIssues, compact: true)
                        }

                        if store.displayRows.isEmpty {
                            ContentUnavailableView("No Apps", systemImage: "speaker.slash", description: Text("Refresh or enable inactive apps in Settings."))
                                .frame(maxWidth: .infinity)
                                .frame(height: PopupContentLayoutModel.emptyStateHeight)
                        } else {
                            LazyVStack(spacing: 8) {
                                ForEach(store.displayRows) { row in
                                    popupRow(row)
                                        .id(row.identity)
                                }
                            }
                        }

                        if !hasExpandedEQ && !store.displayRows.isEmpty {
                            keyboardHint
                        }
                    }
                }
                .frame(height: scrollContentHeight)
                .onChange(of: keyboardSelectionID) { _, identity in
                    guard let identity else { return }
                    withAnimation(.easeInOut(duration: 0.14)) {
                        proxy.scrollTo(identity, anchor: .center)
                    }
                }
                .onChange(of: expandedAppID) { _, identity in
                    guard let identity else { return }
                    withAnimation(.easeInOut(duration: 0.14)) {
                        proxy.scrollTo(identity, anchor: .center)
                    }
                }
            }
        }
        .padding(dimensions.contentPadding)
        .frame(width: popupWidth)
        .frame(maxHeight: maxPopupHeight)
        .fixedSize(horizontal: false, vertical: true)
        .preferredColorScheme(store.settings.customization.appearance.colorScheme)
        .focusable()
        .focused($popupFocused)
        .focusEffectDisabled()
        .onAppear {
            controls.isPopupVisible = true
            updateAvailableScreenHeight()
            nav.sync(apps: store.displayRows.map(\.identity), isEditing: false)
            popupFocused = true
            showsFirstRun = !store.settings.hasCompletedOnboarding
        }
        .onDisappear {
            controls.isPopupVisible = false
            if let expandedAppID { store.endContinuousEdits(for: expandedAppID) }
        }
        .sheet(isPresented: $showsFirstRun) { FirstRunView(store: store) }
        .onChange(of: store.displayRows) { _, rows in
            nav.sync(apps: rows.map(\.identity), isEditing: false)
            let visibleIDs = Set(rows.map(\.identity))
            if let keyboardSelectionID, !visibleIDs.contains(keyboardSelectionID) {
                self.keyboardSelectionID = nil
            }
            if let expandedAppID, !visibleIDs.contains(expandedAppID) {
                store.endContinuousEdits(for: expandedAppID)
                self.expandedAppID = nil
            }
        }
        .onKeyPress(.downArrow) {
            if let next = nav.next(after: keyboardSelectionID) { keyboardSelectionID = next }
            return .handled
        }
        .onKeyPress(.upArrow) {
            if let previous = nav.previous(before: keyboardSelectionID) { keyboardSelectionID = previous }
            return .handled
        }
        .onKeyPress(.space) {
            toggleMuteForKeyboardSelection()
            return .handled
        }
        .onKeyPress(.return) {
            toggleEQForReturn()
            return .handled
        }
        .onKeyPress(.leftArrow) { adjustSelectedVolume(by: -store.settings.customization.volumeStep.fraction); return .handled }
        .onKeyPress(.rightArrow) { adjustSelectedVolume(by: store.settings.customization.volumeStep.fraction); return .handled }
        .onKeyPress(.escape) {
            if let expandedAppID {
                closeEQ(for: expandedAppID)
            } else {
                keyboardSelectionID = nil
            }
            return .handled
        }
        .accessibilityHint(PopupKeyboardNavModel.accessibilityHint)
        .accessibilityIdentifier("eqmacrep.popup.mixer")
    }

    @ViewBuilder
    private func popupRow(_ row: DisplayableAppRow) -> some View {
        VStack(spacing: 8) {
            ConnectedAppRowView(
                store: store,
                row: row,
                rowHeight: dimensions.rowHeight,
                isSelected: expandedAppID == row.identity,
                onSelect: { toggleEQ(for: row.identity) },
                layout: .compact
            )

            if expandedAppID == row.identity {
                EQPanelView(
                    row: row,
                    style: .compact,
                    onClose: { closeEQ(for: row.identity) },
                    onGain: { band, gain in
                        store.setEQGainIntent(gain, band: band, for: row.identity)
                    },
                    onGainEditingChanged: { band, editing in
                        if editing {
                            store.beginEQEditing(band: band, for: row.identity)
                        } else {
                            store.endEQEditing(band: band, for: row.identity)
                        }
                    },
                    onReset: { store.resetEQIntent(for: row.identity) }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    keyboardSelectionID == row.identity ? Color.accentColor.opacity(0.75) : Color.clear,
                    lineWidth: 2
                )
        )
    }

    private func updateAvailableScreenHeight() {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        availableScreenHeight = screen?.visibleFrame.height ?? 700
    }

    /// Maximum popover height before the app list starts scrolling. Keeps the
    /// popover on-screen when many apps are discovered.
    private var maxPopupHeight: CGFloat {
        PopupContentLayoutModel.popupMaxHeight(availableScreenHeight: availableScreenHeight)
    }

    private func toggleMuteForKeyboardSelection() {
        guard let keyboardSelectionID else { return }
        toggleMute(for: keyboardSelectionID)
    }

    private func toggleMute(for identity: AudioAppIdentity) {
        guard let row = store.displayRows.first(where: { $0.identity == identity }) else { return }
        store.setMutedIntent(!row.settings.isMuted, for: identity)
    }

    private func adjustSelectedVolume(by delta: Double) {
        guard let keyboardSelectionID,
              let row = store.displayRows.first(where: { $0.identity == keyboardSelectionID }) else { return }
        store.setVolumeIntent(row.settings.volume + delta, for: keyboardSelectionID)
    }

    private func toggleEQForReturn() {
        guard let target = nav.returnActionTarget(for: keyboardSelectionID) else { return }
        keyboardSelectionID = target
        toggleEQ(for: target)
    }

    private func toggleEQ(for identity: AudioAppIdentity) {
        keyboardSelectionID = identity
        if let expandedAppID {
            store.endContinuousEdits(for: expandedAppID)
        }
        withAnimation(.easeInOut(duration: 0.16)) {
            expandedAppID = expandedAppID == identity ? nil : identity
        }
    }

    private func closeEQ(for identity: AudioAppIdentity) {
        store.endContinuousEdits(for: identity)
        withAnimation(.easeInOut(duration: 0.16)) {
            expandedAppID = nil
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("EQMacRep")
                .font(.subheadline.weight(.semibold))

            statusBadge

            Spacer(minLength: 4)

            headerActions
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            if store.operationState.isRefreshing {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 7, height: 7)
            } else {
                Circle()
                    .fill(statusTint)
                    .frame(width: 6, height: 6)
            }

            Text(appCountSummary)
                .font(.caption2.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
        .background(Color.secondary.opacity(0.09), in: Capsule())
        .help(store.statusMessage)
        .accessibilityLabel("Audio status")
        .accessibilityValue(store.statusMessage)
    }

    private var headerActions: some View {
        HStack(spacing: 3) {
            Button {
                store.refreshIntent()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 24, height: 24)
                    .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.borderless)
            .disabled(store.operationState.isRefreshing)
            .help("Refresh audio apps")

            Button {
                openWindow(id: AppWindowID.main.rawValue)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "macwindow")
                    .frame(width: 24, height: 24)
                    .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.borderless)
            .help("Open main window")

            Button {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 24, height: 24)
                    .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
    }

    private var statusTint: Color {
        switch store.operationState {
        case .idle, .ready: .green
        case .refreshing: .blue
        case .degraded: .orange
        case .failed: .red
        }
    }

    private var appCountSummary: String {
        let total = store.displayRows.count
        let deviceCount = store.devices.count
        guard total > 0 else {
            return deviceCount == 1 ? "No apps · 1 device" : "No apps · \(deviceCount) devices"
        }
        let active = store.displayRows.filter(\.isActive).count
        let apps = active == total
            ? "\(active) app\(active == 1 ? "" : "s")"
            : "\(active)/\(total) apps"
        let devices = deviceCount == 1 ? "1 device" : "\(deviceCount) devices"
        return "\(apps) · \(devices)"
    }

    private var permissionBanner: some View {
        PermissionStatusView(store: store, compact: true)
    }

    private var keyboardHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard")
                .foregroundStyle(.secondary)
            Text(PopupKeyboardNavModel.visibleKeyboardHint)
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
