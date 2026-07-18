import SwiftUI

/// Compatibility wrapper. Settings UI now lives in the tabbed `SettingsRootView`.
struct SettingsView: View {
    @ObservedObject var store: AudioControlStore

    var body: some View {
        SettingsRootView(store: store)
    }
}
