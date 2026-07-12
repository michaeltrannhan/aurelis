import SwiftUI

struct AboutSettingsTab: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("EQMacRep")
                        .font(.title2.weight(.semibold))
                    Text("Version \(version)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Per-app volume, mute, boost, and realtime 10-band EQ for macOS using Core Audio process taps.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Reference") {
                Link("FineTune (parity reference)", destination: URL(string: "https://github.com/ronitsingh10/FineTune")!)
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}
