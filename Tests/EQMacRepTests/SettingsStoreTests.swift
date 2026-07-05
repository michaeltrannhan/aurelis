import XCTest
@testable import EQMacRep

final class SettingsStoreTests: XCTestCase {
    func testLoadMissingFileReturnsDefaults() throws {
        let store = SettingsStore(settingsURL: uniqueSettingsURL())

        let settings = try store.load()

        XCTAssertEqual(settings.version, PersistedSettings.currentVersion)
        XCTAssertEqual(settings.customization, AppCustomization())
        XCTAssertTrue(settings.appSettings.isEmpty)
        XCTAssertTrue(settings.pinnedAppIDs.isEmpty)
        XCTAssertTrue(settings.ignoredAppIDs.isEmpty)
    }

    func testSaveAndLoadRoundTrip() throws {
        let url = uniqueSettingsURL()
        let store = SettingsStore(settingsURL: url)
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let chat = AudioAppIdentity(rawValue: "com.example.Chat")
        var settings = PersistedSettings()
        settings.customization = AppCustomization(
            appearance: .dark,
            popupDensity: .spacious,
            defaultNewAppVolume: 0.35,
            eqGainRange: .db18,
            volumeStep: .twoPercent,
            showInactiveApps: false
        )
        settings.appSettings[music] = AppAudioSettings(displayName: "Music", volume: 0.4, boost: .x2)
        settings.pinnedAppIDs = [music]
        settings.ignoredAppIDs = [chat]

        try store.save(settings)
        let loaded = try store.load()

        XCTAssertEqual(loaded, settings)
    }

    func testMalformedJSONFallsBackToDefaultsAndCanBeSaved() throws {
        let url = uniqueSettingsURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{ not json".utf8).write(to: url)
        let store = SettingsStore(settingsURL: url)

        var loaded = try store.load()

        XCTAssertEqual(loaded, PersistedSettings())

        loaded.customization = AppCustomization(defaultNewAppVolume: 0.25)
        try store.save(loaded)

        XCTAssertEqual(try store.load().customization.defaultNewAppVolume, 0.25)
    }

    private func uniqueSettingsURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("EQMacRepTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("settings.json")
    }
}
