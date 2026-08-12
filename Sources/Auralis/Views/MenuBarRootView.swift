import SwiftUI

struct MenuBarRootView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var controls: ExternalControlsCoordinator
    @ObservedObject var store: AudioControlStore

    @State private var keyboardSelectionID: AudioAppIdentity?
    @State private var destination: PopupDestination?
    @State private var searchText = ""
    @State private var channelFilter: PopupChannelFilter = .playing
    @State private var showsRoutePicker = false
    @State private var showsSavePreset = false
    @State private var presetName = ""
    @State private var showsFirstRun = false
    @State private var availableScreenHeight: CGFloat = 700
    @State private var nav = PopupKeyboardNavModel()
    @State private var popupOutputID: String?
    @FocusState private var popupFocused: Bool

    private enum PopupDestination: Hashable {
        case process(AudioAppIdentity)
        case output(String)
    }

    private enum PopupChannelFilter: String, CaseIterable, Identifiable {
        case playing
        case pinned
        case all

        var id: String { rawValue }

        var title: String {
            switch self {
            case .playing: "Playing"
            case .pinned: "Pinned"
            case .all: "All"
            }
        }
    }

    private var dimensions: PopupDimensions {
        store.settings.customization.popupDensity.dimensions
    }

    private var visibleIssues: [AudioIssue] {
        AudioIssuePresentationModel.visibleIssues(
            store.issues,
            permissionState: store.permissionState,
            hidesAudioPermissionIssue: true
        )
    }

    private var filteredRows: [DisplayableAppRow] {
        store.displayRows.filter { row in
            switch channelFilter {
            case .playing: row.isActive
            case .pinned: row.isPinned
            case .all: true
            }
        }.filter { row in
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            return query.isEmpty || row.displayName.localizedCaseInsensitiveContains(query)
        }
    }

    private var popupOutputPager: OutputDevicePagerModel {
        OutputDevicePagerModel(
            deviceIDs: store.channels.outputOrder,
            defaultDeviceID: store.currentOutput?.id,
            selectedDeviceID: popupOutputID
        )
    }

    private var popupHeight: Double {
        let maximum = PopupContentLayoutModel.popupMaxHeight(
            availableScreenHeight: availableScreenHeight
        )
        if destination != nil {
            return min(maximum, 620)
        }

        let content = PopupContentLayoutModel.contentHeight(
            dimensions: dimensions,
            rowCount: filteredRows.count,
            includesPermissionBanner: !store.permissionState.allowsProcessTaps,
            issueCount: visibleIssues.count,
            includesExpandedEQ: false,
            availableScreenHeight: availableScreenHeight,
            deviceCount: popupOutputPager.deviceIDs.isEmpty ? 0 : 1
        )
        return min(maximum, max(430, content + 190))
    }

    var body: some View {
        keyboardEnabledPopup
            .accessibilityHint(PopupKeyboardNavModel.accessibilityHint)
            .accessibilityIdentifier("auralis.popup.mixer")
    }

    private var popupPages: some View {
        Group {
            if destination == nil {
                mixerPage
                    .transition(.move(edge: .leading).combined(with: .opacity))
            } else {
                inspectorPage
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    private var framedPopup: some View {
        popupPages
            .padding(dimensions.contentPadding)
            .frame(width: dimensions.width, height: popupHeight)
            .background(AuralisColor.canvas)
            .preferredColorScheme(store.settings.customization.appearance.colorScheme)
            .focusable()
            .focused($popupFocused)
            .focusEffectDisabled()
    }

    private var presentedPopup: some View {
        framedPopup
            .onAppear {
                controls.isPopupVisible = true
                updateAvailableScreenHeight()
                syncKeyboardNavigation()
                popupFocused = true
                showsFirstRun = !store.settings.hasCompletedOnboarding
            }
            .onDisappear {
                controls.isPopupVisible = false
                endInspectorEdits()
            }
            .sheet(isPresented: $showsFirstRun) { FirstRunView(store: store) }
            .alert("Save Mix Preset", isPresented: $showsSavePreset) {
                TextField("Preset name", text: $presetName)
                Button("Save") { store.createProfileIntent(named: presetName, scope: .global) }
                    .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Saves app volume, Process EQ, routes, and Output EQ for every routed device.")
            }
    }

    private var observedPopup: some View {
        presentedPopup
            .onChange(of: filteredRows) { _, _ in
                syncKeyboardNavigation()
                validateSelection()
            }
            .onChange(of: store.devices) { _, _ in validateSelection() }
            .onChange(of: destination) { _, _ in
                showsRoutePicker = false
                syncKeyboardNavigation()
            }
    }

    private var navigationKeyEnabledPopup: some View {
        observedPopup
            .onKeyPress(.downArrow) {
                guard destination == nil else { return .ignored }
                if let next = nav.next(after: keyboardSelectionID) { keyboardSelectionID = next }
                return .handled
            }
            .onKeyPress(.upArrow) {
                guard destination == nil else { return .ignored }
                if let previous = nav.previous(before: keyboardSelectionID) { keyboardSelectionID = previous }
                return .handled
            }
    }

    private var keyboardEnabledPopup: some View {
        navigationKeyEnabledPopup
            .onKeyPress(.space) {
                guard destination == nil else { return .ignored }
                toggleSelectedMute()
                return .handled
            }
            .onKeyPress(.return) {
                guard destination == nil else { return .ignored }
                openSelectedProcessEQ()
                return .handled
            }
            .onKeyPress(.leftArrow) {
                guard destination == nil else { return .ignored }
                adjustSelectedVolume(by: -store.settings.customization.volumeStep.fraction)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                guard destination == nil else { return .ignored }
                adjustSelectedVolume(by: store.settings.customization.volumeStep.fraction)
                return .handled
            }
            .onKeyPress(.escape) {
                if destination != nil {
                    closeInspector()
                    return .handled
                }
                if !searchText.isEmpty {
                    searchText = ""
                    return .handled
                }
                if keyboardSelectionID != nil {
                    keyboardSelectionID = nil
                    return .handled
                }
                return .ignored
            }
    }

    private var mixerPage: some View {
        VStack(alignment: .leading, spacing: 8) {
            rootHeader

            popupOutputDeck

            VStack(spacing: 6) {
                TextField("Search apps", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search audio apps")

                Picker("Channels", selection: $channelFilter) {
                    ForEach(PopupChannelFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
            }

            Divider()

            appList
        }
    }

    @ViewBuilder
    private var popupOutputDeck: some View {
        let pager = popupOutputPager
        if let outputID = pager.selectedDeviceID,
           let model = store.channels.outputModel(for: outputID) {
            PopupOutputMaster(
                store: store,
                model: model,
                contextLabel: model.isDefault ? "CURRENT OUTPUT" : "PHYSICAL OUTPUT",
                onTune: { openOutputEQ(outputID) },
                paging: popupOutputPaging(for: pager)
            )
        } else {
            noOutputCard
        }
    }

    private func popupOutputPaging(
        for pager: OutputDevicePagerModel
    ) -> PopupOutputPaging? {
        guard pager.count > 1 else { return nil }
        let previousName = pager.previousDeviceID.flatMap(outputName)
        let nextName = pager.nextDeviceID.flatMap(outputName)
        return PopupOutputPaging(
            position: pager.position,
            count: pager.count,
            previousName: previousName,
            nextName: nextName,
            onPrevious: {
                guard let previousID = pager.previousDeviceID else { return }
                selectPopupOutput(previousID)
            },
            onNext: {
                guard let nextID = pager.nextDeviceID else { return }
                selectPopupOutput(nextID)
            }
        )
    }

    private func outputName(for deviceID: String) -> String? {
        store.devices.first(where: { $0.id == deviceID })?.name
    }

    private var appList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !store.permissionState.allowsProcessTaps {
                        PermissionStatusView(store: store, compact: true)
                    }

                    if !visibleIssues.isEmpty {
                        AudioIssueListView(store: store, issues: visibleIssues, compact: true)
                    }

                    if filteredRows.isEmpty {
                        popupEmptyState
                            .frame(height: PopupContentLayoutModel.emptyStateHeight)
                    } else {
                        LazyVStack(spacing: 7) {
                            ForEach(filteredRows) { row in
                                ConnectedAppRowView(
                                    store: store,
                                    row: row,
                                    rowHeight: dimensions.rowHeight,
                                    isSelected: false,
                                    onSelect: { openProcessEQ(row.identity) },
                                    layout: .compact
                                )
                                .id(row.identity)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(
                                            keyboardSelectionID == row.identity
                                                ? AuralisColor.signalCyan.opacity(0.85)
                                                : Color.clear,
                                            lineWidth: 2
                                        )
                                }
                            }
                        }

                        keyboardHint
                    }
                }
            }
            .onChange(of: keyboardSelectionID) { _, identity in
                guard let identity else { return }
                withAnimation(.easeInOut(duration: 0.12)) {
                    proxy.scrollTo(identity, anchor: .center)
                }
            }
        }
    }

    private var popupEmptyState: some View {
        Group {
            if !searchText.isEmpty || channelFilter != .all {
                VStack(spacing: 7) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No matching apps").font(.headline)
                    Button("Show All") {
                        searchText = ""
                        channelFilter = .all
                    }
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
            } else {
                MixerEmptyStateView(
                    state: MixerEmptyState(phase: store.mixerPhase),
                    onRefresh: { store.refreshIntent() },
                    onShowInactive: showInactiveApps
                )
            }
        }
    }

    private var inspectorPage: some View {
        VStack(alignment: .leading, spacing: 8) {
            inspectorHeader
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch destination {
                    case let .process(identity):
                        if let row = store.displayRows.first(where: { $0.identity == identity }) {
                            processInspector(row)
                        }
                    case let .output(deviceID):
                        if let device = store.devices.first(where: { $0.id == deviceID }) {
                            outputInspector(device)
                        }
                    case nil:
                        EmptyView()
                    }
                }
            }
        }
    }

    private var inspectorHeader: some View {
        HStack(spacing: 8) {
            Button(action: closeInspector) {
                Image(systemName: "chevron.left")
                    .frame(
                        width: AuralisSpacing.comfortableControlHit,
                        height: AuralisSpacing.comfortableControlHit
                    )
                    .background(AuralisColor.mutedPanel, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("[", modifiers: .command)
            .accessibilityLabel("Back to mixer")

            VStack(alignment: .leading, spacing: 1) {
                Text(inspectorTitle)
                    .font(AuralisTypography.workspaceTitle(16))
                    .lineLimit(1)
                Text(inspectorStageLabel)
                    .font(AuralisTypography.metric(9))
                    .foregroundStyle(inspectorAccent)
            }

            Spacer(minLength: 4)

            Button {
                presetName = suggestedPresetName
                showsSavePreset = true
            } label: {
                Image(systemName: "square.stack.3d.up")
                    .frame(
                        width: AuralisSpacing.comfortableControlHit,
                        height: AuralisSpacing.comfortableControlHit
                    )
                    .background(AuralisColor.mutedPanel, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("Save current mix as preset")
            .accessibilityLabel("Save current app mix and output tuning as preset")
        }
    }

    @ViewBuilder
    private func processInspector(_ row: DisplayableAppRow) -> some View {
        EQBandEditor(store: store, row: row, style: .compact, onClose: closeInspector)

        PopupInspectorSection(title: "ROUTE", accent: AuralisColor.signalCyan) {
            Button { showsRoutePicker = true } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(routeSummary(for: row).title)
                            .font(.caption.weight(.semibold))
                        Text(routeSummary(for: row).detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.triangle.branch")
                }
                .frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showsRoutePicker, arrowEdge: .leading) {
                MultiOutputRoutePicker(
                    route: row.settings.route,
                    devices: store.devices,
                    onApply: { route in try await store.setRoute(route, for: row.identity) },
                    onDismiss: { showsRoutePicker = false }
                )
                .frame(width: 340, height: 520)
            }
        }

        PopupInspectorSection(title: "ROUTED OUTPUTS", accent: AuralisColor.peakRose) {
            let outputs = row.settings.route.resolvedDevices(in: store.devices)
            if outputs.isEmpty {
                Text("No connected destination")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(outputs.enumerated()), id: \.element.id) { index, output in
                    Button { openOutputEQ(output.id) } label: {
                        HStack(spacing: 7) {
                            Text(index == 0 && outputs.count > 1 ? "CLOCK" : "OUT \(index + 1)")
                                .font(AuralisTypography.metric(8))
                                .foregroundStyle(index == 0 ? AuralisColor.stageAccent(.process) : Color.secondary)
                                .frame(width: 38, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(output.name).font(.caption.weight(.medium)).lineLimit(1)
                                Text(popupOutputEQSummary(output.id))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "slider.horizontal.3")
                                .foregroundStyle(AuralisColor.stageAccent(.output))
                        }
                        .frame(minHeight: 36)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Tune Output EQ for \(output.name)")
                }
            }
        }
    }

    @ViewBuilder
    private func outputInspector(_ device: AudioDeviceSnapshot) -> some View {
        if let model = store.channels.outputModel(for: device.id) {
            PopupOutputMaster(
                store: store,
                model: model,
                contextLabel: device.isDefault ? "CURRENT OUTPUT" : "PHYSICAL OUTPUT",
                onTune: nil
            )
        }

        EQBandEditor(store: store, device: device, style: .compact, onClose: closeInspector)

        PopupInspectorSection(title: "APPS USING THIS OUTPUT", accent: AuralisColor.signalCyan) {
            let apps = store.displayRows.filter {
                $0.settings.route.routes(to: device.id, in: store.devices)
            }
            if apps.isEmpty {
                Text("No visible apps are routed here")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(apps) { app in
                    Button { openProcessEQ(app.identity) } label: {
                        HStack {
                            Text(app.displayName)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Spacer()
                            Text("\(Int((app.settings.volume * 100).rounded()))%")
                                .font(AuralisTypography.metric(9))
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Tune Process EQ for \(app.displayName)")
                }
            }
        }
    }

    private var rootHeader: some View {
        HStack(spacing: 7) {
            Text("Auralis")
                .font(AuralisTypography.workspaceTitle(17))
            statusBadge
            Spacer(minLength: 3)
            headerActions
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            if store.operationState.isRefreshing {
                ProgressView().controlSize(.mini).frame(width: 7, height: 7)
            } else {
                Circle().fill(statusTint).frame(width: 6, height: 6)
            }
            Text("\(filteredRows.filter(\.isActive).count)/\(store.displayRows.count)")
                .font(AuralisTypography.metric(9))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
        .background(AuralisColor.mutedPanel, in: Capsule())
        .help(store.statusMessage)
        .accessibilityLabel("Audio status, \(store.statusMessage)")
    }

    private var headerActions: some View {
        HStack(spacing: 2) {
            ProfileMenuButton(store: store, compact: true)

            popupToolbarButton("Refresh audio apps", systemImage: "arrow.clockwise") {
                store.refreshIntent()
            }
            .disabled(store.operationState.isRefreshing)

            popupToolbarButton("Open main window", systemImage: "macwindow") {
                openWindow(id: AppWindowID.main.rawValue)
                NSApp.activate(ignoringOtherApps: true)
            }

            popupToolbarButton("Settings", systemImage: "gearshape") {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private func popupToolbarButton(
        _ label: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 28, height: 28)
                .background(AuralisColor.mutedPanel, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }

    private var noOutputCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.slash")
            VStack(alignment: .leading, spacing: 1) {
                Text("No output connected").font(.caption.weight(.semibold))
                Text("Refresh after connecting an audio device")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AuralisColor.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(AuralisColor.hairline) }
    }

    private var keyboardHint: some View {
        HStack(spacing: 7) {
            Image(systemName: "keyboard").foregroundStyle(.secondary)
            Text(PopupKeyboardNavModel.visibleKeyboardHint)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(9)
        .background(AuralisColor.mutedPanel, in: RoundedRectangle(cornerRadius: 9))
    }

    private var statusTint: Color {
        switch store.operationState {
        case .idle, .ready: .green
        case .refreshing: .blue
        case .degraded: .orange
        case .failed: .red
        }
    }

    private var inspectorTitle: String {
        switch destination {
        case let .process(identity):
            store.displayRows.first(where: { $0.identity == identity })?.displayName ?? "App"
        case let .output(deviceID):
            store.devices.first(where: { $0.id == deviceID })?.name ?? "Output"
        case nil:
            "Mixer"
        }
    }

    private var inspectorStageLabel: String {
        switch destination {
        case .process: "PROCESS EQ · PER APP"
        case .output: "OUTPUT EQ · PER DEVICE"
        case nil: "MIXER"
        }
    }

    private var inspectorAccent: Color {
        switch destination {
        case .output: AuralisColor.stageAccent(.output)
        case .process, nil: AuralisColor.stageAccent(.process)
        }
    }

    private var suggestedPresetName: String {
        "Mix \(store.settings.globalProfilesForDisplay.count + 1)"
    }

    private func routeSummary(for row: DisplayableAppRow) -> MultiOutputRouteSummary {
        MultiOutputRoutePickerModel.summary(for: row.settings.route, devices: store.devices)
    }

    private func popupOutputEQSummary(_ deviceID: String) -> String {
        let count = store.settings.deviceSettings[deviceID]?.eq.adjustedBandCount ?? 0
        return count == 0 ? "Output EQ flat" : "Output EQ · \(count) bands"
    }

    private func updateAvailableScreenHeight() {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        availableScreenHeight = screen?.visibleFrame.height ?? 700
    }

    private func syncKeyboardNavigation() {
        nav.sync(apps: filteredRows.map(\.identity), isEditing: destination != nil)
        if let keyboardSelectionID, !filteredRows.contains(where: { $0.identity == keyboardSelectionID }) {
            self.keyboardSelectionID = nil
        }
    }

    private func validateSelection() {
        if let popupOutputID,
           !store.channels.outputOrder.contains(popupOutputID) {
            self.popupOutputID = nil
        }
        switch destination {
        case let .process(identity) where !store.displayRows.contains(where: { $0.identity == identity }):
            closeInspector()
        case let .output(deviceID) where !store.devices.contains(where: { $0.id == deviceID }):
            closeInspector()
        default:
            break
        }
    }

    private func openSelectedProcessEQ() {
        guard let identity = nav.returnActionTarget(for: keyboardSelectionID) else { return }
        keyboardSelectionID = identity
        openProcessEQ(identity)
    }

    private func openProcessEQ(_ identity: AudioAppIdentity) {
        endInspectorEdits()
        keyboardSelectionID = identity
        withAnimation(.easeInOut(duration: 0.16)) {
            destination = .process(identity)
        }
    }

    private func openOutputEQ(_ deviceID: String) {
        endInspectorEdits()
        popupOutputID = deviceID
        withAnimation(.easeInOut(duration: 0.16)) {
            destination = .output(deviceID)
        }
    }

    private func selectPopupOutput(_ deviceID: String) {
        guard store.channels.outputOrder.contains(deviceID) else { return }
        withAnimation(.easeInOut(duration: 0.14)) {
            popupOutputID = deviceID
        }
    }

    private func closeInspector() {
        endInspectorEdits()
        withAnimation(.easeInOut(duration: 0.16)) {
            destination = nil
        }
    }

    private func endInspectorEdits() {
        switch destination {
        case let .process(identity): store.endContinuousEdits(for: identity)
        case let .output(deviceID): store.endContinuousOutputEQEdits(for: deviceID)
        case nil: break
        }
    }

    private func toggleSelectedMute() {
        guard let keyboardSelectionID,
              let row = store.displayRows.first(where: { $0.identity == keyboardSelectionID }) else { return }
        store.setMutedIntent(!row.settings.isMuted, for: keyboardSelectionID)
    }

    private func adjustSelectedVolume(by delta: Double) {
        guard let keyboardSelectionID,
              let row = store.displayRows.first(where: { $0.identity == keyboardSelectionID }) else { return }
        store.setVolumeIntent(row.settings.volume + delta, for: keyboardSelectionID)
    }

    private func showInactiveApps() {
        var customization = store.settings.customization
        customization.showInactiveApps = true
        store.applyCustomizationIntent(customization)
    }
}

private struct PopupOutputPaging {
    let position: Int
    let count: Int
    let previousName: String?
    let nextName: String?
    let onPrevious: () -> Void
    let onNext: () -> Void
}

private struct PopupOutputMaster: View {
    @ObservedObject var store: AudioControlStore
    @ObservedObject var model: OutputChannelModel
    let contextLabel: String
    let onTune: (() -> Void)?
    var paging: PopupOutputPaging? = nil

    private var target: ControlTarget { .outputDevice(model.id) }
    private var presentation: OutputControlPresentation {
        OutputControlPresentation(capabilities: model.capabilities)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(contextLabel)
                        .font(AuralisTypography.metric(8))
                        .foregroundStyle(model.isDefault ? AuralisColor.stageAccent(.process) : Color.secondary)
                    Text(model.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                Spacer(minLength: 3)
                if !model.isDefault {
                    Button {
                        store.setDefaultOutputDeviceIntent(model.id)
                    } label: {
                        Image(systemName: "circle")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .controlSize(.mini)
                    .help("Make \(model.name) the default output")
                    .accessibilityLabel("Make \(model.name) the default output")
                }
                if let paging {
                    HStack(spacing: 2) {
                        popupOutputPageButton(
                            systemImage: "chevron.left",
                            outputName: paging.previousName,
                            action: paging.onPrevious
                        )
                        Text("\(paging.position)/\(paging.count)")
                            .font(AuralisTypography.metric(8))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 24)
                        popupOutputPageButton(
                            systemImage: "chevron.right",
                            outputName: paging.nextName,
                            action: paging.onNext
                        )
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Physical output navigation")
                }
                if let onTune {
                    Button(action: onTune) {
                        HStack(spacing: 4) {
                            Circle().fill(AuralisColor.peakRose).frame(width: 6, height: 6)
                            Text("Output EQ")
                        }
                        .frame(minHeight: 28)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Tune Output EQ for \(model.name)")
                }
            }

            HStack(spacing: 7) {
                if presentation.showsMute {
                    Button {
                        _ = store.commandCoordinator.submit(
                            ControlCommand(target: target, mutation: .toggleMute)
                        )
                    } label: {
                        Image(systemName: model.visibleMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .foregroundStyle(model.visibleMuted ? Color.red : Color.primary)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .disabled(!presentation.enablesMute)
                    .accessibilityLabel(model.visibleMuted ? "Unmute \(model.name)" : "Mute \(model.name)")
                }

                if presentation.showsVolume {
                    Slider(
                        value: Binding(
                            get: { model.visibleVolume },
                            set: { value in
                                _ = store.commandCoordinator.submit(
                                    ControlCommand(target: target, mutation: .setVolume(value))
                                )
                            }
                        ),
                        in: 0...1,
                        onEditingChanged: { editing in
                            if !editing { store.commandCoordinator.flushContinuous(for: target) }
                        }
                    )
                    .disabled(!presentation.enablesVolume)
                    Text("\(Int((model.visibleVolume * 100).rounded()))%")
                        .font(AuralisTypography.metric(10))
                        .frame(width: 36, alignment: .trailing)
                } else {
                    Text("Hardware volume unavailable")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding(9)
        .background(AuralisColor.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(AuralisColor.hairline) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(model.name) output controls")
    }

    private func popupOutputPageButton(
        systemImage: String,
        outputName: String?,
        action: @escaping () -> Void
    ) -> some View {
        let direction = systemImage == "chevron.left" ? "Previous" : "Next"
        return Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 8, weight: .bold))
                .frame(width: 22, height: 24)
                .background(AuralisColor.mutedPanel, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(outputName == nil)
        .help(outputName.map { "\(direction) output: \($0)" } ?? "No \(direction.lowercased()) output")
        .accessibilityLabel(outputName.map { "\(direction) output, \($0)" } ?? "No \(direction.lowercased()) output")
    }
}

private struct PopupInspectorSection<Content: View>: View {
    let title: String
    let accent: Color
    @ViewBuilder let content: Content

    init(title: String, accent: Color, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accent = accent
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Capsule().fill(accent).frame(width: 11, height: 3)
                Text(title)
                    .font(AuralisTypography.metric(8))
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(9)
        .background(AuralisColor.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(AuralisColor.hairline) }
    }
}
