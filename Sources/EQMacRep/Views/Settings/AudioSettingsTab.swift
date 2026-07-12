import SwiftUI

struct AudioSettingsTab: View {
    @ObservedObject var store: AudioControlStore

    var body: some View {
        Form {
            Section("Audio Engine") {
                Picker("Backend", selection: settingsCustomizationBinding(store: store, \.backendMode)) {
                    ForEach(BackendMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                settingsHelper("CoreAudio Discovery lists real apps and output devices. Realtime controls require Screen & System Audio Recording permission.")
            }

            Section("Permissions") {
                Label(store.permissionState.summary, systemImage: store.permissionState.allowsProcessTaps ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(store.permissionState.allowsProcessTaps ? .green : .orange)
                HStack {
                    Button("Request Screen & System Audio Recording") {
                        store.requestAudioCapturePermission()
                    }
                    Button("Open Privacy Settings") {
                        store.openAudioCapturePrivacySettings()
                    }
                }
                settingsHelper("Process taps only run when this shows ready. Without permission, EQMacRep stays in discovery-only mode.")
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
        }
        .formStyle(.grouped)
        .padding(20)
    }
}
