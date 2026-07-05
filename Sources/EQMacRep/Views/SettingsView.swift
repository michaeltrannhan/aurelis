import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: AudioControlStore

    var body: some View {
        Form {
            Section("Backend") {
                Picker("Backend Mode", selection: customizationBinding(\.backendMode)) {
                    ForEach(BackendMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Text("CoreAudio Discovery lists real apps and output devices. Volume, mute, and boost require Screen & System Audio Recording permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Appearance", selection: customizationBinding(\.appearance)) {
                ForEach(AppAppearance.allCases) { appearance in
                    Text(appearance.label).tag(appearance)
                }
            }

            Picker("Popup Density", selection: customizationBinding(\.popupDensity)) {
                ForEach(PopupDensity.allCases) { density in
                    Text(density.label).tag(density)
                }
            }

            Slider(
                value: customizationBinding(\.defaultNewAppVolume),
                in: 0...1,
                step: 0.01
            ) {
                Text("Default New-App Volume")
            } minimumValueLabel: {
                Text("0")
            } maximumValueLabel: {
                Text("100")
            }

            Picker("EQ Gain Range", selection: customizationBinding(\.eqGainRange)) {
                ForEach(EQGainRange.allCases) { range in
                    Text(range.label).tag(range)
                }
            }

            Picker("Volume Step", selection: customizationBinding(\.volumeStep)) {
                ForEach(VolumeStep.allCases) { step in
                    Text(step.label).tag(step)
                }
            }

            Toggle("Show Inactive Apps", isOn: customizationBinding(\.showInactiveApps))

            Button("Reset Settings", role: .destructive) {
                try? store.reset()
                try? store.refresh()
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func customizationBinding<Value>(_ keyPath: WritableKeyPath<AppCustomization, Value>) -> Binding<Value> {
        Binding(
            get: { store.settings.customization[keyPath: keyPath] },
            set: { newValue in
                var customization = store.settings.customization
                customization[keyPath: keyPath] = newValue
                try? store.applyCustomization(customization)
            }
        )
    }
}
