import XCTest
@testable import Auralis

@MainActor
final class ControlCommandCoordinatorTests: XCTestCase {
    func testTwentyRapidVolumeStepsProduceTwentyProjectedSteps() async throws {
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
        try await store.setVolume(0.2, for: music)
        try await store.setMuted(true, for: music)

        let receipt = store.submit(
            ControlCommand(target: .app(music), mutation: .adjustVolume(0.05), source: .mediaKey)
        )
        XCTAssertTrue(receipt.accepted)
        XCTAssertEqual(receipt.projected?.volume ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertEqual(receipt.projected?.isMuted, false)
    }
}
