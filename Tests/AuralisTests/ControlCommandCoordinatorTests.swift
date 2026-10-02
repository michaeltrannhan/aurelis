import XCTest
@testable import Auralis

@MainActor
final class ControlCommandCoordinatorTests: XCTestCase {
    func testDiscreteBarrierFlushesMultipleTargetsInGestureAcceptanceOrder() async throws {
        let firstApp = AudioAppIdentity(rawValue: "z-first")
        let secondApp = AudioAppIdentity(rawValue: "a-second")
        let backend = MockAudioBackend(apps: [
            AudioAppSnapshot(identity: firstApp, displayName: "First"),
            AudioAppSnapshot(identity: secondApp, displayName: "Second")])
        let store = AudioControlStore(
            settingsStore: SettingsStore(settingsURL: temporaryFileURL(filename: "settings.json")),
            backend: backend,
            permissionClient: FakePermissionClient(state: AudioCapturePermissionState(screenCapture: .granted, audioUsageDescription: .present)))
        try await store.refresh()
        backend.clearCommands()
        let first = store.submit(ControlCommand(target: .app(firstApp), mutation: .setVolume(0.2)))
        let second = store.submit(ControlCommand(target: .app(secondApp), mutation: .setVolume(0.4)))
        let barrier = store.submit(ControlCommand(target: .app(firstApp), mutation: .setMuted(true), source: .hotkey))
        _ = await store.result(for: first.id)
        _ = await store.result(for: second.id)
        _ = await store.result(for: barrier.id)
        let volumes = backend.commands.compactMap { command -> AudioAppIdentity? in
            if case let .setVolume(app, _) = command { return app }; return nil
        }
        XCTAssertEqual(volumes, [firstApp, secondApp])
        _ = await store.shutdown()
    }

    func testGlobalAndPerAppCommandsSharePendingProjection() async throws {
        let music = AudioAppIdentity(rawValue: "music")
        let store = AudioControlStore(
            settingsStore: SettingsStore(settingsURL: temporaryFileURL(filename: "settings.json")),
            backend: MockAudioBackend(apps: [AudioAppSnapshot(identity: music, displayName: "Music")]),
            permissionClient: FakePermissionClient(state: AudioCapturePermissionState(screenCapture: .granted, audioUsageDescription: .present)))
        try await store.refresh()
        let first = store.submit(ControlCommand(target: .app(music), mutation: .setVolume(0.2), source: .hotkey))
        let batch = store.submit(ControlCommand(target: .activeApps, mutation: .setVolume(0.8), source: .hotkey))
        let relative = store.submit(ControlCommand(target: .app(music), mutation: .adjustVolume(0.1), source: .hotkey))
        XCTAssertEqual(relative.projected?.volume ?? -1, 0.9, accuracy: 0.0001)
        _ = await store.result(for: first.id)
        _ = await store.result(for: batch.id)
        let result = await store.result(for: relative.id)
        if case let .applied(actual) = result { XCTAssertEqual(actual.volume ?? -1, 0.9, accuracy: 0.0001) }
        else { XCTFail("Expected relative command to apply") }
        XCTAssertEqual(store.settings.appSettings[music]?.volume ?? -1, 0.9, accuracy: 0.0001)
        _ = await store.shutdown()
    }

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
        XCTAssertEqual(store.channels.appModel(for: music)?.visibleVolume ?? -1, 0.8, accuracy: 0.0001)
        let next = store.submit(ControlCommand(
            target: .app(music),
            mutation: .adjustVolume(0.1),
            source: .hotkey
        ))

        XCTAssertEqual(next.projected?.volume ?? -1, 0.9, accuracy: 0.0001)
        _ = await store.result(for: next.id)
    }

    func testOutputAppliedProjectionDoesNotHideLaterHardwareOrEQState() {
        let device = AudioDeviceSnapshot(id: "usb", name: "USB")
        let model = OutputChannelModel(device: device, state: OutputVolumeState(volume: 0.2), settings: nil)
        let projected = ControlProjectedState(volume: 0.4, isMuted: true, eq: EQCurve())
        model.apply(actionState: .pending(projected: projected))
        XCTAssertEqual(model.visibleVolume, 0.4)
        model.apply(actionState: .applied(actual: projected))
        var eq = EQCurve()
        eq.setGain(3, at: 2)
        model.apply(device: device, state: OutputVolumeState(volume: 0.8), settings:
            DeviceAudioSettings(displayName: "USB", volume: 0.8, isMuted: false, eq: eq))
        XCTAssertEqual(model.visibleVolume, 0.8)
        XCTAssertFalse(model.visibleMuted)
        XCTAssertEqual(model.visibleEQ, eq)
    }

    func testDiscreteCommandCannotOvertakeEarlierContinuousCommand() async throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let store = AudioControlStore(
            settingsStore: SettingsStore(settingsURL: temporaryFileURL(filename: "settings.json")),
            backend: MockAudioBackend(apps: [AudioAppSnapshot(identity: music, displayName: "Music")])
        )
        try await store.refresh()
        let slider = store.submit(ControlCommand(target: .app(music), mutation: .setVolume(0.2)))
        let key = store.submit(ControlCommand(target: .app(music), mutation: .adjustVolume(0.1), source: .hotkey))
        _ = await store.result(for: slider.id)
        _ = await store.result(for: key.id)
        XCTAssertEqual(store.settings.appSettings[music]?.volume ?? -1, 0.3, accuracy: 0.0001)
        _ = await store.shutdown()
    }

    func testDifferentContinuousControlsAreNotCoalescedTogether() async throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let store = AudioControlStore(
            settingsStore: SettingsStore(settingsURL: temporaryFileURL(filename: "settings.json")),
            backend: MockAudioBackend(apps: [AudioAppSnapshot(identity: music, displayName: "Music")])
        )
        try await store.refresh()
        let volume = store.submit(ControlCommand(target: .app(music), mutation: .setVolume(0.2)))
        let firstBand = store.submit(ControlCommand(target: .app(music), mutation: .setEQBand(band: 0, gain: 3)))
        let secondBand = store.submit(ControlCommand(target: .app(music), mutation: .setEQBand(band: 1, gain: 4)))
        store.commandCoordinator.flushContinuous(for: .app(music))
        for receipt in [volume, firstBand, secondBand] {
            guard case .applied = await store.result(for: receipt.id) else { return XCTFail("Distinct control was discarded") }
        }
        XCTAssertEqual(store.settings.appSettings[music]?.volume, 0.2)
        XCTAssertEqual(store.settings.appSettings[music]?.eq.gains[0], 3)
        XCTAssertEqual(store.settings.appSettings[music]?.eq.gains[1], 4)
        _ = await store.shutdown()
    }

    func testShutdownCancelsPendingPreviewReceiptAndWaitsForActiveWorker() async throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let backend = BlockingVolumeBackend(app: music)
        defer { backend.releaseAll() }
        let store = AudioControlStore(
            settingsStore: SettingsStore(settingsURL: temporaryFileURL(filename: "settings.json")), backend: backend
        )
        try await store.refresh()
        let active = store.submit(ControlCommand(target: .app(music), mutation: .setVolume(0.3), source: .hotkey))
        await waitForVolumeApplyCount(1, backend: backend)
        let preview = store.submit(ControlCommand(target: .app(music), mutation: .setVolume(0.7)))
        var stopped = false
        let shutdown = Task { let report = await store.shutdown(); stopped = true; return report }
        for _ in 0..<10_000 {
            if store.storePhase == .shuttingDown { break }
            await Task.yield()
        }
        XCTAssertEqual(store.storePhase, .shuttingDown)
        XCTAssertFalse(stopped)
        let previewResult = await store.result(for: preview.id)
        XCTAssertEqual(previewResult, .cancelled)
        backend.releaseNext()
        _ = await shutdown.value
        guard case .applied = await store.result(for: active.id) else { return XCTFail("Active worker did not finish") }
        XCTAssertTrue(stopped)
        XCTAssertEqual(store.channels.appModel(for: music)?.visibleVolume, 0.3)
        XCTAssertFalse(store.commandCoordinator.submit(ControlCommand(target: .app(music), mutation: .toggleMute)).accepted)
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
        guard releaseSemaphore.wait(timeout: .now() + 5) == .success else {
            throw UserFacingFailure(title: "Test timeout", message: "Blocked volume command was not released")
        }
    }

    func releaseNext() {
        releaseSemaphore.signal()
    }

    func releaseAll() {
        for _ in 0..<10 { releaseSemaphore.signal() }
    }
}
