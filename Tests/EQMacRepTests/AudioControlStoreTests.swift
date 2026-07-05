import XCTest
@testable import EQMacRep

@MainActor
final class AudioControlStoreTests: XCTestCase {
    func testRefreshCreatesDefaultSettingsForBackendApps() throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let backend = MockAudioBackend(apps: [
            AudioAppSnapshot(identity: music, displayName: "Music", bundleIdentifier: music.rawValue, level: 0.6)
        ])
        let store = try makeStore(backend: backend)

        try store.refresh()

        XCTAssertEqual(store.displayRows.count, 1)
        XCTAssertEqual(store.displayRows[0].displayName, "Music")
        XCTAssertEqual(store.displayRows[0].settings.volume, 1)
        XCTAssertEqual(store.displayRows[0].level, 0.6)
        XCTAssertEqual(store.settings.appSettings[music]?.displayName, "Music")
    }

    func testIgnoredAppsAreHiddenAndPersisted() throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let backend = MockAudioBackend(apps: [
            AudioAppSnapshot(identity: music, displayName: "Music", bundleIdentifier: music.rawValue)
        ])
        let store = try makeStore(backend: backend)
        try store.refresh()

        try store.ignore(music)

        XCTAssertTrue(store.displayRows.isEmpty)
        XCTAssertTrue(store.settings.ignoredAppIDs.contains(music))
        XCTAssertTrue(try store.settingsStore.load().ignoredAppIDs.contains(music))
    }

    func testPinnedInactiveAppStaysVisibleWhenInactiveAppsAreHidden() throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let backend = MockAudioBackend(apps: [
            AudioAppSnapshot(identity: music, displayName: "Music", bundleIdentifier: music.rawValue, isActive: false)
        ])
        let store = try makeStore(backend: backend)
        store.settings.customization.showInactiveApps = false
        try store.refresh()

        XCTAssertTrue(store.displayRows.isEmpty)

        try store.pin(music)

        XCTAssertEqual(store.displayRows.map(\.identity), [music])
        XCTAssertTrue(store.displayRows[0].isPinned)
        XCTAssertFalse(store.displayRows[0].isActive)
    }

    func testVolumeMuteBoostAndEQMutationsPersistAndNotifyBackend() throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let backend = MockAudioBackend(apps: [
            AudioAppSnapshot(identity: music, displayName: "Music", bundleIdentifier: music.rawValue)
        ])
        let store = try makeStore(backend: backend)
        try store.refresh()

        try store.setVolume(0.25, for: music)
        try store.setMuted(true, for: music)
        try store.setBoost(.x3, for: music)
        try store.setEQGain(6, band: 0, for: music)

        let saved = try store.settingsStore.load()
        XCTAssertEqual(saved.appSettings[music]?.volume, 0.25)
        XCTAssertEqual(saved.appSettings[music]?.isMuted, true)
        XCTAssertEqual(saved.appSettings[music]?.boost, .x3)
        XCTAssertEqual(saved.appSettings[music]?.eq.gains[0], 6)
        XCTAssertEqual(
            backend.commands,
            [
                .setVolume(music, 0.25),
                .setMuted(music, true),
                .setBoost(music, .x3),
                .setEQ(music, saved.appSettings[music]!.eq)
            ]
        )
    }

    private func makeStore(backend: MockAudioBackend) throws -> AudioControlStore {
        let store = SettingsStore(settingsURL: uniqueSettingsURL())
        return try AudioControlStore(settingsStore: store, backend: backend)
    }

    private func uniqueSettingsURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("EQMacRepStoreTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("settings.json")
    }
}
