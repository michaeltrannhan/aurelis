import SwiftUI

struct ProfileMenuButton: View {
    @ObservedObject var store: AudioControlStore
    var compact = false

    @State private var isCreatingGlobalProfile = false
    @State private var isShowingProfilePanel = false
    @State private var profileName = ""

    @ViewBuilder
    var body: some View {
        if compact {
            compactMenu
        } else {
            windowButton
        }
    }

    private var compactMenu: some View {
        Menu {
            if !globalProfiles.isEmpty {
                Section("Apply Preset to Current Output") {
                    ForEach(globalProfiles) { profile in globalProfileButton(profile) }
                }
            }

            if let currentOutput {
                Section(currentOutput.name) {
                    Label("Device context · autosaved", systemImage: "checkmark.icloud.fill")
                    presetAssignmentMenu(for: currentOutput)
                    Button(role: .destructive) {
                        store.removeOutputConfigurationIntent(deviceID: currentOutput.id)
                    } label: {
                        Label("Reset to Neutral", systemImage: "arrow.counterclockwise")
                    }
                }
            }

            Divider()

            Button {
                profileName = suggestedProfileName
                isCreatingGlobalProfile = true
            } label: {
                Label("Save Current as Preset…", systemImage: "plus.circle")
            }
        } label: {
            Image(systemName: "square.stack.3d.up.fill")
                .frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .help("Device contexts and presets")
        .accessibilityLabel("Device contexts and presets")
        .alert("Save Current as Preset", isPresented: $isCreatingGlobalProfile) {
            TextField("Profile name", text: $profileName)
            Button("Save") {
                store.createProfileIntent(
                    named: profileName,
                    scope: .global
                )
            }
            .disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The preset is a reusable copy. Later changes remain local to each output.")
        }
    }

    private var windowButton: some View {
        Button {
            isShowingProfilePanel.toggle()
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.accentColor.opacity(0.13))
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text(profileButtonTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(profileButtonSubtitle)
                        .font(.caption2)
                        .foregroundStyle(
                            store.settings.profileHasOverrides
                                ? Color.orange
                                : Color.secondary
                        )
                        .lineLimit(1)
                }

                Spacer(minLength: 2)

                Image(systemName: isShowingProfilePanel ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .frame(height: 40)
            .contentShape(Rectangle())
            .background(
                Color(nsColor: .controlBackgroundColor).opacity(0.72),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(
                        isShowingProfilePanel
                            ? Color.accentColor.opacity(0.42)
                            : Color.secondary.opacity(0.16),
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .help("Manage device contexts and presets")
        .accessibilityLabel("Device contexts and presets")
        .accessibilityValue(profileButtonTitle)
        .accessibilityIdentifier("auralis.main.profiles")
        .popover(isPresented: $isShowingProfilePanel, arrowEdge: .bottom) {
            ProfileManagementPopover(
                store: store,
                onClose: { isShowingProfilePanel = false }
            )
        }
    }

    private var globalProfiles: [AudioProfile] {
        store.settings.globalProfilesForDisplay
    }

    private var profileButtonTitle: String {
        currentOutput?.name ?? "No Audio Output"
    }

    private var profileButtonSubtitle: String {
        switch store.contextSwitchState {
        case .detecting: return "Detecting output…"
        case .failed: return "Refresh needed"
        case .applied, .idle: return "Device context · autosaved"
        }
    }

    private var currentOutput: AudioDeviceSnapshot? {
        store.devices.first(where: \.isDefault)
    }

    private var currentOutputConfiguration: AudioProfile? {
        currentOutput.flatMap { store.outputConfiguration(for: $0.id) }
    }

    private func globalProfileButton(_ profile: AudioProfile) -> some View {
        return Button {
            store.applyProfileIntent(profile.id)
        } label: {
            Label(profile.name, systemImage: "square.stack.3d.up")
        }
    }

    @ViewBuilder
    private func presetAssignmentMenu(for output: AudioDeviceSnapshot) -> some View {
        OutputPresetAssignmentMenu(
            store: store,
            output: output,
            configuration: currentOutputConfiguration,
            title: "Choose Output Preset"
        )
    }

    private var suggestedProfileName: String {
        let existing = Set(globalProfiles.map { $0.name.lowercased() })
        for candidate in ["Default", "Focus", "Calls", "Preset"]
        where !existing.contains(candidate.lowercased()) {
            return candidate
        }
        return "Preset \(globalProfiles.count + 1)"
    }
}

struct OutputPresetAssignmentMenu: View {
    @ObservedObject var store: AudioControlStore
    let output: AudioDeviceSnapshot
    let configuration: AudioProfile?
    let title: String

    @ViewBuilder
    var body: some View {
        if !presets.isEmpty {
            Menu {
                ForEach(presets) { preset in
                    Button {
                        store.assignPresetToOutputIntent(
                            profileID: preset.id,
                            deviceID: output.id,
                            deviceName: output.name
                        )
                    } label: {
                        Label(
                            preset.name,
                            systemImage: configuration?.matchesMixerPreset(preset) == true
                                ? "checkmark.circle.fill"
                                : "square.stack.3d.up"
                        )
                    }
                }
            } label: {
                Label(title, systemImage: "slider.horizontal.3")
            }
        }
    }

    private var presets: [AudioProfile] {
        store.settings.globalProfilesForDisplay
    }
}

struct ProfileManagementPopover: View {
    @ObservedObject var store: AudioControlStore
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor.opacity(0.13))
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Audio Contexts & Presets")
                        .font(.headline)
                    Text("Every output remembers its own mix automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close")
                .accessibilityLabel("Close profiles")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            Form {
                ProfileManagementSection(store: store, layout: .popover)
            }
            .formStyle(.grouped)
        }
        .frame(width: 560, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("auralis.profile.management")
    }
}
