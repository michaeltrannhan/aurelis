import SwiftUI

@main
struct EQMacRepApp: App {
    @StateObject private var store: AudioControlStore

    init() {
        let settingsStore = SettingsStore()
        let backend = MockAudioBackend()
        let controlStore = (try? AudioControlStore(settingsStore: settingsStore, backend: backend))
            ?? (try! AudioControlStore(settingsStore: SettingsStore(settingsURL: FileManager.default.temporaryDirectory.appendingPathComponent("eqmacrep-fallback.json")), backend: backend))
        _store = StateObject(wrappedValue: controlStore)
    }

    var body: some Scene {
        MenuBarExtra("EQMacRep", systemImage: "slider.horizontal.3") {
            MenuBarRootView(store: store)
                .task {
                    try? store.refresh()
                }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store)
        }
    }
}
