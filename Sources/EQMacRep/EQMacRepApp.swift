import SwiftUI

@main
struct EQMacRepApp: App {
    @StateObject private var store: AudioControlStore
    @StateObject private var controls = ExternalControlsCoordinator()

    init() {
        let settingsStore = SettingsStore()
        let settings = (try? settingsStore.load()) ?? PersistedSettings()
        let backend = AudioBackendFactory.makeBackend(mode: settings.customization.backendMode)
        let controlStore = (try? AudioControlStore(settingsStore: settingsStore, backend: backend))
            ?? (try! AudioControlStore(settingsStore: SettingsStore(settingsURL: FileManager.default.temporaryDirectory.appendingPathComponent("eqmacrep-fallback.json")), backend: MockAudioBackend()))
        _store = StateObject(wrappedValue: controlStore)
    }

    private var menuBarSymbol: String {
        let loudest = store.displayRows.max { $0.level < $1.level }
        let volume = loudest?.settings.volume ?? 1
        let muted = loudest?.settings.isMuted ?? false
        return MenuBarIconState.symbolName(
            style: store.settings.customization.menuBarIconStyle,
            volume: volume,
            isMuted: muted
        )
    }

    var body: some Scene {
        WindowGroup("EQMacRep", id: "main") {
            MainWindowView(store: store)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    store.shutdown()
                }
        }
        .defaultSize(width: 1080, height: 760)

        MenuBarExtra("EQMacRep", systemImage: menuBarSymbol) {
            MenuBarRootView(store: store)
                .task {
                    store.refreshPermissionState()
                    store.startBackendObservation()
                    controls.attach(store: store)
                    try? store.refresh()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    store.shutdown()
                }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store)
                .onChange(of: store.settings.customization) { _, _ in
                    controls.applySettings()
                }
        }
    }
}
