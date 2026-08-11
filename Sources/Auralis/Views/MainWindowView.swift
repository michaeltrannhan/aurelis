import SwiftUI

/// A calm signal workbench: apps stay scannable, outputs stay directly
/// adjustable, and one stable inspector owns all detailed Process/Output work.
struct MainWindowView: View {
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var store: AudioControlStore

    @State private var inspectorSelection: InspectorSelection?
    @State private var searchText = ""
    @State private var channelFilter: ChannelFilter = .playing
    @State private var pulseToken: UUID?
    @State private var showsInspectorSheet = false

    private enum InspectorSelection: Hashable {
        case app(AudioAppIdentity)
        case output(String)
    }

    private enum ChannelFilter: String, CaseIterable, Identifiable {
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

    var body: some View {
        GeometryReader { geometry in
            let usesSheet = geometry.size.width < AuralisSpacing.inspectorBreakpoint

            VStack(spacing: 0) {
                header
                Divider().opacity(0.55)

                signalPath
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)

                outputDeck(usesSheet: usesSheet)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)

                Divider().opacity(0.45)
                workspace(usesSheet: usesSheet)
            }
            .frame(minWidth: 780, minHeight: 560)
            .background(AuralisColor.canvas)
            .preferredColorScheme(store.settings.customization.appearance.colorScheme)
            .sheet(isPresented: $showsInspectorSheet) {
                inspector
                    .frame(minWidth: 440, idealWidth: 470, minHeight: 520)
                    .background(AuralisColor.canvas)
            }
            .onChange(of: store.displayRows) { _, _ in validateSelection() }
            .onChange(of: store.devices) { _, _ in validateSelection() }
            .onChange(of: usesSheet) { _, shouldUseSheet in
                guard inspectorSelection != nil else { return }
                showsInspectorSheet = shouldUseSheet
            }
            .onDisappear(perform: endSelectedContinuousEdits)
        }
        .accessibilityIdentifier("auralis.main.workbench")
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Auralis")
                        .font(AuralisTypography.workspaceTitle(25))
                    Text(store.currentOutput?.name ?? "No output connected")
                        .font(AuralisTypography.content(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                ProfileMenuButton(store: store)
                    .frame(width: 205)

                toolbarButton("Refresh audio apps", systemImage: "arrow.clockwise") {
                    store.refreshIntent()
                }

                toolbarButton("Open Settings", systemImage: "gearshape") {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                }
            }

            HStack(spacing: 10) {
                TextField("Search apps", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)

                Picker("Channels", selection: $channelFilter) {
                    ForEach(ChannelFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 250)

                Spacer(minLength: 8)

                Text(channelCountLabel)
                    .font(AuralisTypography.metric(11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 13)
    }

    private func toolbarButton(
        _ label: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(
                    width: AuralisSpacing.comfortableControlHit,
                    height: AuralisSpacing.comfortableControlHit
                )
                .background(AuralisColor.mutedPanel, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private var signalPath: some View {
        let row = selectedApp ?? store.displayRows.first(where: \.isActive) ?? store.displayRows.first
        let outputNames: [String]
        let activeStage: EQStage?

        switch inspectorSelection {
        case let .output(deviceID):
            outputNames = store.devices.first(where: { $0.id == deviceID }).map { [$0.name] } ?? ["Output"]
            activeStage = .output
        case .app:
            outputNames = resolvedOutputs(for: row?.settings.route ?? .followDefault).map(\.name)
            activeStage = .process
        case nil:
            outputNames = resolvedOutputs(for: row?.settings.route ?? .followDefault).map(\.name)
            activeStage = nil
        }

        let nodes = SignalPathBuilder.nodes(
            appName: row?.displayName ?? "App",
            volume: row?.settings.volume ?? 0,
            isMuted: row?.settings.isMuted ?? false,
            boost: row?.settings.boost ?? .x1,
            outputNames: outputNames,
            activeStage: activeStage
        )

        return SignalPathView(nodes: nodes, pulseToken: pulseToken)
            .onChange(of: store.commandCoordinator.actionStates) { previous, current in
                let confirmed = current.contains { target, state in
                    guard previous[target] != state else { return false }
                    if case .applied = state { return true }
                    return false
                }
                if confirmed { pulseToken = UUID() }
            }
    }

    private func outputDeck(usesSheet: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("OUTPUTS")
                    .font(AuralisTypography.metric(10))
                    .foregroundStyle(.secondary)
                Text("Volume and Output EQ belong to each physical device")
                    .font(AuralisTypography.content(.caption2))
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(store.channels.outputOrder, id: \.self) { deviceID in
                        if let model = store.channels.outputModel(for: deviceID) {
                            OutputChannelStrip(
                                store: store,
                                model: model,
                                isSelected: inspectorSelection == .output(deviceID),
                                onTune: { select(.output(deviceID), usesSheet: usesSheet) }
                            )
                        }
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(height: 132)
            .accessibilityLabel("Output device channel strips")
        }
    }

    private func workspace(usesSheet: Bool) -> some View {
        HStack(spacing: 0) {
            channelList(usesSheet: usesSheet)

            if !usesSheet {
                Divider().opacity(0.5)
                inspector
                    .frame(width: 400)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func channelList(usesSheet: Bool) -> some View {
        VStack(spacing: 0) {
            if !store.permissionState.allowsProcessTaps {
                PermissionStatusView(store: store, compact: false)
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
            }

            let issues = AudioIssuePresentationModel.visibleIssues(
                store.issues,
                permissionState: store.permissionState,
                hidesAudioPermissionIssue: true
            )
            if !issues.isEmpty {
                AudioIssueListView(store: store, issues: issues)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
            }

            if filteredRows.isEmpty {
                MixerEmptyStateView(
                    state: MixerEmptyState(phase: store.mixerPhase),
                    onRefresh: { store.refreshIntent() },
                    onShowInactive: showInactiveApps
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(filteredRows) { row in
                            ConnectedAppRowView(
                                store: store,
                                row: row,
                                rowHeight: 56,
                                isSelected: inspectorSelection == .app(row.identity),
                                onSelect: { select(.app(row.identity), usesSheet: usesSheet) },
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

    @ViewBuilder
    private var inspector: some View {
        switch inspectorSelection {
        case let .app(identity):
            if let row = store.displayRows.first(where: { $0.identity == identity }) {
                AppSignalInspector(
                    store: store,
                    row: row,
                    onClose: closeInspector,
                    onTuneOutput: { deviceID in
                        select(.output(deviceID), usesSheet: showsInspectorSheet)
                    }
                )
            } else {
                InspectorPlaceholder()
            }
        case let .output(deviceID):
            if let device = store.devices.first(where: { $0.id == deviceID }) {
                OutputSignalInspector(
                    store: store,
                    device: device,
                    onClose: closeInspector,
                    onTuneApp: { identity in
                        select(.app(identity), usesSheet: showsInspectorSheet)
                    }
                )
            } else {
                InspectorPlaceholder()
            }
        case nil:
            InspectorPlaceholder()
        }
    }

    private var selectedApp: DisplayableAppRow? {
        guard case let .app(identity) = inspectorSelection else { return nil }
        return store.displayRows.first { $0.identity == identity }
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

    private var channelCountLabel: String {
        "\(filteredRows.count) of \(store.displayRows.count) apps"
    }

    private func resolvedOutputs(for route: DeviceRoute) -> [AudioDeviceSnapshot] {
        switch route.normalized {
        case .followDefault:
            return store.devices.filter(\.isDefault)
        case let .selectedDevice(deviceID):
            return store.devices.filter { $0.id == deviceID }
        case let .multiOutput(deviceIDs):
            let byID = Dictionary(uniqueKeysWithValues: store.devices.map { ($0.id, $0) })
            return deviceIDs.compactMap { byID[$0] }
        }
    }

    private func select(_ selection: InspectorSelection, usesSheet: Bool) {
        endSelectedContinuousEdits()
        withAnimation(.easeInOut(duration: 0.16)) {
            inspectorSelection = selection
            showsInspectorSheet = usesSheet
        }
    }

    private func closeInspector() {
        endSelectedContinuousEdits()
        withAnimation(.easeInOut(duration: 0.16)) {
            inspectorSelection = nil
            showsInspectorSheet = false
        }
    }

    private func endSelectedContinuousEdits() {
        switch inspectorSelection {
        case let .app(identity): store.endContinuousEdits(for: identity)
        case let .output(deviceID): store.endContinuousOutputEQEdits(for: deviceID)
        case nil: break
        }
    }

    private func validateSelection() {
        switch inspectorSelection {
        case let .app(identity) where !store.displayRows.contains(where: { $0.identity == identity }):
            closeInspector()
        case let .output(deviceID) where !store.devices.contains(where: { $0.id == deviceID }):
            closeInspector()
        default:
            break
        }
    }

    private func showInactiveApps() {
        var customization = store.settings.customization
        customization.showInactiveApps = true
        store.applyCustomizationIntent(customization)
    }
}

private struct OutputChannelStrip: View {
    @ObservedObject var store: AudioControlStore
    @ObservedObject var model: OutputChannelModel
    let isSelected: Bool
    let onTune: () -> Void

    private var target: ControlTarget { .outputDevice(model.id) }
    private var presentation: OutputControlPresentation {
        OutputControlPresentation(capabilities: model.capabilities)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Button {
                    store.setDefaultOutputDeviceIntent(model.id)
                } label: {
                    Image(systemName: model.isDefault ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(model.isDefault ? AuralisColor.stageAccent(.process) : Color.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(model.isDefault)
                .help(model.isDefault ? "Current system output" : "Make default output")

                Text(model.name)
                    .font(AuralisTypography.workspaceTitle(14))
                    .lineLimit(1)

                Spacer(minLength: 2)

                if model.isDefault {
                    Text("DEFAULT")
                        .font(AuralisTypography.metric(8))
                        .foregroundStyle(AuralisColor.stageAccent(.process))
                }
            }

            if presentation.showsVolume {
                HStack(spacing: 7) {
                    if presentation.showsMute {
                        Button {
                            _ = store.commandCoordinator.submit(
                                ControlCommand(target: target, mutation: .toggleMute)
                            )
                        } label: {
                            Image(systemName: model.visibleMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .foregroundStyle(model.visibleMuted ? Color.red : Color.primary)
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .disabled(!presentation.enablesMute)
                        .accessibilityLabel(model.visibleMuted ? "Unmute \(model.name)" : "Mute \(model.name)")
                    }

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
                        .frame(width: 34, alignment: .trailing)
                }
            } else {
                Text("Hardware volume unavailable")
                    .font(AuralisTypography.content(.caption2))
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 28)
            }

            Button(action: onTune) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(AuralisColor.peakRose)
                        .frame(width: 7, height: 7)
                    Text(outputEQLabel)
                        .font(AuralisTypography.content(.caption).weight(.medium))
                    Spacer()
                    Image(systemName: "slider.horizontal.3")
                }
                .frame(minHeight: AuralisSpacing.comfortableControlHit)
                .padding(.horizontal, 8)
                .background(AuralisColor.mutedPanel, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Tune Output EQ for \(model.name), \(outputEQLabel)")
        }
        .padding(11)
        .frame(width: 232)
        .background(AuralisColor.panel, in: RoundedRectangle(cornerRadius: AuralisSpacing.panelRadius))
        .overlay {
            RoundedRectangle(cornerRadius: AuralisSpacing.panelRadius)
                .stroke(
                    isSelected
                        ? AuralisColor.peakRose.opacity(0.75)
                        : (model.isDefault ? AuralisColor.signalCyan.opacity(0.5) : AuralisColor.hairline),
                    lineWidth: isSelected ? 2 : 1
                )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(model.name) output channel")
    }

    private var outputEQLabel: String {
        let count = model.visibleEQ.gains.filter { abs($0) >= 0.05 }.count
        return count == 0 ? "Output EQ · Flat" : "Output EQ · \(count) bands"
    }
}

private struct InspectorPlaceholder: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "slider.horizontal.below.square.filled.and.square")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("Select an app or output")
                .font(AuralisTypography.workspaceTitle(17))
            Text("Detailed tuning stays here, so the channel list never jumps or expands.")
                .font(AuralisTypography.content(.caption))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(AuralisColor.mutedPanel.opacity(0.45))
    }
}

private struct AppSignalInspector: View {
    @ObservedObject var store: AudioControlStore
    let row: DisplayableAppRow
    let onClose: () -> Void
    let onTuneOutput: (String) -> Void

    @State private var showsRoutePicker = false

    private var outputs: [AudioDeviceSnapshot] {
        resolvedRouteDevices(route: row.settings.route, devices: store.devices)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                EQBandEditor(store: store, row: row, style: .desktop, onClose: onClose)

                InspectorSection(title: "ROUTING", accent: AuralisColor.signalCyan) {
                    Button { showsRoutePicker = true } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(routeSummary.title)
                                    .font(.callout.weight(.semibold))
                                Text(routeSummary.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.triangle.branch")
                        }
                        .frame(minHeight: 38)
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
                        .frame(width: 370, height: 520)
                    }
                }

                InspectorSection(title: "ROUTED OUTPUTS", accent: AuralisColor.peakRose) {
                    if outputs.isEmpty {
                        Text("No connected destination for this route")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(outputs.enumerated()), id: \.element.id) { index, device in
                            HStack(spacing: 8) {
                                Text(index == 0 && outputs.count > 1 ? "CLOCK" : "OUT \(index + 1)")
                                    .font(AuralisTypography.metric(8))
                                    .foregroundStyle(index == 0 ? AuralisColor.stageAccent(.process) : Color.secondary)
                                    .frame(width: 38, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(device.name).font(.caption.weight(.medium)).lineLimit(1)
                                    Text(outputEQSummary(device.id))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Tune") { onTuneOutput(device.id) }
                                    .controlSize(.small)
                            }
                            .frame(minHeight: 34)
                            if index < outputs.count - 1 { Divider() }
                        }
                    }
                }

                SaveMixPresetButton(store: store)
            }
            .padding(14)
        }
        .background(AuralisColor.mutedPanel.opacity(0.42))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.displayName) Process inspector")
    }

    private var routeSummary: MultiOutputRouteSummary {
        MultiOutputRoutePickerModel.summary(for: row.settings.route, devices: store.devices)
    }

    private func outputEQSummary(_ deviceID: String) -> String {
        let gains = store.settings.deviceSettings[deviceID]?.eq.gains ?? []
        let count = gains.filter { abs($0) >= 0.05 }.count
        return count == 0 ? "Output EQ flat" : "Output EQ · \(count) bands"
    }
}

private struct OutputSignalInspector: View {
    @ObservedObject var store: AudioControlStore
    let device: AudioDeviceSnapshot
    let onClose: () -> Void
    let onTuneApp: (AudioAppIdentity) -> Void

    private var routedApps: [DisplayableAppRow] {
        store.displayRows.filter { route($0.settings.route, contains: device.id, devices: store.devices) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                EQBandEditor(store: store, device: device, style: .desktop, onClose: onClose)

                InspectorSection(title: "DEVICE", accent: AuralisColor.peakRose) {
                    HStack(spacing: 8) {
                        if device.isDefault {
                            Label("System default", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(AuralisColor.stageAccent(.process))
                        } else {
                            Button("Make Default") { store.setDefaultOutputDeviceIntent(device.id) }
                        }
                        Spacer()
                        Text(deviceVolumeLabel)
                            .font(AuralisTypography.metric(10))
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }

                InspectorSection(title: "APPS USING THIS OUTPUT", accent: AuralisColor.signalCyan) {
                    if routedApps.isEmpty {
                        Text("No visible apps are routed here")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(routedApps) { app in
                            Button { onTuneApp(app.identity) } label: {
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
                                .frame(minHeight: 30)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                SaveMixPresetButton(store: store)
            }
            .padding(14)
        }
        .background(AuralisColor.mutedPanel.opacity(0.42))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(device.name) Output inspector")
    }

    private var deviceVolumeLabel: String {
        guard let state = store.deviceVolumeStates[device.id], state.capabilities.canReadVolume else {
            return "Volume unavailable"
        }
        return state.isMuted ? "Muted" : "\(Int((state.volume * 100).rounded()))%"
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    let accent: Color
    @ViewBuilder let content: Content

    init(title: String, accent: Color, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accent = accent
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Capsule().fill(accent).frame(width: 12, height: 3)
                Text(title)
                    .font(AuralisTypography.metric(9))
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(11)
        .background(AuralisColor.panel, in: RoundedRectangle(cornerRadius: AuralisSpacing.panelRadius))
        .overlay {
            RoundedRectangle(cornerRadius: AuralisSpacing.panelRadius)
                .stroke(AuralisColor.hairline)
        }
    }
}

private struct SaveMixPresetButton: View {
    @ObservedObject var store: AudioControlStore
    @State private var showsPrompt = false
    @State private var name = ""

    var body: some View {
        Button {
            name = suggestedName
            showsPrompt = true
        } label: {
            Label("Save app mix + output tuning as preset", systemImage: "square.stack.3d.up")
                .frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.bordered)
        .alert("Save Mix Preset", isPresented: $showsPrompt) {
            TextField("Preset name", text: $name)
            Button("Save") { store.createProfileIntent(named: name, scope: .global) }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves app volume, Process EQ, routes, and the Output EQ for every routed device.")
        }
    }

    private var suggestedName: String {
        "Mix \(store.settings.globalProfilesForDisplay.count + 1)"
    }
}

private func resolvedRouteDevices(
    route: DeviceRoute,
    devices: [AudioDeviceSnapshot]
) -> [AudioDeviceSnapshot] {
    switch route.normalized {
    case .followDefault:
        return devices.filter(\.isDefault)
    case let .selectedDevice(deviceID):
        return devices.filter { $0.id == deviceID }
    case let .multiOutput(deviceIDs):
        let byID = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        return deviceIDs.compactMap { byID[$0] }
    }
}

private func route(
    _ route: DeviceRoute,
    contains deviceID: String,
    devices: [AudioDeviceSnapshot]
) -> Bool {
    resolvedRouteDevices(route: route, devices: devices).contains { $0.id == deviceID }
}
