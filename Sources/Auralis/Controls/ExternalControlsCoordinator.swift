import AppKit
import SwiftUI

@MainActor
protocol VolumeHUDPresenting: AnyObject {
    func show(_ state: VolumeHUDState)
}

extension VolumeHUDWindowController: VolumeHUDPresenting {}

/// Owns media keys, hotkeys, Accessibility state, window routing, and the HUD
/// for the process lifetime. Registration failures are published through the
/// store instead of becoming silent dead controls.
@MainActor
final class ExternalControlsCoordinator: ObservableObject {
    let accessibility: AccessibilityPermissionService
    @Published private(set) var accessibilityTrusted: Bool

    private let mediaKeyMonitor: any MediaKeyMonitoring
    private let hotkeyRegistrar: any GlobalHotkeyRegistering
    private let hud: any VolumeHUDPresenting
    private let windowRouter: any AppWindowRouting
    private weak var store: AudioControlStore?
    private var isStarted = false

    /// Updated by the menu-extra view so the custom HUD does not cover an open
    /// mixer. Phase 7 owns the exact popup visibility presentation behavior.
    var isPopupVisible = false

    init(
        accessibility: AccessibilityPermissionService = AccessibilityPermissionService(),
        mediaKeyMonitor: any MediaKeyMonitoring = MediaKeyMonitor(),
        hotkeyRegistrar: any GlobalHotkeyRegistering = GlobalHotkeyRegistrar(),
        hud: any VolumeHUDPresenting = VolumeHUDWindowController(),
        windowRouter: any AppWindowRouting = AppWindowRouter()
    ) {
        self.accessibility = accessibility
        self.accessibilityTrusted = accessibility.isTrusted
        self.mediaKeyMonitor = mediaKeyMonitor
        self.hotkeyRegistrar = hotkeyRegistrar
        self.hud = hud
        self.windowRouter = windowRouter
    }

    func start(store: AudioControlStore) {
        guard !isStarted else { return }
        self.store = store
        isStarted = true
        refreshAccessibility()
        configureMediaKeys()
        configureHotkeys()
    }

    func applySettings() {
        guard isStarted else { return }
        refreshAccessibility()
        configureMediaKeys()
        configureHotkeys()
    }

    func stop() {
        guard isStarted else { return }
        mediaKeyMonitor.stop()
        mediaKeyMonitor.onEvent = nil
        mediaKeyMonitor.onOperationalFailure = nil
        hotkeyRegistrar.stop()
        hotkeyRegistrar.onAction = nil
        store = nil
        isStarted = false
    }

    func refreshAccessibility() {
        accessibility.refresh()
        accessibilityTrusted = accessibility.isTrusted
    }

    func requestAccessibilityAccess() {
        accessibility.requestAccess()
        accessibilityTrusted = accessibility.isTrusted
        if isStarted { configureMediaKeys() }
    }

    func openAccessibilitySettings() {
        if accessibility.openPrivacySettings() {
            store?.reportExternalControlIssue(id: "accessibility-settings", message: nil)
        } else {
            store?.reportExternalControlIssue(
                id: "accessibility-settings",
                message: "Couldn’t open Accessibility settings.",
                recovery: .openAccessibilitySettings
            )
        }
    }

    var accessibilityRequirement: PermissionRequirement {
        PermissionRequirement(
            kind: .accessibility,
            state: accessibilityTrusted ? .granted : .notRequested,
            explanation: "Optional; required only for intercepting hardware media keys.",
            isOptional: true
        )
    }

    private func configureMediaKeys() {
        guard let store else { return }
        mediaKeyMonitor.onEvent = { [weak self] event in self?.handleMediaKey(event) }
        mediaKeyMonitor.onOperationalFailure = { [weak self] message in
            self?.store?.reportExternalControlIssue(
                id: "media-keys",
                message: message,
                recovery: .retryExternalControls
            )
        }

        guard store.settings.customization.mediaKeysEnabled else {
            mediaKeyMonitor.stop()
            store.reportExternalControlIssue(id: "media-keys", message: nil)
            store.reportExternalControlIssue(id: "media-keys-accessibility", message: nil)
            return
        }
        guard accessibilityTrusted else {
            mediaKeyMonitor.stop()
            store.reportExternalControlIssue(
                id: "media-keys-accessibility",
                message: "Media-key control needs Accessibility permission.",
                severity: .warning,
                recovery: .requestAccessibilityPermission
            )
            return
        }

        store.reportExternalControlIssue(id: "media-keys-accessibility", message: nil)
        switch mediaKeyMonitor.start() {
        case .running:
            store.reportExternalControlIssue(id: "media-keys", message: nil)
        case let .failed(message):
            store.reportExternalControlIssue(
                id: "media-keys",
                message: message,
                recovery: .retryExternalControls
            )
        }
    }

    private func configureHotkeys() {
        guard let store else { return }
        hotkeyRegistrar.onAction = { [weak self] action in self?.handleShortcut(action) }
        guard store.settings.customization.hotkeysEnabled else {
            hotkeyRegistrar.unregisterAll()
            store.reportExternalControlIssue(id: "global-hotkeys", message: nil)
            return
        }

        let bindings = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map {
            ($0, $0.defaultBinding)
        })
        let report = hotkeyRegistrar.register(bindings)
        if report.succeeded {
            store.reportExternalControlIssue(id: "global-hotkeys", message: nil)
        } else {
            let details = report.failures.map { failure in
                let target = failure.action?.label ?? "event handler"
                return "\(target) (OSStatus \(failure.status))"
            }.joined(separator: ", ")
            store.reportExternalControlIssue(
                id: "global-hotkeys",
                message: "Some global hotkeys could not be registered: \(details).",
                recovery: .retryExternalControls
            )
        }
    }

    private func handleMediaKey(_ event: MediaKeyEvent) {
        switch event {
        case .volumeUp: perform(.volumeUp)
        case .volumeDown: perform(.volumeDown)
        case .muteToggle: perform(.muteToggle)
        }
    }

    private func handleShortcut(_ action: ShortcutAction) {
        switch action {
        case .showMixer:
            guard windowRouter.showMainWindow() else {
                store?.reportExternalControlIssue(
                    id: "window-routing",
                    message: "The mixer window is not available yet. Retry after application startup.",
                    severity: .warning,
                    recovery: .retryExternalControls
                )
                return
            }
            store?.reportExternalControlIssue(id: "window-routing", message: nil)
        case .targetAppVolumeUp: perform(.volumeUp)
        case .targetAppVolumeDown: perform(.volumeDown)
        case .targetAppMuteToggle: perform(.muteToggle)
        }
    }

    private func perform(_ action: AppControlAction) {
        guard let store else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        AppControlStoreExecutor(store: store).perform(
            action,
            frontmostBundleID: frontmost,
            selectedAppID: nil
        )
        presentHUD()
    }

    private func presentHUD() {
        guard let store, !isPopupVisible else { return }
        let rows = store.displayRows
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard let identity = AppControlTargetResolver.resolve(
            rows: rows,
            frontmostBundleID: frontmost,
            selectedAppID: nil
        ), let row = rows.first(where: { $0.identity == identity }) else { return }
        hud.show(VolumeHUDState(
            appName: row.displayName,
            volume: row.settings.volume,
            isMuted: row.settings.isMuted
        ))
    }
}
