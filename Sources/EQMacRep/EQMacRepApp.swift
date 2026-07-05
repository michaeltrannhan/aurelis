import SwiftUI

@main
struct EQMacRepApp: App {
    @StateObject private var store: AudioControlStore

    init() {
        let settingsStore = SettingsStore()
        let settings = (try? settingsStore.load()) ?? PersistedSettings()
        let backend = AudioBackendFactory.makeBackend(mode: settings.customization.backendMode)
        let controlStore = (try? AudioControlStore(settingsStore: settingsStore, backend: backend))
            ?? (try! AudioControlStore(settingsStore: SettingsStore(settingsURL: FileManager.default.temporaryDirectory.appendingPathComponent("eqmacrep-fallback.json")), backend: MockAudioBackend()))
        _store = StateObject(wrappedValue: controlStore)
    }

    var body: some Scene {
        MenuBarExtra("EQMacRep", systemImage: "slider.horizontal.3") {
            MenuBarRootView(store: store)
                .task {
                    try? store.refresh()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    store.shutdown()
                }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store)
        }
    }
}
