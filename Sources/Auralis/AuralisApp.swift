import Foundation
import SwiftUI

@main
struct AuralisApp: App {
    @NSApplicationDelegateAdaptor(AuralisApplicationDelegate.self) private var appDelegate
    @StateObject private var store: AudioControlStore
    @StateObject private var controls: ExternalControlsCoordinator
    @StateObject private var widgetBridge: WidgetBridge
    private let lifecycle: AppLifecycleCoordinator

    init() {
        #if DEBUG
        let enforcedBackendMode: BackendMode? = nil
        #else
        let enforcedBackendMode: BackendMode? = .coreAudioDiscovery
        #endif
        let controlStore: AudioControlStore
        if AuralisRuntimeEnvironment.isRunningTests {
            let testSettingsURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "Auralis-XCTest-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
                    isDirectory: true
                )
                .appendingPathComponent("settings.json")
            controlStore = AudioControlStore(
                settingsStore: SettingsStore(
                    settingsURL: testSettingsURL,
                    enforcedBackendMode: .mock
                ),
                backend: MockAudioBackend()
            )
        } else {
            let settingsStore = SettingsStore(enforcedBackendMode: enforcedBackendMode)
            // AudioControlStore owns the one recovery-aware load. Preloading
            // here would consume a quarantine notice before the UI can publish
            // it.
            controlStore = AudioControlStore(settingsStore: settingsStore)
        }

        let externalControls = ExternalControlsCoordinator(windowRouter: AppWindowRouter())
        let bridge = WidgetBridge(store: controlStore)
        let lifecycle = AppLifecycleCoordinator(
            store: controlStore,
            controls: externalControls,
            widgetBridge: bridge
        )
        _store = StateObject(wrappedValue: controlStore)
        _controls = StateObject(wrappedValue: externalControls)
        _widgetBridge = StateObject(wrappedValue: bridge)
        self.lifecycle = lifecycle
        appDelegate.configure(lifecycle: lifecycle)
    }

    private var menuBarSymbol: String {
        let levels = store.appLevels.levels
        let loudest = store.displayRows.max { (levels[$0.identity] ?? 0) < (levels[$1.identity] ?? 0) }
        return MenuBarIconState.symbolName(
            style: store.settings.customization.menuBarIconStyle,
            volume: loudest?.settings.volume ?? 1,
            isMuted: loudest?.settings.isMuted ?? false
        )
    }

    var body: some Scene {
        Window("Auralis", id: AppWindowID.main.rawValue) {
            MainWindowSceneContent(store: store, widgetBridge: widgetBridge)
                .environmentObject(controls)
        }
        .defaultSize(width: 1080, height: 760)

        MenuBarExtra("Auralis", systemImage: menuBarSymbol) {
            MenuBarRootView(store: store)
                .environmentObject(controls)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsRootView(store: store)
                .environmentObject(controls)
                .onChange(of: store.settings.customization) { _, _ in
                    Task { await lifecycle.applySettings() }
                }
        }
    }
}

private struct MainWindowSceneContent: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var store: AudioControlStore
    @ObservedObject var widgetBridge: WidgetBridge

    var body: some View {
        MainWindowView(store: store)
            .background(WindowIdentityInstaller(identifier: .main))
            .onOpenURL { url in
                guard AppURLRoute(url) == .openMainWindow else { return }
                openWindow(id: AppWindowID.main.rawValue)
                NSApp.activate(ignoringOtherApps: true)
                Task { await widgetBridge.flush() }
            }
    }
}
