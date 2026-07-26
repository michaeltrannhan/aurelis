import SwiftUI

struct AudioSettingsTab: View {
    @ObservedObject var store: AudioControlStore
    @State private var newProfileName = ""

    var body: some View {
        Form {
            Section("Audio Engine") {
#if DEBUG
                Picker("Backend", selection: settingsCustomizationBinding(store: store, \.backendMode)) {
                    ForEach(BackendMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
#else
                LabeledContent("Backend", value: "CoreAudio")
#endif
                settingsHelper("CoreAudio Discovery lists real apps and output devices. Realtime controls require Screen & System Audio Recording permission.")
            }

            Section("Permissions") {
                PermissionStatusView(store: store)
                    .listRowInsets(EdgeInsets())
                settingsHelper("Process taps only run when this shows ready. Without permission, Auralis stays in discovery-only mode.")
            }

            Section("Defaults") {
                Slider(
                    value: settingsCustomizationBinding(store: store, \.defaultNewAppVolume),
                    in: 0...1,
                    step: 0.01
                ) {
                    Text("New app volume")
                } minimumValueLabel: {
                    Text("0")
                } maximumValueLabel: {
                    Text("100")
                }

                Picker("EQ range", selection: settingsCustomizationBinding(store: store, \.eqGainRange)) {
                    ForEach(EQGainRange.allCases) { range in
                        Text(range.label).tag(range)
                    }
                }
                settingsHelper("Changing EQ range reclamps existing per-app EQ curves to the selected dB limit.")
            }

            Section("Audio Profiles") {
                HStack {
                    TextField("New profile name", text: $newProfileName)
                    Button("Save Current") {
                        let name = newProfileName
                        newProfileName = ""
                        store.createProfileIntent(named: name)
                    }
                    .disabled(newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if store.settings.profiles.isEmpty {
                    settingsHelper("Profiles capture app controls, per-device volume and mute, plus your preferred output.")
                } else {
                    ForEach(store.settings.profiles) { profile in
                        HStack(spacing: 10) {
                            Image(systemName: profile.id == store.settings.activeProfileID
                                ? "checkmark.circle.fill"
                                : "circle")
                                .foregroundStyle(profile.id == store.settings.activeProfileID ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name)
                                Text("\(profile.appSettings.count) apps · \(profile.deviceSettings.count) devices")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Apply") { store.applyProfileIntent(profile.id) }
                            Button("Update") { store.updateProfileIntent(profile.id) }
                            Button(role: .destructive) {
                                store.deleteProfileIntent(profile.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .help("Delete \(profile.name)")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}
