import XCTest
@testable import Auralis

final class SettingsStoreTests: XCTestCase {
    func testTolerantDecodingNormalizesSettingsAndDeduplicatesOrdering() throws {
        let data = Data(
            """
            {
              "version": 3,
              "customization": {
                "appearance": "unknown",
                "defaultNewAppVolume": "NaN",
                "eqGainRange": 999
              },
              "appSettings": {
                "com.example.Music": {
                  "displayName": "Music",
                  "volume": "NaN",
                  "boost": 99,
                  "eq": {
                    "gains": ["NaN", 50, -50],
                    "range": 12
                  },
                  "route": {
                    "multiOutput": {"_0": ["usb", "usb", ""]}
                  }
                }
              },
              "pinnedAppIDs": ["com.example.Music", {"rawValue": "com.example.Music"}, "", 42],
              "ignoredAppIDs": ["com.example.Chat", "com.example.Chat"],
              "appDisplayOrder": ["com.example.Music", "com.example.Music", "com.example.Chat", null]
            }
            """.utf8
        )

        let settings = try JSONDecoder().decode(PersistedSettings.self, from: data)
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let chat = AudioAppIdentity(rawValue: "com.example.Chat")

        XCTAssertEqual(settings.version, PersistedSettings.currentVersion)
        XCTAssertEqual(settings.customization.appearance, .system)
        XCTAssertEqual(settings.customization.defaultNewAppVolume, 1)
        XCTAssertEqual(settings.customization.eqGainRange, .db12)
        XCTAssertEqual(settings.appSettings[music]?.volume, 1)
        XCTAssertEqual(settings.appSettings[music]?.boost, .x1)
        XCTAssertEqual(settings.appSettings[music]?.eq.gains, [0, 12, -12, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(settings.appSettings[music]?.route, .multiOutput(["usb"]))
        XCTAssertEqual(settings.pinnedAppIDs, [music])
        XCTAssertEqual(settings.ignoredAppIDs, [chat])
        XCTAssertEqual(settings.appDisplayOrder, [music, chat])
    }

    func testLegacyAlternatingAppSettingsDeduplicatesIdentityWithoutTrap() throws {
        let data = Data(
            """
            {
              "version": 3,
              "appSettings": [
                "com.example.Music", {"displayName": "Music", "volume": 0.2},
                {"rawValue": "com.example.Music"}, {"displayName": "Music", "volume": 0.8}
              ]
            }
            """.utf8
        )

        let settings = try JSONDecoder().decode(PersistedSettings.self, from: data)

        XCTAssertEqual(settings.appSettings.count, 1)
        XCTAssertEqual(
            settings.appSettings[AudioAppIdentity(rawValue: "com.example.Music")]?.volume,
            0.8
        )
    }

    func testMalformedSelectedRouteFallsBackToFollowDefault() throws {
        let data = Data("{\"selectedDevice\":{\"_0\":\"\"}}".utf8)

        let route = try JSONDecoder().decode(DeviceRoute.self, from: data)

        XCTAssertEqual(route, .followDefault)
    }

    func testLoadMissingFileReturnsDefaults() throws {
        let store = SettingsStore(settingsURL: uniqueSettingsURL())

        let settings = try store.load()

        XCTAssertEqual(settings.version, PersistedSettings.currentVersion)
        XCTAssertEqual(settings.customization, AppCustomization())
        XCTAssertTrue(settings.appSettings.isEmpty)
        XCTAssertTrue(settings.pinnedAppIDs.isEmpty)
        XCTAssertTrue(settings.ignoredAppIDs.isEmpty)
    }

    func testLegacyOnlySettingsLoadAndMigrateWithoutRemovingRollbackCopy() throws {
        let urls = try uniqueMigrationURLs()
        var legacySettings = PersistedSettings()
        legacySettings.customization.defaultNewAppVolume = 0.37
        legacySettings.hasCompletedOnboarding = true
        try SettingsStore(settingsURL: urls.legacy).save(legacySettings)
        let legacyData = try Data(contentsOf: urls.legacy)

        let migrated = try SettingsStore(
            settingsURL: urls.current,
            legacySettingsURL: urls.legacy
        ).load()

        XCTAssertEqual(migrated, legacySettings)
        XCTAssertEqual(try SettingsStore(settingsURL: urls.current).load(), legacySettings)
        XCTAssertEqual(try Data(contentsOf: urls.legacy), legacyData)
    }

    func testCurrentSettingsWinWhenCurrentAndLegacyFilesBothExist() throws {
        let urls = try uniqueMigrationURLs()
        var currentSettings = PersistedSettings()
        currentSettings.customization.defaultNewAppVolume = 0.21
        var legacySettings = PersistedSettings()
        legacySettings.customization.defaultNewAppVolume = 0.84
        try SettingsStore(settingsURL: urls.current).save(currentSettings)
        try SettingsStore(settingsURL: urls.legacy).save(legacySettings)
        let currentData = try Data(contentsOf: urls.current)
        let legacyData = try Data(contentsOf: urls.legacy)

        let loaded = try SettingsStore(
            settingsURL: urls.current,
            legacySettingsURL: urls.legacy
        ).load()

        XCTAssertEqual(loaded, currentSettings)
        XCTAssertEqual(try Data(contentsOf: urls.current), currentData)
        XCTAssertEqual(try Data(contentsOf: urls.legacy), legacyData)
    }

    func testLegacySettingsStillLoadWhenMigrationDestinationCannotBeCreated() throws {
        let urls = try uniqueMigrationURLs()
        var legacySettings = PersistedSettings()
        legacySettings.customization.defaultNewAppVolume = 0.63
        try SettingsStore(settingsURL: urls.legacy).save(legacySettings)
        let legacyData = try Data(contentsOf: urls.legacy)
        let blockedDirectory = urls.current.deletingLastPathComponent()
        try Data("not a directory".utf8).write(to: blockedDirectory)

        let loaded = try SettingsStore(
            settingsURL: urls.current,
            legacySettingsURL: urls.legacy
        ).load()

        XCTAssertEqual(loaded, legacySettings)
        XCTAssertFalse(FileManager.default.fileExists(atPath: urls.current.path))
        XCTAssertEqual(try Data(contentsOf: urls.legacy), legacyData)
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

    func testMalformedJSONIsQuarantinedBeforeDefaultsCanBeSaved() throws {
        let url = uniqueSettingsURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = Data("{ not json".utf8)
        try original.write(to: url)
        let store = SettingsStore(settingsURL: url)

        let result = try store.loadWithRecovery()
        var loaded = result.settings

        XCTAssertEqual(loaded, PersistedSettings())
        let notice = try XCTUnwrap(result.recoveryNotice)
        XCTAssertEqual(notice.originalURL, url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: notice.quarantineURL), original)

        loaded.customization = AppCustomization(defaultNewAppVolume: 0.25)
        try store.save(loaded)

        XCTAssertEqual(try store.load().customization.defaultNewAppVolume, 0.25)
    }

    func testTruncatedSettingsArePreservedInQuarantine() throws {
        let url = uniqueSettingsURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("{\"version\":3,\"appSettings\":[".utf8)
        try original.write(to: url)

        let result = try SettingsStore(settingsURL: url).loadWithRecovery()

        XCTAssertEqual(result.settings, PersistedSettings())
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.recoveryNotice).quarantineURL), original)
    }

    func testFutureVersionIsRejectedWithoutRewritingOrQuarantining() throws {
        let url = uniqueSettingsURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("{\"version\":999,\"customization\":{}}".utf8)
        try original.write(to: url)
        let store = SettingsStore(settingsURL: url, enforcedBackendMode: .coreAudioDiscovery)

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(
                error as? SettingsStoreError,
                .futureVersion(found: 999, supported: PersistedSettings.currentVersion)
            )
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
        let siblingNames = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertFalse(siblingNames.contains { $0.contains(".corrupt-") })
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

    func testPersistenceActorDebouncesToLatestSettingsAndFlushes() async throws {
        let url = uniqueSettingsURL()
        let persistence = SettingsPersistenceActor(store: SettingsStore(settingsURL: url))
        var first = PersistedSettings()
        first.hasCompletedOnboarding = false
        var latest = first
        latest.hasCompletedOnboarding = true

        await persistence.schedule(first, debounceNanoseconds: 80_000_000)
        await persistence.schedule(latest, debounceNanoseconds: 80_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        await persistence.waitForScheduledWork()
        XCTAssertTrue(try SettingsStore(settingsURL: url).load().hasCompletedOnboarding)

        latest.hasCompletedOnboarding = false
        await persistence.schedule(latest, debounceNanoseconds: 1_000_000_000)
        try await persistence.flush()
        XCTAssertFalse(try SettingsStore(settingsURL: url).load().hasCompletedOnboarding)
    }

    func testPersistenceActorRetainsDirtyStateAndRetriesAfterFilesystemFaultIsRemoved() async throws {
        let url = uniqueSettingsURL()
        let blockedParent = url.deletingLastPathComponent()
        try Data("not a directory".utf8).write(to: blockedParent)
        defer { try? FileManager.default.removeItem(at: blockedParent) }
        let persistence = SettingsPersistenceActor(
            store: SettingsStore(settingsURL: url),
            retryDelaysNanoseconds: [20_000_000, 40_000_000]
        )
        var settings = PersistedSettings()
        settings.hasCompletedOnboarding = true

        do {
            _ = try await persistence.commit(settings)
            XCTFail("Expected the blocked parent to reject the write")
        } catch {}
        var diagnostics = await persistence.diagnostics()
        XCTAssertTrue(diagnostics.hasDirtyState)
        XCTAssertNotNil(diagnostics.lastErrorDescription)
        XCTAssertEqual(diagnostics.retryAttemptCount, 1)

        try FileManager.default.removeItem(at: blockedParent)
        try FileManager.default.createDirectory(at: blockedParent, withIntermediateDirectories: true)
        await persistence.waitForScheduledWork()

        diagnostics = await persistence.diagnostics()
        XCTAssertFalse(diagnostics.hasDirtyState)
        XCTAssertNil(diagnostics.lastErrorDescription)
        XCTAssertEqual(diagnostics.retryAttemptCount, 0)
        XCTAssertTrue(try SettingsStore(settingsURL: url).load().hasCompletedOnboarding)
    }

    func testPersistenceActorBoundsRetriesButKeepsLatestDirtySnapshot() async throws {
        let url = uniqueSettingsURL()
        let blockedParent = url.deletingLastPathComponent()
        try Data("not a directory".utf8).write(to: blockedParent)
        defer { try? FileManager.default.removeItem(at: blockedParent) }
        let persistence = SettingsPersistenceActor(
            store: SettingsStore(settingsURL: url),
            retryDelaysNanoseconds: [5_000_000, 10_000_000]
        )

        do {
            _ = try await persistence.commit(PersistedSettings())
            XCTFail("Expected the blocked parent to reject the write")
        } catch {}
        await persistence.waitForScheduledWork()

        let diagnostics = await persistence.diagnostics()
        XCTAssertTrue(diagnostics.hasDirtyState)
        XCTAssertNotNil(diagnostics.lastErrorDescription)
        XCTAssertEqual(diagnostics.retryAttemptCount, 2)
    }

    func testPersistenceActorWritesOnlyDirtySnapshots() async throws {
        let url = uniqueSettingsURL()
        let store = SettingsStore(settingsURL: url)
        let persistence = SettingsPersistenceActor(store: store)
        _ = try await persistence.loadWithRecovery()
        let baseline = PersistedSettings()

        let baselineWritten = try await persistence.commit(baseline)
        XCTAssertFalse(baselineWritten)
        var changed = baseline
        changed.hasCompletedOnboarding = true
        let changedWritten = try await persistence.commit(changed)
        let duplicateWritten = try await persistence.commit(changed)
        XCTAssertTrue(changedWritten)
        XCTAssertFalse(duplicateWritten)

        let diagnostics = await persistence.diagnostics()
        XCTAssertEqual(diagnostics.attemptedWriteCount, 1)
        XCTAssertEqual(diagnostics.successfulWriteCount, 1)
        XCTAssertFalse(diagnostics.hasDirtyState)
    }

    private func uniqueSettingsURL() -> URL {
        temporaryFileURL(prefix: "AuralisSettings", filename: "settings.json")
    }

    private func uniqueMigrationURLs() throws -> (current: URL, legacy: URL) {
        let root = try temporaryDirectory(prefix: "AuralisSettingsMigration")
        return (
            current: root
                .appendingPathComponent("Auralis", isDirectory: true)
                .appendingPathComponent("settings.json"),
            legacy: root
                .appendingPathComponent("EQMacRep", isDirectory: true)
                .appendingPathComponent("settings.json")
        )
    }
}
