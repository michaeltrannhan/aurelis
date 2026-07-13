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
        settings.appSettings[music] = AppAudioSettings(
            displayName: "Music",
            volume: 0.4,
            boost: .x2,
            route: .multiOutput(["usb", "hdmi"])
        )
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

    func testVersionOneDefaultMockSettingsMigrateToCoreAudioDiscovery() throws {
        let url = uniqueSettingsURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let json = """
        {
          "version": 1,
          "customization": {
            "appearance": "system",
            "backendMode": "mock",
            "defaultNewAppVolume": 1,
            "eqGainRange": 12,
            "popupDensity": "comfortable",
            "showInactiveApps": true,
            "volumeStep": 0.05
          },
          "appSettings": [],
          "pinnedAppIDs": [],
          "ignoredAppIDs": []
        }
        """
        try Data(json.utf8).write(to: url)
        let store = SettingsStore(settingsURL: url)

        let settings = try store.load()

        XCTAssertEqual(settings.version, PersistedSettings.currentVersion)
        XCTAssertEqual(settings.customization.backendMode, .coreAudioDiscovery)
    }

    func testOlderSettingsDefaultOnboardingToIncomplete() throws {
        let data = Data("{\"version\":2}".utf8)
        let decoded = try JSONDecoder().decode(PersistedSettings.self, from: data)
        XCTAssertEqual(decoded.version, PersistedSettings.currentVersion)
        XCTAssertFalse(decoded.hasCompletedOnboarding)
    }

    func testEnforcedBackendModeNormalizesAndMigratesPersistedMockMode() throws {
        let url = uniqueSettingsURL()
        let unrestrictedStore = SettingsStore(settingsURL: url)
        var settings = PersistedSettings()
        settings.customization.backendMode = .mock
        try unrestrictedStore.save(settings)

        let productionStore = SettingsStore(
            settingsURL: url,
            enforcedBackendMode: .coreAudioDiscovery
        )

        XCTAssertEqual(try productionStore.load().customization.backendMode, .coreAudioDiscovery)
        XCTAssertEqual(try unrestrictedStore.load().customization.backendMode, .coreAudioDiscovery)
    }

    func testEnforcedBackendModeAlsoNormalizesFutureSaves() throws {
        let url = uniqueSettingsURL()
        let productionStore = SettingsStore(
            settingsURL: url,
            enforcedBackendMode: .coreAudioDiscovery
        )
        var settings = PersistedSettings()
        settings.customization.backendMode = .mock

        try productionStore.save(settings)

        XCTAssertEqual(
            try SettingsStore(settingsURL: url).load().customization.backendMode,
            .coreAudioDiscovery
        )
    }

    @MainActor
    func testRepositoryDebouncesToLatestSettingsAndFlushes() async throws {
        let url = uniqueSettingsURL()
        let repository = AudioSettingsRepository(store: SettingsStore(settingsURL: url))
        var first = PersistedSettings()
        first.hasCompletedOnboarding = false
        var latest = first
        latest.hasCompletedOnboarding = true

        repository.scheduleSave(first, debounceNanoseconds: 80_000_000)
        repository.scheduleSave(latest, debounceNanoseconds: 80_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertTrue(try repository.load().hasCompletedOnboarding)

        latest.hasCompletedOnboarding = false
        repository.scheduleSave(latest, debounceNanoseconds: 1_000_000_000)
        try repository.flush()
        XCTAssertFalse(try repository.load().hasCompletedOnboarding)
    }

    private func uniqueSettingsURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("EQMacRepTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("settings.json")
    }
}
