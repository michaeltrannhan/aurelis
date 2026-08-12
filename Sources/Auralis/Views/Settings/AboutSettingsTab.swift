import SwiftUI

struct AboutSettingsTab: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.8"
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Auralis")
                        .font(.title2.weight(.semibold))
                    Text("Version \(version)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Per-app volume, mute, boost, and Process EQ, plus per-device Output EQ, using Core Audio process taps.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Reference") {
                Link("FineTune (parity reference)", destination: AuralisURL.fineTuneRepository)
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}
