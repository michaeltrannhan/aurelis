import SwiftUI

struct ShortcutsSettingsTab: View {
    @ObservedObject var store: AudioControlStore
    @EnvironmentObject private var controls: ExternalControlsCoordinator

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
                LabeledContent("Accessibility") {
                    Label(
                        controls.accessibilityTrusted ? "Granted" : "Not Granted",
                        systemImage: controls.accessibilityTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(controls.accessibilityTrusted ? Color.green : Color.orange)
                }
                HStack {
                    Button("Request Accessibility") {
                        controls.requestAccessibilityAccess()
                    }
                    .disabled(controls.accessibilityTrusted)
                    Button("Open Accessibility Settings") {
                        controls.openAccessibilitySettings()
                    }
                }
                settingsHelper("Media keys need Accessibility permission. Hotkeys default to Option+Command+Up/Down/M and Option+Command+Space to show the mixer.")
            }

            Section("Display") {
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
