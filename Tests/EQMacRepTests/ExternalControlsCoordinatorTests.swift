import Foundation
import XCTest
@testable import EQMacRep

@MainActor
final class ExternalControlsCoordinatorTests: XCTestCase {
    func testRepeatedStartAndStopDoNotDuplicateRegistrationsOrCallbacks() async throws {
        let accessClient = StubAccessibilityClient(isTrusted: true)
        let media = StubMediaKeyMonitor()
        let hotkeys = StubHotkeyRegistrar()
        let coordinator = makeCoordinator(
            accessClient: accessClient,
            media: media,
            hotkeys: hotkeys
        )
        let store = try makeStore()
        await store.waitUntilReady()

        coordinator.start(store: store)
        coordinator.start(store: store)
        coordinator.stop()
        coordinator.stop()

        XCTAssertEqual(media.startCount, 1)
        XCTAssertEqual(media.stopCount, 1)
        XCTAssertEqual(hotkeys.registerCount, 1)
        XCTAssertEqual(hotkeys.stopCount, 1)
        XCTAssertNil(media.onEvent)
        XCTAssertNil(media.onOperationalFailure)
        XCTAssertNil(hotkeys.onAction)
        _ = await store.shutdown()
    }

    func testAccessibilityFailureIsVisibleAndRequestCanRecoverMediaKeys() async throws {
        let accessClient = StubAccessibilityClient(isTrusted: false, grantsOnRequest: true)
        let media = StubMediaKeyMonitor()
        let hotkeys = StubHotkeyRegistrar()
        let coordinator = makeCoordinator(
            accessClient: accessClient,
            media: media,
            hotkeys: hotkeys
        )
        let store = try makeStore()
        await store.waitUntilReady()

        coordinator.start(store: store)

        let issue = try XCTUnwrap(store.issues.first { $0.id == "media-keys-accessibility" })
        XCTAssertEqual(issue.domain, .externalControl)
        XCTAssertEqual(issue.severity, .warning)
        XCTAssertEqual(issue.recovery, .requestAccessibilityPermission)
        XCTAssertEqual(media.startCount, 0)
        XCTAssertEqual(media.stopCount, 1)

        coordinator.requestAccessibilityAccess()

        XCTAssertTrue(coordinator.accessibilityTrusted)
        XCTAssertEqual(accessClient.requestCount, 1)
        XCTAssertEqual(media.startCount, 1)
        XCTAssertFalse(store.issues.contains { $0.id == "media-keys-accessibility" })
        coordinator.stop()
        _ = await store.shutdown()
    }

    func testMediaTapAndHotkeyRegistrationFailuresArePublishedAndRecoverable() async throws {
        let media = StubMediaKeyMonitor(startResult: .failed("Synthetic media-tap failure"))
        let hotkeys = StubHotkeyRegistrar(report: HotkeyRegistrationReport(
            registeredActions: [.showMixer],
            failures: [HotkeyRegistrationFailure(action: .targetAppMuteToggle, status: -9876)]
        ))
        let coordinator = makeCoordinator(
            accessClient: StubAccessibilityClient(isTrusted: true),
            media: media,
            hotkeys: hotkeys
        )
        let store = try makeStore()
        await store.waitUntilReady()

        coordinator.start(store: store)

        let mediaIssue = try XCTUnwrap(store.issues.first { $0.id == "media-keys" })
        XCTAssertEqual(mediaIssue.recovery, .retryExternalControls)
        XCTAssertTrue(mediaIssue.message.contains("Synthetic media-tap failure"))
        let hotkeyIssue = try XCTUnwrap(store.issues.first { $0.id == "global-hotkeys" })
        XCTAssertEqual(hotkeyIssue.recovery, .retryExternalControls)
        XCTAssertTrue(hotkeyIssue.message.contains("Mute (OSStatus -9876)"))

        media.startResult = .running
        hotkeys.report = .success
        coordinator.applySettings()

        XCTAssertEqual(media.startCount, 2)
        XCTAssertEqual(hotkeys.registerCount, 2)
        XCTAssertFalse(store.issues.contains { $0.id == "media-keys" })
        XCTAssertFalse(store.issues.contains { $0.id == "global-hotkeys" })
        coordinator.stop()
        _ = await store.shutdown()
    }

    func testOperationalMediaTapFailureAfterStartupIsPublished() async throws {
        let media = StubMediaKeyMonitor()
        let coordinator = makeCoordinator(
            accessClient: StubAccessibilityClient(isTrusted: true),
            media: media,
            hotkeys: StubHotkeyRegistrar()
        )
        let store = try makeStore()
        await store.waitUntilReady()
        coordinator.start(store: store)

        media.onOperationalFailure?("Event tap kept flapping")

        let issue = try XCTUnwrap(store.issues.first { $0.id == "media-keys" })
        XCTAssertTrue(issue.message.contains("flapping"))
        XCTAssertEqual(issue.recovery, .retryExternalControls)
        coordinator.stop()
        _ = await store.shutdown()
    }

    func testShowMixerUsesStableRouterAndPublishesUnavailableWindow() async throws {
        let hotkeys = StubHotkeyRegistrar()
        let router = StubWindowRouter(result: false)
        let coordinator = makeCoordinator(
            accessClient: StubAccessibilityClient(isTrusted: true),
            media: StubMediaKeyMonitor(),
            hotkeys: hotkeys,
            router: router
        )
        let store = try makeStore()
        await store.waitUntilReady()
        coordinator.start(store: store)

        hotkeys.onAction?(.showMixer)

        XCTAssertEqual(router.showCount, 1)
        XCTAssertEqual(store.issues.first { $0.id == "window-routing" }?.severity, .warning)

        router.result = true
        hotkeys.onAction?(.showMixer)

        XCTAssertEqual(router.showCount, 2)
        XCTAssertFalse(store.issues.contains { $0.id == "window-routing" })
        coordinator.stop()
        _ = await store.shutdown()
    }

    func testAccessibilitySettingsFailureIsPublishedWithRecovery() async throws {
        let accessClient = StubAccessibilityClient(isTrusted: false, openResult: false)
        let coordinator = makeCoordinator(
            accessClient: accessClient,
            media: StubMediaKeyMonitor(),
            hotkeys: StubHotkeyRegistrar()
        )
        let store = try makeStore()
        await store.waitUntilReady()
        coordinator.start(store: store)

        coordinator.openAccessibilitySettings()

        XCTAssertEqual(accessClient.openCount, 1)
        XCTAssertEqual(
            store.issues.first { $0.id == "accessibility-settings" }?.recovery,
            .openAccessibilitySettings
        )

        accessClient.openResult = true
        coordinator.openAccessibilitySettings()

        XCTAssertEqual(accessClient.openCount, 2)
        XCTAssertFalse(store.issues.contains { $0.id == "accessibility-settings" })
        coordinator.stop()
        _ = await store.shutdown()
    }

    private func makeCoordinator(
        accessClient: StubAccessibilityClient,
        media: StubMediaKeyMonitor,
        hotkeys: StubHotkeyRegistrar,
        router: StubWindowRouter = StubWindowRouter(result: true)
    ) -> ExternalControlsCoordinator {
        ExternalControlsCoordinator(
            accessibility: AccessibilityPermissionService(client: accessClient),
            mediaKeyMonitor: media,
            hotkeyRegistrar: hotkeys,
            hud: StubVolumeHUD(),
            windowRouter: router
        )
    }

    private func makeStore() throws -> AudioControlStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EQMacRep-ExternalControls-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try AudioControlStore(
            settingsStore: SettingsStore(settingsURL: url),
            backend: MockAudioBackend(),
            permissionClient: ExternalControlsAudioPermissionClient()
        )
    }
}

private extension HotkeyRegistrationReport {
    static var success: HotkeyRegistrationReport {
        HotkeyRegistrationReport(
            registeredActions: Set(ShortcutAction.allCases),
            failures: []
        )
    }
}

@MainActor
private final class StubAccessibilityClient: AccessibilityPermissionClient {
    var isTrusted: Bool
    let grantsOnRequest: Bool
    var openResult: Bool
    private(set) var requestCount = 0
    private(set) var openCount = 0

    init(isTrusted: Bool, grantsOnRequest: Bool = false, openResult: Bool = true) {
        self.isTrusted = isTrusted
        self.grantsOnRequest = grantsOnRequest
        self.openResult = openResult
    }

    func isProcessTrusted() -> Bool { isTrusted }

    func requestProcessTrust() -> Bool {
        requestCount += 1
        if grantsOnRequest { isTrusted = true }
        return isTrusted
    }

    func openPrivacySettings() -> Bool {
        openCount += 1
        return openResult
    }
}

@MainActor
private final class StubMediaKeyMonitor: MediaKeyMonitoring {
    var onEvent: ((MediaKeyEvent) -> Void)?
    var onOperationalFailure: ((String) -> Void)?
    var startResult: MediaKeyMonitorStartResult
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(startResult: MediaKeyMonitorStartResult = .running) {
        self.startResult = startResult
    }

    func start() -> MediaKeyMonitorStartResult {
        startCount += 1
        return startResult
    }

    func stop() {
        stopCount += 1
    }
}

@MainActor
private final class StubHotkeyRegistrar: GlobalHotkeyRegistering {
    var onAction: ((ShortcutAction) -> Void)?
    var report: HotkeyRegistrationReport
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var stopCount = 0

    init(report: HotkeyRegistrationReport = .success) {
        self.report = report
    }

    func register(_ bindings: [ShortcutAction: HotkeyBinding]) -> HotkeyRegistrationReport {
        registerCount += 1
        return report
    }

    func unregisterAll() {
        unregisterCount += 1
    }

    func stop() {
        stopCount += 1
        onAction = nil
    }
}

@MainActor
private final class StubVolumeHUD: VolumeHUDPresenting {
    private(set) var states: [VolumeHUDState] = []
    func show(_ state: VolumeHUDState) { states.append(state) }
}

@MainActor
private final class StubWindowRouter: AppWindowRouting {
    var result: Bool
    private(set) var showCount = 0

    init(result: Bool) {
        self.result = result
    }

    func showMainWindow() -> Bool {
        showCount += 1
        return result
    }
}

@MainActor
private struct ExternalControlsAudioPermissionClient: AudioCapturePermissionClient {
    func currentState() -> AudioCapturePermissionState {
        .init(screenCapture: .granted, audioUsageDescription: .present)
    }

    func requestScreenCaptureAccess() -> AudioCapturePermissionState { currentState() }
    func openPrivacySettings() {}
    func relaunchApp() async throws {}
}
