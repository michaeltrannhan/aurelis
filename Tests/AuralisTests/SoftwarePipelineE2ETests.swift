import Foundation
import XCTest
@testable import Auralis

/// End-to-end software path: on-disk v8 fixture → SettingsStore migration →
/// persisted automatic output context → AudioControlStore mutations →
/// independent reload. Uses the in-process mock backend so CI stays hermetic.
/// Always runs; not gated by `AURALIS_HW_TESTS`.
@MainActor
final class SoftwarePipelineE2ETests: XCTestCase {
    func testV8FixtureMigratesThenStoreMutationsPersistThroughReload() async throws {
        let music = AudioAppIdentity(rawValue: "com.apple.Music")
        let safari = AudioAppIdentity(rawValue: "com.apple.Safari")
        let settingsURL = try copyFixture("mixer-settings-v8.json")
        let settingsStore = SettingsStore(settingsURL: settingsURL)
        var settings = try settingsStore.load()

        XCTAssertEqual(settings.version, PersistedSettings.currentVersion)
        XCTAssertEqual(settings.customization.appearance, .dark)
        XCTAssertEqual(settings.customization.backendMode, .coreAudioDiscovery)
        XCTAssertEqual(settings.appSettings[music]?.volume ?? -1, 0.72, accuracy: 0.0001)
        XCTAssertEqual(settings.appSettings[music]?.boost, .x2)
        XCTAssertEqual(settings.appSettings[music]?.eq.gains[4] ?? 0, 3.5, accuracy: 0.0001)
        XCTAssertEqual(settings.appSettings[music]?.route, .multiOutput(["built-in", "usb"]))
        XCTAssertEqual(settings.appSettings[safari]?.isMuted, true)
        XCTAssertEqual(settings.deviceSettings["usb"]?.eq.gains[1] ?? 0, -4, accuracy: 0.0001)
        XCTAssertEqual(settings.deviceSettings["built-in"]?.eq, EQCurve())

        let contextID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        settings.profiles = [
            AudioProfile(
                id: contextID,
                name: "MacBook Speakers",
                scope: .outputDevice("built-in"),
                activatesAutomatically: true,
                appSettings: settings.appSettings,
                deviceSettings: settings.deviceSettings,
                preferredOutputDeviceID: "built-in"
            )
        ]
        settings.activeLocalProfileID = contextID
        settings.activeProfileID = contextID
        try settingsStore.save(settings)

        let backend = MockAudioBackend(
            apps: [
                AudioAppSnapshot(
                    identity: music,
                    displayName: "Music",
                    bundleIdentifier: music.rawValue,
                    isActive: true,
                    level: 0.55
                ),
                AudioAppSnapshot(
                    identity: safari,
                    displayName: "Safari",
                    bundleIdentifier: safari.rawValue,
                    isActive: true,
                    level: 0.12
                ),
            ],
            devices: [
                AudioDeviceSnapshot(id: "built-in", name: "MacBook Speakers", isDefault: true),
                AudioDeviceSnapshot(id: "usb", name: "USB DAC"),
            ]
        )
        backend.perDeviceVolume = ["built-in": 0.65, "usb": 0.48]
        let store = AudioControlStore(
            settingsStore: SettingsStore(settingsURL: settingsURL),
            backend: backend,
            permissionClient: FakePermissionClient(
                state: AudioCapturePermissionState(
                    screenCapture: .granted,
                    audioUsageDescription: .present
                )
            )
        )
        await store.waitUntilReady()
        try await store.refresh()

        let musicRow = try XCTUnwrap(store.displayRows.first { $0.identity == music })
        XCTAssertEqual(musicRow.settings.volume, 0.72, accuracy: 0.0001)
        XCTAssertEqual(musicRow.settings.boost, .x2)
        XCTAssertEqual(musicRow.settings.route, .multiOutput(["built-in", "usb"]))
        XCTAssertEqual(store.deviceVolumeStates["usb"]?.volume ?? -1, 0.48, accuracy: 0.0001)
        XCTAssertEqual(store.settings.deviceSettings["usb"]?.eq.gains[1] ?? 0, -4, accuracy: 0.0001)
        XCTAssertEqual(store.settings.activeLocalProfileID, contextID)

        backend.clearCommands()
        try await store.setVolume(0.33, for: music)
        try await store.setEQGain(-2, band: 4, for: music)
        try await store.setRoute(.selectedDevice("usb"), for: music)
        try await store.setOutputEQGain(6, band: 1, for: "usb")
        await store.waitForPendingOperations()
        await store.waitForPendingPersistence()

        XCTAssertEqual(store.settings.appSettings[music]?.volume ?? -1, 0.33, accuracy: 0.0001)
        XCTAssertEqual(store.settings.appSettings[music]?.eq.gains[4] ?? 0, -2, accuracy: 0.0001)
        XCTAssertEqual(store.settings.appSettings[music]?.route, .selectedDevice("usb"))
        XCTAssertEqual(store.settings.deviceSettings["usb"]?.eq.gains[1] ?? 0, 6, accuracy: 0.0001)
        XCTAssertTrue(backend.commands.contains(.setVolume(music, 0.33)))
        XCTAssertTrue(backend.commands.contains(.setRoute(music, .selectedDevice("usb"))))
        XCTAssertTrue(backend.commands.contains {
            if case let .setOutputEQ("usb", curve) = $0 { return curve.gains[1] == 6 }
            return false
        })

        let reloaded = try SettingsStore(settingsURL: settingsURL).load()
        XCTAssertEqual(reloaded.version, PersistedSettings.currentVersion)
        XCTAssertEqual(reloaded.appSettings[music]?.volume ?? -1, 0.33, accuracy: 0.0001)
        XCTAssertEqual(reloaded.appSettings[music]?.eq.gains[4] ?? 0, -2, accuracy: 0.0001)
        XCTAssertEqual(reloaded.appSettings[music]?.route, .selectedDevice("usb"))
        XCTAssertEqual(reloaded.appSettings[safari]?.isMuted, true)
        XCTAssertEqual(reloaded.deviceSettings["usb"]?.eq.gains[1] ?? 0, 6, accuracy: 0.0001)
        XCTAssertEqual(reloaded.pinnedAppIDs, [music])
        XCTAssertEqual(
            reloaded.profiles.first { $0.scope.outputDeviceID == "built-in" }?.appSettings[music]?.volume ?? -1,
            0.33,
            accuracy: 0.0001
        )

        _ = await store.shutdown()
    }

    private func copyFixture(_ name: String) throws -> URL {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        let destination = temporaryFileURL(prefix: "AuralisPipelineE2E", filename: name)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }
}
