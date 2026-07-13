import XCTest
@testable import EQMacRep

@MainActor
final class AudioCoordinatorTests: XCTestCase {
    func testSessionForwardsSnapshotCommandAndStatus() throws {
        let backend = CoordinatorBackend()
        backend.snapshot = AudioBackendSnapshot(apps: [AudioAppSnapshot(identity: .init(rawValue: "music"), displayName: "Music")])
        let session = AudioSessionCoordinator(backend: backend, backendFactory: { _ in CoordinatorBackend() })

        XCTAssertEqual(try session.fetchSnapshot().apps.count, 1)
        try session.apply(.setMuted(.init(rawValue: "music"), true))
        XCTAssertEqual(backend.commands.count, 1)
        XCTAssertEqual(session.statusMessage(appCount: 1, deviceCount: 0), "healthy 1/0")
    }

    func testDeniedSynchronizationTearsDownAndGrantedSynchronizationForwards() throws {
        let backend = CoordinatorBackend()
        let session = AudioSessionCoordinator(backend: backend, backendFactory: { _ in CoordinatorBackend() })
        let music = AudioAppIdentity(rawValue: "music")

        try session.synchronizeTaps(activeAppIDs: [music], ignoredAppIDs: [], permissionAllowsTaps: false)
        XCTAssertEqual(backend.tearDownAllCount, 1)
        XCTAssertTrue(backend.synchronized.isEmpty)

        try session.synchronizeTaps(activeAppIDs: [music], ignoredAppIDs: [], permissionAllowsTaps: true)
        XCTAssertEqual(backend.synchronized, [music])
    }

    func testBackendSwitchAndShutdownTearDownOwnedBackends() throws {
        let initial = CoordinatorBackend()
        let replacement = CoordinatorBackend()
        let session = AudioSessionCoordinator(backend: initial, backendFactory: { _ in replacement })

        try session.switchBackend(to: .mock)
        XCTAssertEqual(initial.tearDownAllCount, 1)
        try session.shutdown()
        XCTAssertEqual(replacement.tearDownAllCount, 1)
    }

    func testPermissionCoordinatorMapsAndDelegates() {
        let client = CoordinatorPermissionClient(state: .init(screenCapture: .denied, audioUsageDescription: .present))
        let coordinator = AudioPermissionCoordinator(client: client)

        XCTAssertEqual(coordinator.requirements.first?.state, .denied)
        XCTAssertEqual(coordinator.requestAudioCapture().screenCapture, .denied)
        coordinator.openAudioPrivacySettings()
        XCTAssertEqual(client.openCount, 1)
    }

    func testPendingRestartStaysStickyAcrossRefresh() {
        // Request returns pendingRestart; the OS keeps reporting notDetermined until
        // relaunch. refresh() must not regress the surfaced state back to notRequested.
        let client = CoordinatorPermissionClient(
            state: .init(screenCapture: .notDetermined, audioUsageDescription: .present),
            requestState: .init(screenCapture: .pendingRestart, audioUsageDescription: .present)
        )
        let coordinator = AudioPermissionCoordinator(client: client)

        XCTAssertEqual(coordinator.requestAudioCapture().screenCapture, .pendingRestart)
        XCTAssertEqual(coordinator.refresh().screenCapture, .pendingRestart)
        XCTAssertEqual(coordinator.requirements.first?.state, .restartRequired)
        coordinator.relaunchApp()
        XCTAssertEqual(client.relaunchCount, 1)
    }
}

private final class CoordinatorBackend: AudioBackend, AudioBackendStatusProviding, AudioBackendTapSynchronizing {
    var snapshot = AudioBackendSnapshot()
    var commands: [AudioBackendCommand] = []
    var synchronized: Set<AudioAppIdentity> = []
    var tearDownAllCount = 0
    func fetchSnapshot() throws -> AudioBackendSnapshot { snapshot }
    func apply(_ command: AudioBackendCommand) throws { commands.append(command) }
    func statusMessage(appCount: Int, deviceCount: Int) -> String { "healthy \(appCount)/\(deviceCount)" }
    func synchronizeTaps(activeAppIDs: Set<AudioAppIdentity>, ignoredAppIDs: Set<AudioAppIdentity>) throws { synchronized = activeAppIDs.subtracting(ignoredAppIDs) }
    func tearDownTap(for identity: AudioAppIdentity) throws {}
    func tearDownAllTaps() throws { tearDownAllCount += 1 }
}

private final class CoordinatorPermissionClient: AudioCapturePermissionClient {
    let state: AudioCapturePermissionState
    let requestState: AudioCapturePermissionState
    var openCount = 0
    var relaunchCount = 0
    init(state: AudioCapturePermissionState, requestState: AudioCapturePermissionState? = nil) {
        self.state = state
        self.requestState = requestState ?? state
    }
    func currentState() -> AudioCapturePermissionState { state }
    func requestScreenCaptureAccess() -> AudioCapturePermissionState { requestState }
    func openPrivacySettings() { openCount += 1 }
    func relaunchApp() { relaunchCount += 1 }
}
