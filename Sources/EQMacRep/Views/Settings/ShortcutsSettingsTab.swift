import SwiftUI

struct ShortcutsSettingsTab: View {
    @ObservedObject var store: AudioControlStore

    var body: some View {
        Form {
            Section("Volume") {
                Picker("Volume step", selection: settingsCustomizationBinding(store: store, \.volumeStep)) {
                    ForEach(VolumeStep.allCases) { step in
                        Text(step.label).tag(step)
                    }
                }
                settingsHelper("Step size for scroll-wheel, media-key, and hotkey volume changes.")
            }

            Section("External Controls") {
                Toggle("Media keys control target app", isOn: settingsCustomizationBinding(store: store, \.mediaKeysEnabled))
                Toggle("Global hotkeys", isOn: settingsCustomizationBinding(store: store, \.hotkeysEnabled))
                settingsHelper("Media keys need Accessibility permission. Hotkeys default to Option+Command+Up/Down/M and Option+Command+Space to toggle the popup.")
            }

            Section("Display") {
                Picker("Volume HUD", selection: settingsCustomizationBinding(store: store, \.hudStyle)) {
                    ForEach(HUDStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                Picker("Menu bar icon", selection: settingsCustomizationBinding(store: store, \.menuBarIconStyle)) {
                    ForEach(MenuBarIconStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}
