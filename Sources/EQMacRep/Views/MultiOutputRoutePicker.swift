import SwiftUI

/// Pure draft state used by ``MultiOutputRoutePicker``. Route changes stay here
/// until the user applies them, so checking several devices causes one Core Audio
/// rebuild instead of one rebuild per click.
struct MultiOutputRoutePickerModel: Equatable {
    private(set) var originalRoute: DeviceRoute
    private(set) var draftRoute: DeviceRoute

    init(route: DeviceRoute) {
        let normalizedRoute = route.normalized
        originalRoute = normalizedRoute
        draftRoute = normalizedRoute
    }

    var hasChanges: Bool {
        draftRoute != originalRoute
    }

    var multiOutputDeviceIDs: [String] {
        guard case let .multiOutput(deviceIDs) = draftRoute.normalized else { return [] }
        return deviceIDs
    }

    var selectedDeviceCount: Int {
        multiOutputDeviceIDs.count
    }

    mutating func selectFollowDefault() {
        draftRoute = .followDefault
    }

    mutating func selectSingleDevice(_ deviceID: String) {
        draftRoute = .selectedDevice(deviceID)
    }

    mutating func toggleMultiOutputDevice(_ deviceID: String) {
        guard !deviceID.isEmpty else { return }

        var selectedIDs = multiOutputDeviceIDs
        if let index = selectedIDs.firstIndex(of: deviceID) {
            selectedIDs.remove(at: index)
        } else {
            selectedIDs.append(deviceID)
        }
        draftRoute = DeviceRoute.multiOutput(selectedIDs).normalized
    }

    func multiOutputSelectionIndex(for deviceID: String) -> Int? {
        multiOutputDeviceIDs.firstIndex(of: deviceID)
    }

    func missingMultiOutputDeviceIDs(devices: [AudioDeviceSnapshot]) -> [String] {
        let availableIDs = Set(Self.uniqueDevices(devices).map(\.id))
        return multiOutputDeviceIDs.filter { !availableIDs.contains($0) }
    }

    func summary(devices: [AudioDeviceSnapshot]) -> MultiOutputRouteSummary {
        Self.summary(for: draftRoute, devices: devices)
    }

    static func summary(
        for route: DeviceRoute,
        devices: [AudioDeviceSnapshot]
    ) -> MultiOutputRouteSummary {
        let uniqueDevices = uniqueDevices(devices)
        let namesByID = Dictionary(uniqueKeysWithValues: uniqueDevices.map { ($0.id, $0.name) })

        switch route.normalized {
        case .followDefault:
            let defaultName = uniqueDevices.first(where: \.isDefault)?.name ?? "System Output"
            return MultiOutputRouteSummary(
                title: defaultName,
                detail: "Follow Default (\(defaultName))",
                selectedCount: 0,
                missingCount: 0,
                isMultiOutput: false,
                accessibilityValue: "Follow Default, \(defaultName)"
            )
        case let .selectedDevice(deviceID):
            let name = namesByID[deviceID]
            let isMissing = name == nil
            return MultiOutputRouteSummary(
                title: name ?? "Missing Device",
                detail: name ?? "Missing Device",
                selectedCount: 1,
                missingCount: isMissing ? 1 : 0,
                isMultiOutput: false,
                accessibilityValue: isMissing ? "Selected output is missing" : "Single output, \(name!)"
            )
        case let .multiOutput(deviceIDs):
            let missingCount = deviceIDs.reduce(into: 0) { count, deviceID in
                if namesByID[deviceID] == nil { count += 1 }
            }
            let count = deviceIDs.count
            let outputWord = count == 1 ? "Output" : "Outputs"
            let deviceWord = count == 1 ? "device" : "devices"
            let missingDetail = missingCount == 0 ? "" : " · \(missingCount) missing"
            let missingAccessibility = missingCount == 0 ? "" : ", \(missingCount) missing"
            return MultiOutputRouteSummary(
                title: "\(count) \(outputWord)",
                detail: "Multi-Output (\(count) \(deviceWord))\(missingDetail)",
                selectedCount: count,
                missingCount: missingCount,
                isMultiOutput: true,
                accessibilityValue: "Multi-Output, \(count) \(outputWord.lowercased())\(missingAccessibility)"
            )
        }
    }

    static func uniqueDevices(_ devices: [AudioDeviceSnapshot]) -> [AudioDeviceSnapshot] {
        var seen = Set<String>()
        return devices.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
    }
}

struct MultiOutputRouteSummary: Equatable {
    let title: String
    let detail: String
    let selectedCount: Int
    let missingCount: Int
    let isMultiOutput: Bool
    let accessibilityValue: String
}

/// Popover content for choosing an app's route. All choices are staged and a
/// single Apply/Done action commits the resulting route.
struct MultiOutputRoutePicker: View {
    let route: DeviceRoute
    let devices: [AudioDeviceSnapshot]
    let onApply: (DeviceRoute) -> Void
    let onDismiss: () -> Void

    @State private var model: MultiOutputRoutePickerModel

    init(
        route: DeviceRoute,
        devices: [AudioDeviceSnapshot],
        onApply: @escaping (DeviceRoute) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.route = route
        self.devices = devices
        self.onApply = onApply
        self.onDismiss = onDismiss
        _model = State(initialValue: MultiOutputRoutePickerModel(route: route))
    }

    private var availableDevices: [AudioDeviceSnapshot] {
        MultiOutputRoutePickerModel.uniqueDevices(devices)
    }

    private var missingDeviceIDs: [String] {
        model.missingMultiOutputDeviceIDs(devices: availableDevices)
    }

    private var missingSingleDeviceID: String? {
        guard case let .selectedDevice(deviceID) = model.draftRoute,
              !availableDevices.contains(where: { $0.id == deviceID }) else {
            return nil
        }
        return deviceID
    }

    private var summary: MultiOutputRouteSummary {
        model.summary(devices: availableDevices)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Output Route")
                    .font(.headline)
                Spacer()
                if summary.isMultiOutput {
                    countBadge(summary.selectedCount)
                }
                if summary.missingCount > 0 {
                    missingBadge(summary.missingCount)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    routeChoice(
                        title: "Follow Default",
                        subtitle: availableDevices.first(where: \.isDefault)?.name ?? "System Output",
                        isSelected: model.draftRoute == .followDefault
                    ) {
                        model.selectFollowDefault()
                    }

                    sectionLabel("Single Output")
                    ForEach(availableDevices) { device in
                        routeChoice(
                            title: device.name,
                            subtitle: device.isDefault ? "System default" : nil,
                            isSelected: model.draftRoute == .selectedDevice(device.id)
                        ) {
                            model.selectSingleDevice(device.id)
                        }
                    }
                    if let missingSingleDeviceID {
                        routeChoice(
                            title: "Missing Device",
                            subtitle: missingSingleDeviceID,
                            isSelected: true
                        ) {
                            model.selectSingleDevice(missingSingleDeviceID)
                        }
                    }

                    Divider()
                        .padding(.vertical, 4)

                    HStack(spacing: 6) {
                        sectionLabel("Multi-Output")
                        Spacer()
                        if model.selectedDeviceCount > 0 {
                            countBadge(model.selectedDeviceCount)
                        }
                        if !missingDeviceIDs.isEmpty {
                            missingBadge(missingDeviceIDs.count)
                        }
                    }

                    Text("Select outputs in clock priority order. Changes apply together.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(availableDevices) { device in
                        multiOutputChoice(
                            title: device.name,
                            subtitle: device.isDefault ? "System default" : nil,
                            deviceID: device.id,
                            isMissing: false
                        )
                    }

                    ForEach(missingDeviceIDs, id: \.self) { deviceID in
                        multiOutputChoice(
                            title: "Missing Device",
                            subtitle: deviceID,
                            deviceID: deviceID,
                            isMissing: true
                        )
                    }

                    if availableDevices.isEmpty && missingDeviceIDs.isEmpty {
                        Text("No output devices available")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    }
                }
            }
            .frame(maxHeight: 330)

            Divider()

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.detail)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    if summary.missingCount > 0 {
                        Text("Unavailable outputs will be skipped")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(model.hasChanges ? "Apply" : "Done") {
                    if model.hasChanges {
                        onApply(model.draftRoute.normalized)
                    }
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .help(model.hasChanges ? "Apply this output route" : "Close output picker")
            }
        }
        .padding(12)
        .frame(width: 300)
        .onChange(of: route) { _, newRoute in
            model = MultiOutputRoutePickerModel(route: newRoute)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Output route picker")
    }

    private func routeChoice(
        title: String,
        subtitle: String?,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                routeText(title: title, subtitle: subtitle)
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .background(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private func multiOutputChoice(
        title: String,
        subtitle: String?,
        deviceID: String,
        isMissing: Bool
    ) -> some View {
        let selectionIndex = model.multiOutputSelectionIndex(for: deviceID)
        let isSelected = selectionIndex != nil

        return Button {
            model.toggleMultiOutputDevice(deviceID)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isMissing ? Color.orange : (isSelected ? Color.accentColor : Color.secondary))
                    .frame(width: 16)
                    .accessibilityHidden(true)
                routeText(title: title, subtitle: subtitle)
                Spacer(minLength: 4)
                if isMissing {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                }
                if let selectionIndex {
                    Text("\(selectionIndex + 1)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Color.secondary.opacity(0.12), in: Circle())
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(multiOutputAccessibilityValue(
            selectionIndex: selectionIndex,
            isMissing: isMissing
        ))
        .help(isMissing ? "Remove this unavailable output from the route" : "Add or remove this output")
    }

    private func routeText(title: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption)
                .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.top, 4)
    }

    private func countBadge(_ count: Int) -> some View {
        Text("\(count)")
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12), in: Capsule())
            .accessibilityLabel("\(count) selected")
    }

    private func missingBadge(_ count: Int) -> some View {
        Label("\(count) missing", systemImage: "exclamationmark.triangle.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.10), in: Capsule())
    }

    private func multiOutputAccessibilityValue(
        selectionIndex: Int?,
        isMissing: Bool
    ) -> String {
        var parts = [selectionIndex.map { "Selected, priority \($0 + 1)" } ?? "Not selected"]
        if isMissing { parts.append("Missing") }
        return parts.joined(separator: ", ")
    }
}
