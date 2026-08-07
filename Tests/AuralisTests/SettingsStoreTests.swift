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

    func testVersionFourFlatProfileMigratesToActiveGlobalProfile() throws {
        let profileID = "11111111-1111-1111-1111-111111111111"
        let data = Data(
            """
            {
              "version": 4,
              "profiles": [{
                "id": "\(profileID)",
                "name": "Legacy Home",
                "appSettings": {},
                "deviceSettings": {},
                "preferredOutputDeviceID": "home-speaker"
              }],
              "activeProfileID": "\(profileID)"
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(PersistedSettings.self, from: data)

        XCTAssertEqual(decoded.profiles.first?.scope, .global)
        XCTAssertFalse(decoded.profiles.first?.activatesAutomatically ?? true)
        XCTAssertEqual(decoded.activeGlobalProfileID?.uuidString, profileID)
        XCTAssertNil(decoded.activeLocalProfileID)
        XCTAssertEqual(decoded.activeProfileID?.uuidString, profileID)
    }

    func testVersionSixOutputPresetsMigrateToOneConfigurationWithoutLosingPresetApps() throws {
        let selectedID = "11111111-1111-1111-1111-111111111111"
        let alternateID = "22222222-2222-2222-2222-222222222222"
        let data = Data(
            """
            {
              "version": 6,
              "profiles": [
                {
                  "id": "\(selectedID)",
                  "name": "Home",
                  "scope": {"kind": "outputDevice", "deviceID": "home"},
                  "activatesAutomatically": false,
                  "appSettings": [
                    "music", {"displayName": "Music", "volume": 0.4}
                  ],
                  "deviceSettings": {
                    "home": {"displayName": "Home Speaker", "volume": 0.6}
                  }
                },
                {
                  "id": "\(alternateID)",
                  "name": "Home Quiet",
                  "scope": {"kind": "outputDevice", "deviceID": "home"},
                  "activatesAutomatically": true,
                  "appSettings": [
                    "music", {"displayName": "Music", "volume": 0.2}
                  ],
                  "deviceSettings": {
                    "home": {"displayName": "Home Speaker", "volume": 0.3}
                  }
                }
              ],
              "activeLocalProfileID": "\(selectedID)"
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(PersistedSettings.self, from: data)
        let selected = try XCTUnwrap(
            decoded.profiles.first { $0.id.uuidString == selectedID }
        )
        let preservedPreset = try XCTUnwrap(
            decoded.profiles.first { $0.id.uuidString == alternateID }
        )

        XCTAssertEqual(selected.scope, .outputDevice("home"))
        XCTAssertTrue(selected.activatesAutomatically)
        XCTAssertTrue(preservedPreset.scope.isGlobal)
        XCTAssertFalse(preservedPreset.activatesAutomatically)
        XCTAssertTrue(preservedPreset.deviceSettings.isEmpty)
        XCTAssertEqual(
            preservedPreset.appSettings[AudioAppIdentity(rawValue: "music")]?.volume,
            0.2
        )
        XCTAssertEqual(decoded.activeLocalProfileID?.uuidString, selectedID)
        XCTAssertEqual(
            decoded.profiles.first { $0.id == decoded.activeGlobalProfileID }?.name,
            "Global Default"
        )
    }

    func testVersionSixMigrationPersistsAStableFlatGlobalFallback() throws {
        let url = uniqueSettingsURL()
        let localID = "11111111-1111-1111-1111-111111111111"
        let data = Data(
            """
            {
              "version": 6,
              "appSettings": [
                "music", {
                  "displayName": "Music",
                  "volume": 0.25,
                  "isMuted": true,
                  "boost": 3,
                  "eq": {"gains": [0, 0, 4], "range": 12}
                }
              ],
              "profiles": [{
                "id": "\(localID)",
                "name": "Home",
                "scope": {"kind": "outputDevice", "deviceID": "home"},
                "activatesAutomatically": true,
                "appSettings": [
                  "music", {"displayName": "Music", "volume": 0.25}
                ],
                "deviceSettings": {
                  "home": {"displayName": "Home Speaker", "volume": 0.6}
                }
              }],
              "activeLocalProfileID": "\(localID)"
            }
            """.utf8
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
        let store = SettingsStore(settingsURL: url)

        let firstLoad = try store.load()
        let firstFallback = try XCTUnwrap(
            firstLoad.profiles.first { $0.id == firstLoad.activeGlobalProfileID }
        )
        let music = AudioAppIdentity(rawValue: "music")
        XCTAssertEqual(firstFallback.name, "Global Default")
        XCTAssertEqual(firstFallback.appSettings[music]?.volume ?? -1, 1, accuracy: 0.001)
        XCTAssertFalse(firstFallback.appSettings[music]?.isMuted ?? true)
        XCTAssertEqual(firstFallback.appSettings[music]?.boost, .x1)
        XCTAssertEqual(firstFallback.appSettings[music]?.eq.gains, Array(repeating: 0, count: 10))

        let persistedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertEqual(persistedObject["version"] as? Int, PersistedSettings.currentVersion)
        let secondLoad = try store.load()
        XCTAssertEqual(secondLoad.activeGlobalProfileID, firstFallback.id)
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

    func testProfileQueriesKeepActiveGlobalFirstAndMatchMixerContents() {
        let music = AudioAppIdentity(rawValue: "music")
        let appSettings = [
            music: AppAudioSettings(displayName: "Music", volume: 0.5)
        ]
        let alpha = AudioProfile(
            name: "Alpha",
            appSettings: appSettings,
            deviceSettings: [:],
            preferredOutputDeviceID: nil
        )
        let active = AudioProfile(
            name: "Zulu",
            appSettings: appSettings,
            deviceSettings: [:],
            preferredOutputDeviceID: nil
        )
        let output = AudioProfile(
            name: "Alpha",
            scope: .outputDevice("home"),
            activatesAutomatically: true,
            appSettings: appSettings,
            deviceSettings: [:],
            preferredOutputDeviceID: "home"
        )
        let settings = PersistedSettings(
            profiles: [alpha, output, active],
            activeGlobalProfileID: active.id
        )

        XCTAssertEqual(settings.globalProfilesForDisplay.map(\.id), [active.id, alpha.id])
        XCTAssertTrue(output.matchesMixerPreset(alpha))
        XCTAssertFalse(output.matchesMixerPreset(active))
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
}
