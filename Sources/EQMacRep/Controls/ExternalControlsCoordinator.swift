import AppKit
import SwiftUI

/// Owns the long-lived external-control services (media keys, hotkeys, HUD) and
/// wires them to the store. Lives for the app's lifetime.
@MainActor
final class ExternalControlsCoordinator: ObservableObject {
    let accessibility = AccessibilityPermissionService()
    private let mediaKeyMonitor = MediaKeyMonitor()
    private let hotkeyRegistrar = GlobalHotkeyRegistrar()
    private let hud = VolumeHUDWindowController()
    private weak var store: AudioControlStore?

    /// Whether the popup is currently open; the HUD is suppressed while it is.
    var isPopupVisible = false

    func attach(store: AudioControlStore) {
        self.store = store
        accessibility.refresh()
        configureMediaKeys()
        configureHotkeys()
    }

    func applySettings() {
        configureMediaKeys()
        configureHotkeys()
    }

    private func configureMediaKeys() {
        guard let store else { return }
        let enabled = store.settings.customization.mediaKeysEnabled && accessibility.isTrusted
        mediaKeyMonitor.isEnabled = enabled
        mediaKeyMonitor.onEvent = { [weak self] event in
            self?.handleMediaKey(event)
        }
        if enabled {
            mediaKeyMonitor.start()
        } else {
            mediaKeyMonitor.stop()
        }
    }

    private func configureHotkeys() {
        guard let store else { return }
        hotkeyRegistrar.onAction = { [weak self] action in
            self?.handleShortcut(action)
        }
        if store.settings.customization.hotkeysEnabled {
            let bindings = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.defaultBinding) })
            hotkeyRegistrar.register(bindings)
        } else {
            hotkeyRegistrar.unregisterAll()
        }
    }

    private func handleMediaKey(_ event: MediaKeyEvent) {
        switch event {
        case .volumeUp:
            perform(.volumeUp)
        case .volumeDown:
            perform(.volumeDown)
        case .muteToggle:
            perform(.muteToggle)
        }
    }

    private func handleShortcut(_ action: ShortcutAction) {
        switch action {
        case .togglePopup:
            NSApp.sendAction(#selector(NSApplication.arrangeInFront(_:)), to: nil, from: nil)
        case .targetAppVolumeUp:
            perform(.volumeUp)
        case .targetAppVolumeDown:
            perform(.volumeDown)
        case .targetAppMuteToggle:
            perform(.muteToggle)
        }
    }

    private func perform(_ action: AppControlAction) {
        guard let store else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let executor = AppControlStoreExecutor(store: store)
        executor.perform(action, frontmostBundleID: frontmost, selectedAppID: nil)
        presentHUD()
    }

    private func presentHUD() {
        guard let store, !isPopupVisible else { return }
        let rows = store.displayRows
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard let identity = AppControlTargetResolver.resolve(rows: rows, frontmostBundleID: frontmost, selectedAppID: nil),
              let row = rows.first(where: { $0.identity == identity }) else {
            return
        }
        hud.show(VolumeHUDState(appName: row.displayName, volume: row.settings.volume, isMuted: row.settings.isMuted))
    }
}
