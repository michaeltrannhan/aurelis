import SwiftUI

enum ProfileManagementLayout {
    case settings
    case popover
}

/// Device-first audio context management shared by Settings and the main
/// window popover. Contexts save automatically; presets are detached templates.
struct ProfileManagementSection: View {
    @ObservedObject var store: AudioControlStore
    var layout: ProfileManagementLayout = .settings

    @State private var newPresetName = ""
    @State private var pendingAction: DestructiveAction?
    @State private var pendingPresetDeleteID: UUID?
    @State private var isCreatingPreset = false
    @State private var creationErrorMessage: String?

    private enum DestructiveAction {
        case reset(AudioDeviceSnapshot)
        case forget(AudioDeviceSnapshot)

        var output: AudioDeviceSnapshot {
            switch self {
            case let .reset(output), let .forget(output): output
            }
        }
    }

    @ViewBuilder
    var body: some View {
        switch layout {
        case .settings:
            Section("Audio Contexts & Presets") { sectionContent }
        case .popover:
            Section { sectionContent }
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        if let current = store.currentOutput {
            currentOutputCard(current)
        } else {
            emptyCurrentOutputCard
        }

        VStack(alignment: .leading, spacing: 3) {
            Label("Remembered Outputs", systemImage: "hifispeaker.2.fill")
                .font(.headline)
            settingsHelper(
                "Every output saves app routing, volume, boost, Process EQ, and its physical-device Output EQ automatically."
            )
        }

        if managedOutputs.isEmpty {
            settingsHelper("Connect an audio output to create its automatic context.")
        } else {
            ForEach(managedOutputs) { output in
                deviceContextRow(output)
            }
        }

        Divider()

        VStack(alignment: .leading, spacing: 3) {
            Label("Preset Library", systemImage: "square.stack.3d.up.fill")
                .font(.headline)
            settingsHelper(
                "Presets capture the app mix and Output EQ for every routed device. Applying one makes an independent copy."
            )
        }

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("New preset name", text: $newPresetName)
                    .onSubmit(createPreset)
                    .disabled(isCreatingPreset)
                    .accessibilityIdentifier("auralis.profiles.new-preset-name")
                Button(action: createPreset) {
                    if isCreatingPreset {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Save Current as Preset")
                    }
                }
                .disabled(!canCreatePreset || store.currentOutput == nil || isCreatingPreset)
                .accessibilityIdentifier("auralis.profiles.save-preset")
            }
            if let creationErrorMessage {
                Text(creationErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }

        if presets.isEmpty {
            settingsHelper("Save the current device mix when you want to reuse it elsewhere.")
        } else {
            ForEach(presets) { preset in
                presetRow(preset)
            }
        }
    }

    private func currentOutputCard(_ output: AudioDeviceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color.accentColor.opacity(0.14))
                    Image(systemName: "hifispeaker.fill")
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(output.name)
                            .font(.headline)
                            .lineLimit(1)
                        statusPill("Current", tint: .accentColor)
                    }
                    Text(currentStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                OutputPresetAssignmentMenu(
                    store: store,
                    output: output,
                    configuration: store.currentDeviceContext,
                    title: "Apply Preset"
                )
                .controlSize(.small)
            }

            HStack(spacing: 6) {
                Image(systemName: "checkmark.icloud.fill")
                    .foregroundStyle(Color.green)
                Text("Changes save automatically to this output")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor.opacity(0.22), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("auralis.profiles.current-output")
    }

    private var emptyCurrentOutputCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.slash")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("No Current Output")
                    .font(.headline)
                Text("Auralis will create a neutral context when an output appears.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private func deviceContextRow(_ output: AudioDeviceSnapshot) -> some View {
        let isAvailable = store.devices.contains { $0.id == output.id }
        let isCurrent = output.id == store.currentOutput?.id
        let context = store.outputConfiguration(for: output.id)
        let matchingPreset = context.flatMap(matchingPreset)

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Image(systemName: isCurrent ? "checkmark.circle.fill" : "hifispeaker")
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(output.name).lineLimit(1)
                        if isCurrent {
                            statusPill("Current", tint: .accentColor)
                        } else if !isAvailable {
                            statusPill("Disconnected", tint: .secondary)
                        }
                    }
                    Text(contextSummary(context, matchingPreset: matchingPreset))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                if isAvailable && !isCurrent {
                    Button("Make Current") {
                        store.setDefaultOutputDeviceIntent(output.id)
                    }
                    .help("Switch macOS and Auralis to \(output.name)")
                }
                if isAvailable {
                    OutputPresetAssignmentMenu(
                        store: store,
                        output: output,
                        configuration: context,
                        title: "Apply Preset"
                    )
                }
                Button(role: .destructive) {
                    pendingAction = isAvailable ? .reset(output) : .forget(output)
                } label: {
                    Label(
                        isAvailable ? "Reset to Neutral" : "Forget",
                        systemImage: isAvailable ? "arrow.counterclockwise" : "trash"
                    )
                }
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            .padding(.leading, 28)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("auralis.profiles.device.\(output.id)")
        .confirmationDialog(
            destructiveTitle,
            isPresented: Binding(
                get: { pendingAction?.output.id == output.id },
                set: { if !$0 { pendingAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(destructiveButtonTitle, role: .destructive) {
                store.removeOutputConfigurationIntent(deviceID: output.id)
                pendingAction = nil
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: {
            Text(destructiveMessage)
        }
    }

    private func presetRow(_ preset: AudioProfile) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name).lineLimit(1)
                Text(presetSummary(preset))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Apply to Current") {
                store.applyProfileIntent(preset.id)
            }
            .disabled(store.currentOutput == nil)
            Button("Update") {
                store.updateProfileIntent(preset.id)
            }
            .help("Update \(preset.name) from the current app mix and routed Output EQs")
            Button(role: .destructive) {
                pendingPresetDeleteID = preset.id
            } label: {
                Image(systemName: "trash")
            }
            .help("Delete \(preset.name)")
        }
        .confirmationDialog(
            "Delete \(preset.name)?",
            isPresented: Binding(
                get: { pendingPresetDeleteID == preset.id },
                set: { if !$0 { pendingPresetDeleteID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Preset", role: .destructive) {
                store.deleteProfileIntent(preset.id)
                pendingPresetDeleteID = nil
            }
            Button("Cancel", role: .cancel) { pendingPresetDeleteID = nil }
        } message: {
            Text("Output contexts already copied from this preset will stay unchanged.")
        }
    }

    private var canCreatePreset: Bool {
        !newPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var presets: [AudioProfile] {
        store.settings.globalProfilesForDisplay
    }

    private var managedOutputs: [AudioDeviceSnapshot] {
        var outputsByID = Dictionary(
            store.devices.map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        for context in store.settings.deviceContextsForDisplay {
            guard let outputID = context.scope.outputDeviceID,
                  outputsByID[outputID] == nil else { continue }
            let name = context.deviceSettings[outputID]?.displayName ?? context.name
            outputsByID[outputID] = AudioDeviceSnapshot(id: outputID, name: name)
        }
        return outputsByID.values.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            let lhsAvailable = store.devices.contains { $0.id == lhs.id }
            let rhsAvailable = store.devices.contains { $0.id == rhs.id }
            if lhsAvailable != rhsAvailable { return lhsAvailable }
            return StableDisplayOrder.precedes(
                lhsName: lhs.name,
                lhsID: lhs.id,
                rhsName: rhs.name,
                rhsID: rhs.id
            )
        }
    }

    private var currentStatusText: String {
        switch store.contextSwitchState {
        case .detecting:
            return "Detecting output…"
        case let .applied(_, name):
            return "Context applied to \(name)"
        case let .failed(message):
            return "Refresh failed · \(message)"
        case .idle:
            return "Context active"
        }
    }

    private var destructiveTitle: String {
        guard let action = pendingAction else { return "Change audio context?" }
        switch action {
        case let .reset(output): return "Reset \(output.name)?"
        case let .forget(output): return "Forget \(output.name)?"
        }
    }

    private var destructiveButtonTitle: String {
        guard let action = pendingAction else { return "Continue" }
        switch action {
        case .reset: return "Reset to Neutral"
        case .forget: return "Forget Output"
        }
    }

    private var destructiveMessage: String {
        guard let action = pendingAction else { return "" }
        switch action {
        case .reset:
            return "Routing, app volume, boost, Process EQ, and Output EQ will return to safe neutral values."
        case .forget:
            return "Its saved context will be removed. A new neutral context will be created if it reconnects."
        }
    }

    private func matchingPreset(for context: AudioProfile) -> AudioProfile? {
        presets.first { context.matchesMixerPreset($0) }
    }

    private func presetSummary(_ preset: AudioProfile) -> String {
        let appCount = preset.appSettings.count
        let outputCount = preset.deviceSettings.count
        let appWord = appCount == 1 ? "app" : "apps"
        let outputWord = outputCount == 1 ? "output EQ" : "output EQs"
        return "\(appCount) \(appWord) · \(outputCount) \(outputWord)"
    }

    private func contextSummary(
        _ context: AudioProfile?,
        matchingPreset: AudioProfile?
    ) -> String {
        guard let context else { return "Neutral context will be created on connection" }
        if let matchingPreset {
            return "Preset · \(matchingPreset.name) · autosaved"
        }
        return "Custom mix · \(context.appSettings.count) apps · \(context.deviceSettings.count) output EQs · autosaved"
    }

    private func statusPill(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.1), in: Capsule())
    }

    private func createPreset() {
        guard canCreatePreset, !isCreatingPreset else { return }
        let name = newPresetName
        creationErrorMessage = nil
        isCreatingPreset = true
        Task { @MainActor in
            do {
                _ = try await store.createProfile(named: name, scope: .global)
                newPresetName = ""
            } catch {
                creationErrorMessage = "Couldn’t save the preset. Your name and current mix are unchanged."
            }
            isCreatingPreset = false
        }
    }
}
