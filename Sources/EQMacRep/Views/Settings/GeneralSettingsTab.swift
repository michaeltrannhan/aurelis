import SwiftUI

struct GeneralSettingsTab: View {
    @ObservedObject var store: AudioControlStore

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: settingsCustomizationBinding(store: store, \.appearance)) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.label).tag(appearance)
                    }
                }

                Picker("Popup density", selection: settingsCustomizationBinding(store: store, \.popupDensity)) {
                    ForEach(PopupDensity.allCases) { density in
                        Text(density.label).tag(density)
                    }
                }

                Toggle("Show inactive apps", isOn: settingsCustomizationBinding(store: store, \.showInactiveApps))
            }

            Section("Maintenance") {
                Button("Reset All Settings", role: .destructive) {
                    try? store.reset()
                    try? store.refresh()
                }
                settingsHelper("Clears app volume, mute, boost, EQ, pinned apps, ignored apps, order, and customization.")
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}
