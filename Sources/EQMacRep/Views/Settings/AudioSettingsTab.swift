import SwiftUI

struct AudioSettingsTab: View {
    @ObservedObject var store: AudioControlStore

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
