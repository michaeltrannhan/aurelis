import SwiftUI

/// Tabbed settings root. Updates returns only when a real updater exists.
struct SettingsRootView: View {
    @ObservedObject var store: AudioControlStore
    @State private var selection: SettingsTab = .general

    var body: some View {
        TabView(selection: $selection) {
            GeneralSettingsTab(store: store)
                .tabItem { Label(SettingsTab.general.label, systemImage: SettingsTab.general.systemImage) }
                .tag(SettingsTab.general)
            AudioSettingsTab(store: store)
                .tabItem { Label(SettingsTab.audio.label, systemImage: SettingsTab.audio.systemImage) }
                .tag(SettingsTab.audio)
            ShortcutsSettingsTab(store: store)
                .tabItem { Label(SettingsTab.shortcuts.label, systemImage: SettingsTab.shortcuts.systemImage) }
                .tag(SettingsTab.shortcuts)
            AboutSettingsTab()
                .tabItem { Label(SettingsTab.about.label, systemImage: SettingsTab.about.systemImage) }
                .tag(SettingsTab.about)
        }
        .frame(width: 720, height: 560)
        .preferredColorScheme(store.settings.customization.appearance.colorScheme)
    }
}
