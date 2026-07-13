import SwiftUI

struct MenuBarRootView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var store: AudioControlStore
    @State private var selectedAppID: AudioAppIdentity?
    @State private var showsFirstRun = false
    @State private var availableScreenHeight: CGFloat = 700
    @FocusState private var popupFocused: Bool
    private let nav = PopupKeyboardNavModel()

    private var dimensions: PopupDimensions {
        store.settings.customization.popupDensity.dimensions
    }

    private var hasExpandedEQ: Bool {
        guard let selectedAppID else { return false }
        return store.displayRows.contains { $0.identity == selectedAppID }
    }

    private var popupWidth: Double {
        hasExpandedEQ
            ? dimensions.width
            : store.settings.customization.popupDensity.collapsedWidth
    }

    private var quickActionRow: DisplayableAppRow? {
        guard let identity = PopupQuickActionTargetResolver.resolve(
            rows: store.displayRows,
            selectedAppID: selectedAppID
        ) else { return nil }
        return store.displayRows.first { $0.identity == identity }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()

            OutputVolumeSection(store: store, layout: .compact)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !store.permissionState.allowsProcessTaps {
                        permissionBanner
                    }

                    if let issue = store.issues.last {
                        issueBanner(issue)
                    }

                    if store.displayRows.isEmpty {
                        ContentUnavailableView("No Apps", systemImage: "speaker.slash", description: Text("Refresh or enable inactive apps in Settings."))
                            .frame(maxWidth: .infinity)
                            .frame(height: PopupContentLayoutModel.emptyStateHeight)
                    } else {
                        LazyVStack(spacing: 8) {
                            ForEach(store.displayRows) { row in
                                VStack(spacing: 8) {
                                    AppRowView(
                                        row: row,
                                        rowHeight: dimensions.rowHeight,
                                        isSelected: selectedAppID == row.identity,
                                        onSelect: { select(row.identity) },
                                        onVolume: { store.setVolumeIntent($0, for: row.identity) },
                                        onVolumeEditingChanged: { editing in
                                            editing ? store.beginVolumeEditing(for: row.identity) : store.endVolumeEditing(for: row.identity)
                                        },
                                        onMute: { store.setMutedIntent($0, for: row.identity) },
                                        onBoost: { store.setBoostIntent($0, for: row.identity) },
                                        onPin: { pinned in
                                            store.pinIntent(pinned, identity: row.identity)
                                        },
                                        onIgnore: { store.ignoreIntent(row.identity) },
                                        devices: store.devices,
                                        onRoute: { store.setRouteIntent($0, for: row.identity) },
                                        volumeStep: store.settings.customization.volumeStep.fraction,
                                        layout: .compact
                                    )

                                    if selectedAppID == row.identity {
                                        EQPanelView(
                                            row: row,
                                            style: .compact,
                                            onClose: { closeEQ(for: row.identity) },
                                            onGain: { band, gain in
                                                store.setEQGainIntent(gain, band: band, for: row.identity)
                                            },
                                            onGainEditingChanged: { band, editing in
                                                editing ? store.beginEQEditing(band: band, for: row.identity) : store.endEQEditing(band: band, for: row.identity)
                                            },
                                            onReset: { store.resetEQIntent(for: row.identity) }
                                        )
                                        .transition(.opacity.combined(with: .move(edge: .top)))
                                    }
                                }
                            }
                        }
                    }

                    if !hasExpandedEQ && !store.displayRows.isEmpty {
                        eqHint
                    }
                }
                .padding(.trailing, 2)
            }
            .scrollIndicators(.automatic)
            // A ScrollView has no useful intrinsic height inside MenuBarExtra.
            // Supplying the adaptive height explicitly prevents a collapsed,
            // nearly unusable popover while still respecting small displays.
            .frame(height: popupContentHeight)
        }
        .padding(dimensions.contentPadding)
        .frame(width: popupWidth)
        .preferredColorScheme(store.settings.customization.appearance.colorScheme)
        .focusable()
        .focused($popupFocused)
        .focusEffectDisabled()
        .onAppear {
            updateAvailableScreenHeight()
            nav.sync(apps: store.displayRows.map(\.identity), isEditing: false)
            popupFocused = true
            showsFirstRun = !store.settings.hasCompletedOnboarding
        }
        .sheet(isPresented: $showsFirstRun) { FirstRunView(store: store) }
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
            if let target = nav.returnActionTarget(for: selectedAppID) {
                selectedAppID = target
                toggleMute(for: target)
            }
            return .handled
        }
        .onKeyPress(.leftArrow) { adjustSelectedVolume(by: -store.settings.customization.volumeStep.fraction); return .handled }
        .onKeyPress(.rightArrow) { adjustSelectedVolume(by: store.settings.customization.volumeStep.fraction); return .handled }
        .onKeyPress(.escape) {
            if let selectedAppID { closeEQ(for: selectedAppID) }
            return .handled
        }
    }

    /// Keeps the popover inside the display containing the pointer/menu-bar item.
    /// Real intrinsic sizes matter here: the two-line app row, permission card,
    /// and vertical EQ are all taller than their original estimates.
    private var popupContentHeight: CGFloat {
        CGFloat(PopupContentLayoutModel.contentHeight(
            dimensions: dimensions,
            rowCount: store.displayRows.count,
            includesPermissionBanner: !store.permissionState.allowsProcessTaps,
            includesIssueBanner: store.issues.last != nil,
            includesExpandedEQ: hasExpandedEQ,
            availableScreenHeight: Double(availableScreenHeight),
            deviceCount: store.devices.count
        ))
    }

    private func updateAvailableScreenHeight() {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        availableScreenHeight = screen?.visibleFrame.height ?? 700
    }

    private func toggleMuteForSelection() {
        guard let selectedAppID else { return }
        toggleMute(for: selectedAppID)
    }

    private func toggleMute(for identity: AudioAppIdentity) {
        guard let row = store.displayRows.first(where: { $0.identity == identity }) else { return }
        store.setMutedIntent(!row.settings.isMuted, for: identity)
    }

    private func adjustSelectedVolume(by delta: Double) {
        guard let selectedAppID, let row = store.displayRows.first(where: { $0.identity == selectedAppID }) else { return }
        store.setVolumeIntent(row.settings.volume + delta, for: selectedAppID)
    }

    private func adjustVolume(for row: DisplayableAppRow, by delta: Double) {
        store.setVolumeIntent(row.settings.volume + delta, for: row.identity)
    }

    private func select(_ identity: AudioAppIdentity) {
        if let selectedAppID {
            store.endContinuousEdits(for: selectedAppID)
        }
        withAnimation(.easeInOut(duration: 0.16)) {
            selectedAppID = selectedAppID == identity ? nil : identity
        }
    }

    private func closeEQ(for identity: AudioAppIdentity) {
        store.endContinuousEdits(for: identity)
        withAnimation(.easeInOut(duration: 0.16)) {
            selectedAppID = nil
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("EQMacRep")
                    .font(.subheadline.weight(.semibold))

                statusBadge

                Spacer(minLength: 4)

                headerActions
            }

            if let quickActionRow {
                quickActions(for: quickActionRow)
            }
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

    private func quickActions(for row: DisplayableAppRow) -> some View {
        HStack(spacing: 4) {
            Button {
                select(row.identity)
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(row.isActive ? Color.green : Color.secondary.opacity(0.6))
                        .frame(width: 5, height: 5)
                    Text(row.displayName)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(selectedAppID == row.identity ? "Hide EQ for \(row.displayName)" : "Show EQ for \(row.displayName)")

            Text("\(Int((row.settings.volume * 100).rounded()))%")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)

            quickActionButton(
                systemName: "minus",
                title: "Lower \(row.displayName) volume",
                isDisabled: row.settings.volume <= 0
            ) {
                adjustVolume(for: row, by: -store.settings.customization.volumeStep.fraction)
            }

            quickActionButton(
                systemName: row.settings.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                title: row.settings.isMuted ? "Unmute \(row.displayName)" : "Mute \(row.displayName)",
                isActive: row.settings.isMuted
            ) {
                toggleMute(for: row.identity)
            }

            quickActionButton(
                systemName: "plus",
                title: "Raise \(row.displayName) volume",
                isDisabled: row.settings.volume >= 1
            ) {
                adjustVolume(for: row, by: store.settings.customization.volumeStep.fraction)
            }

            quickActionButton(
                systemName: "slider.vertical.3",
                title: selectedAppID == row.identity ? "Hide EQ for \(row.displayName)" : "Show EQ for \(row.displayName)",
                isActive: selectedAppID == row.identity
            ) {
                select(row.identity)
            }
        }
        .padding(4)
        .frame(height: 30)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func quickActionButton(
        systemName: String,
        title: String,
        isActive: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .frame(width: 22, height: 22)
                .background(
                    isActive ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 5)
                )
        }
        .buttonStyle(.borderless)
        .disabled(isDisabled)
        .help(title)
        .accessibilityLabel(title)
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
                openWindow(id: "main")
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

    private func issueBanner(_ issue: AudioIssue) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(issue.severity == .error ? .red : .orange)
            Text(issue.message).font(.caption).lineLimit(3)
            Spacer()
            if issue.recovery == .retry {
                Button("Retry") { store.refreshIntent() }.controlSize(.small)
            }
            Button { store.dismissIssue(id: issue.id) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
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
