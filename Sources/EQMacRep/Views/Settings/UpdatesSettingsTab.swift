import SwiftUI

struct UpdatesSettingsTab: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    var body: some View {
        Form {
            Section("Version") {
                LabeledContent("Current version", value: version)
                settingsHelper("Automatic updates arrive with the signed release build (Phase 13). For now, pull the latest source and rebuild.")
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}
