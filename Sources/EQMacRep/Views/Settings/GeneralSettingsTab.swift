import SwiftUI

struct GeneralSettingsTab: View {
    @ObservedObject var store: AudioControlStore
    @State private var confirmsReset = false

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
                    confirmsReset = true
                }
                settingsHelper("Clears app volume, mute, boost, EQ, pinned apps, ignored apps, order, and customization.")
            }

            if !store.settings.ignoredAppIDs.isEmpty {
                Section("Ignored Apps") {
                    ForEach(store.settings.ignoredAppIDs.sorted(by: { ignoredName($0) < ignoredName($1) })) { identity in
                        HStack {
                            Text(ignoredName(identity))
                            Spacer()
                            Button("Restore") { store.unignoreIntent(identity) }
                        }
                    }
                    Button("Restore All") {
                        for identity in store.settings.ignoredAppIDs { store.unignoreIntent(identity) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .confirmationDialog("Reset all EQMacRep settings?", isPresented: $confirmsReset) {
            Button("Reset All Settings", role: .destructive) { store.resetIntent() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears every per-app control and customization. This action cannot be undone.")
        }
    }

    private func ignoredName(_ identity: AudioAppIdentity) -> String {
        store.settings.appSettings[identity]?.displayName ?? identity.rawValue
    }
}
