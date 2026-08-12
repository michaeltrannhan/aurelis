import XCTest
@testable import Auralis

@MainActor
final class ControlCommandCoordinatorTests: XCTestCase {
    func testTwentyRapidVolumeStepsProduceTwentyProjectedSteps() async throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let backend = MockAudioBackend(apps: [
            AudioAppSnapshot(identity: music, displayName: "Music", isActive: true)
        ])
        let store = AudioControlStore(
            settingsStore: SettingsStore(settingsURL: temporaryFileURL(filename: "settings.json")),
            backend: backend,
            permissionClient: FakePermissionClient(
                state: AudioCapturePermissionState(screenCapture: .granted, audioUsageDescription: .present)
            )
        )
        await store.waitUntilReady()
        store.refreshPermissionState()
        try await store.refresh()
        try await store.setVolume(0.0, for: music)

        var projected: [Double] = []
        for _ in 0..<20 {
            let receipt = store.submit(
                ControlCommand(target: .app(music), mutation: .adjustVolume(0.05), source: .mediaKey)
            )
            XCTAssertTrue(receipt.accepted)
            projected.append(receipt.projected?.volume ?? -1)
        }

        XCTAssertEqual(projected.count, 20)
        XCTAssertEqual(projected.last ?? -1, 1.0, accuracy: 0.0001)
        XCTAssertEqual(store.commandCoordinator.lastReceipt?.projected?.volume ?? -1, 1.0, accuracy: 0.0001)

        // Channel model updates from action states without replacing unrelated identities.
        XCTAssertEqual(store.channels.appOrder, [music])
        XCTAssertNotNil(store.channels.appModel(for: music))
    }

    func testVolumeUpUnmuteIsOneAtomicProjection() async throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let backend = MockAudioBackend(apps: [
            AudioAppSnapshot(identity: music, displayName: "Music", isActive: true)
        ])
        let store = AudioControlStore(
            settingsStore: SettingsStore(settingsURL: temporaryFileURL(filename: "settings.json")),
            backend: backend,
            permissionClient: FakePermissionClient(
                state: AudioCapturePermissionState(screenCapture: .granted, audioUsageDescription: .present)
            )
        )
        await store.waitUntilReady()
        store.refreshPermissionState()
        try await store.refresh()
        try await store.setVolume(0.2, for: music)
        try await store.setMuted(true, for: music)

        let receipt = store.submit(
            ControlCommand(target: .app(music), mutation: .adjustVolume(0.05), source: .mediaKey)
        )
        XCTAssertTrue(receipt.accepted)
        XCTAssertEqual(receipt.projected?.volume ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertEqual(receipt.projected?.isMuted, false)

        let result = await store.result(for: receipt.id)
        if case let .applied(actual) = result {
            XCTAssertEqual(actual.volume ?? -1, 0.25, accuracy: 0.0001)
            XCTAssertEqual(actual.isMuted, false)
        } else {
            XCTFail("Expected applied result, got \(result)")
        }
        XCTAssertEqual(store.settings.appSettings[music]?.volume ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertEqual(store.settings.appSettings[music]?.isMuted, false)
        XCTAssertTrue(backend.commands.contains(.setMuted(music, false)))
    }

    func testContinuousCommandsCancelSupersededReceiptAndFlushLatest() async throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let store = AudioControlStore(
            settingsStore: SettingsStore(settingsURL: temporaryFileURL(filename: "settings.json")),
            backend: MockAudioBackend(apps: [
                AudioAppSnapshot(identity: music, displayName: "Music", isActive: true)
            ]),
            permissionClient: FakePermissionClient(
                state: AudioCapturePermissionState(screenCapture: .granted, audioUsageDescription: .present)
            )
        )
        await store.waitUntilReady()
        store.refreshPermissionState()
        try await store.refresh()

        let first = store.submit(
            ControlCommand(target: .app(music), mutation: .setVolume(0.25), source: .ui)
        )
        let latest = store.submit(
            ControlCommand(target: .app(music), mutation: .setVolume(0.75), source: .ui)
        )
        store.commandCoordinator.flushContinuous(for: .app(music))

        let supersededResult = await store.result(for: first.id)
        let latestResult = await store.result(for: latest.id)
        XCTAssertEqual(supersededResult, .cancelled)
        if case let .applied(actual) = latestResult {
            XCTAssertEqual(actual.volume ?? -1, 0.75, accuracy: 0.0001)
        } else {
            XCTFail("Expected latest continuous command to be applied")
        }
        XCTAssertEqual(store.settings.appSettings[music]?.volume ?? -1, 0.75, accuracy: 0.0001)
    }

    func testOlderCompletionDoesNotOverwriteNewerRelativeProjection() async throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let backend = BlockingVolumeBackend(app: music)
        defer { backend.releaseAll() }
        let store = AudioControlStore(
            settingsStore: SettingsStore(settingsURL: temporaryFileURL(filename: "settings.json")),
            backend: backend,
            permissionClient: FakePermissionClient(
                state: AudioCapturePermissionState(screenCapture: .granted, audioUsageDescription: .present)
            )
        )
        await store.waitUntilReady()
        store.refreshPermissionState()
        try await store.refresh()

        let first = store.submit(ControlCommand(
            target: .app(music),
            mutation: .setVolume(0.2),
            source: .hotkey
        ))
        await waitForVolumeApplyCount(1, backend: backend)

        let second = store.submit(ControlCommand(
            target: .app(music),
            mutation: .adjustVolume(0.1),
            source: .hotkey
        ))
        XCTAssertEqual(second.projected?.volume ?? -1, 0.3, accuracy: 0.0001)

        backend.releaseNext()
        await waitForVolumeApplyCount(2, backend: backend)

        let third = store.submit(ControlCommand(
            target: .app(music),
            mutation: .adjustVolume(0.1),
            source: .hotkey
        ))
        XCTAssertEqual(third.projected?.volume ?? -1, 0.4, accuracy: 0.0001)

        backend.releaseNext()
        await waitForVolumeApplyCount(3, backend: backend)
        backend.releaseNext()

        for receipt in [first, second, third] {
            if case .applied = await store.result(for: receipt.id) {
            } else {
                XCTFail("Expected every queued command to apply")
            }
        }
        XCTAssertEqual(store.settings.appSettings[music]?.volume ?? -1, 0.4, accuracy: 0.0001)
    }

    func testCompletedProjectionDoesNotMaskLaterCommittedState() async throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let store = AudioControlStore(
            settingsStore: SettingsStore(settingsURL: temporaryFileURL(filename: "settings.json")),
            backend: MockAudioBackend(apps: [
                AudioAppSnapshot(identity: music, displayName: "Music", isActive: true)
            ]),
            permissionClient: FakePermissionClient(
                state: AudioCapturePermissionState(screenCapture: .granted, audioUsageDescription: .present)
            )
        )
        await store.waitUntilReady()
        store.refreshPermissionState()
        try await store.refresh()

        let first = store.submit(ControlCommand(
            target: .app(music),
            mutation: .setVolume(0.2),
            source: .hotkey
        ))
        if case .applied = await store.result(for: first.id) {
        } else {
            XCTFail("Expected initial command to apply")
        }

        try await store.setVolume(0.8, for: music)
        let next = store.submit(ControlCommand(
            target: .app(music),
            mutation: .adjustVolume(0.1),
            source: .hotkey
        ))

        XCTAssertEqual(next.projected?.volume ?? -1, 0.9, accuracy: 0.0001)
        _ = await store.result(for: next.id)
    }

    private func waitForVolumeApplyCount(
        _ expectedCount: Int,
        backend: BlockingVolumeBackend
    ) async {
        for _ in 0..<10_000 {
            if backend.volumeApplyCount >= expectedCount { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for volume apply \(expectedCount)")
    }
}

private final class BlockingVolumeBackend: AudioBackend {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private let snapshot: AudioBackendSnapshot
    private var storedVolumeApplyCount = 0

    init(app: AudioAppIdentity) {
        snapshot = AudioBackendSnapshot(apps: [
            AudioAppSnapshot(identity: app, displayName: "Music", isActive: true)
        ])
    }

    var volumeApplyCount: Int {
        lock.withLock { storedVolumeApplyCount }
    }

    func fetchSnapshot() throws -> AudioBackendSnapshot { snapshot }

    func apply(_ command: AudioBackendCommand) throws {
        guard case .setVolume = command else { return }
        lock.withLock { storedVolumeApplyCount += 1 }
        releaseSemaphore.wait()
    }

    func releaseNext() {
        releaseSemaphore.signal()
    }

    func releaseAll() {
        for _ in 0..<10 { releaseSemaphore.signal() }
    }
}
