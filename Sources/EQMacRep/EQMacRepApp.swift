import SwiftUI

@main
struct EQMacRepApp: App {
    @StateObject private var store: AudioControlStore
    @StateObject private var controls = ExternalControlsCoordinator()

    init() {
        #if DEBUG
        let enforcedBackendMode: BackendMode? = nil
        #else
        let enforcedBackendMode: BackendMode? = .coreAudioDiscovery
        #endif
        let settingsStore = SettingsStore(enforcedBackendMode: enforcedBackendMode)
        let settings = (try? settingsStore.load()) ?? PersistedSettings()
        let backend = AudioBackendFactory.makeBackend(mode: settings.customization.backendMode)
        let controlStore: AudioControlStore
        if let primaryStore = try? AudioControlStore(settingsStore: settingsStore, backend: backend) {
            controlStore = primaryStore
        } else {
            let fallbackStore = SettingsStore(
                settingsURL: FileManager.default.temporaryDirectory.appendingPathComponent("eqmacrep-fallback.json"),
                enforcedBackendMode: enforcedBackendMode
            )
            let fallbackBackend = AudioBackendFactory.makeBackend(mode: enforcedBackendMode ?? .mock)
            controlStore = try! AudioControlStore(settingsStore: fallbackStore, backend: fallbackBackend)
        }
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
        Window("EQMacRep", id: "main") {
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
                    store.refreshIntent()
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
