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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()

            OutputVolumeSection(store: store, layout: .compact)

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
                    VStack(spacing: 8) {
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

    private func updateAvailableScreenHeight() {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        availableScreenHeight = screen?.visibleFrame.height ?? 700
    }

    /// Maximum popover height before the app list starts scrolling. Keeps the
    /// popover on-screen when many apps are discovered.
    private var maxPopupHeight: CGFloat {
        max(400, availableScreenHeight - 40)
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
