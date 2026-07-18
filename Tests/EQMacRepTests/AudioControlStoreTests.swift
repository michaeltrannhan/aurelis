import Combine
import XCTest
@testable import EQMacRep

@MainActor
final class AudioControlStoreTests: XCTestCase {
    func testCorruptSettingsRecoveryIsPublishedAndOriginalIsQuarantined() async throws {
        let url = uniqueSettingsURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("{ truncated".utf8)
        try original.write(to: url)

        let store = try AudioControlStore(
            settingsStore: SettingsStore(settingsURL: url),
            backend: MockAudioBackend()
        )
        await store.waitUntilReady()

        let issue = try XCTUnwrap(store.issues.first { $0.id == "settings-recovery" })
        XCTAssertEqual(issue.severity, .warning)
        XCTAssertTrue(issue.message.contains("preserved"))
        if case .degraded = store.operationState {} else { XCTFail("Expected degraded recovery state") }
        let quarantines = try FileManager.default.contentsOfDirectory(
            at: url.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".corrupt-") }
        XCTAssertEqual(quarantines.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(quarantines.first)), original)
    }

    func testFutureSettingsVersionIsPublishedAndAllWritesRemainBlocked() async throws {
        let url = uniqueSettingsURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("{\"version\":999,\"unknownFutureField\":true}".utf8)
        try original.write(to: url)
        let store = try AudioControlStore(
            settingsStore: SettingsStore(settingsURL: url),
            backend: MockAudioBackend()
        )
        await store.waitUntilReady()

        let issue = try XCTUnwrap(store.issues.first { $0.id == "settings-version" })
        XCTAssertEqual(issue.severity, .error)
        XCTAssertTrue(issue.message.contains("left unchanged"))
        var customization = store.settings.customization
        customization.appearance = .dark
        await assertThrows { try await store.applyCustomization(customization) }
        XCTAssertEqual(try Data(contentsOf: url), original)
        let siblingNames = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertFalse(siblingNames.contains { $0.contains(".corrupt-") })
    }

    func testRefreshCoalescesDuplicateBackendIdentitiesAndPersistedOrder() async throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let backend = MockAudioBackend(apps: [
            AudioAppSnapshot(identity: music, displayName: "Music", isActive: false, level: 0.2),
            AudioAppSnapshot(identity: music, displayName: "Duplicate", isActive: true, level: 0.8)
        ])
        let store = try makeStore(backend: backend)
        await store.waitUntilReady()
        store.settings.appDisplayOrder = [music, music]

        try await store.refresh()

        XCTAssertEqual(store.appSnapshots.count, 1)
        XCTAssertEqual(store.displayRows.count, 1)
        XCTAssertEqual(store.displayRows[0].displayName, "Music")
        XCTAssertTrue(store.displayRows[0].isActive)
        XCTAssertEqual(store.displayRows[0].level, 0.8)
        XCTAssertEqual(store.settings.appDisplayOrder, [music])
    }

    func testRefreshCreatesDefaultSettingsForBackendApps() async throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let backend = MockAudioBackend(apps: [
            AudioAppSnapshot(identity: music, displayName: "Music", bundleIdentifier: music.rawValue, level: 0.6)
        ])
        let store = try AudioControlStore(settingsStore: SettingsStore(settingsURL: uniqueSettingsURL()), backend: backend)

        try await store.refresh()

        XCTAssertEqual(store.displayRows.count, 1)
        XCTAssertEqual(store.displayRows[0].displayName, "Music")
        XCTAssertEqual(store.displayRows[0].settings.volume, 1)
        XCTAssertEqual(store.displayRows[0].level, 0.6)
        XCTAssertEqual(store.settings.appSettings[music]?.displayName, "Music")
    }

    func testLevelObservationPublishesRealBackendMeterValuesWithoutFullRefresh() async throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let backend = LevelProvidingBackend(apps: [
            AudioAppSnapshot(identity: music, displayName: "Music")
        ])
        let store = try AudioControlStore(
            settingsStore: SettingsStore(settingsURL: uniqueSettingsURL()),
            backend: backend,
            permissionClient: grantedClient()
        )
        try await store.refresh()
        let updated = expectation(description: "meter level published")
        let cancellable = store.$displayRows.sink { rows in
            if rows.first?.level == 0.75 { updated.fulfill() }
        }

        await store.startBackendObservation()
        backend.levels = [music: 0.75]
        await fulfillment(of: [updated], timeout: 1)
        await store.stopBackendObservation()

        XCTAssertEqual(store.displayRows.first?.level, 0.75)
        XCTAssertEqual(backend.fetchCount, 1, "Meter polling must not repeat process/device discovery")
        withExtendedLifetime(cancellable) {}
    }

    func testIgnoredAppsAreHiddenAndPersisted() async throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let backend = MockAudioBackend(apps: [
            AudioAppSnapshot(identity: music, displayName: "Music", bundleIdentifier: music.rawValue)
        ])
        let store = try AudioControlStore(settingsStore: SettingsStore(settingsURL: uniqueSettingsURL()), backend: backend)
        try await store.refresh()

        try await store.ignore(music)

        XCTAssertTrue(store.displayRows.isEmpty)
        XCTAssertTrue(store.settings.ignoredAppIDs.contains(music))
        XCTAssertTrue(try store.settingsStore.load().ignoredAppIDs.contains(music))
    }

    func testPinnedInactiveAppStaysVisibleWhenInactiveAppsAreHidden() async throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let backend = MockAudioBackend(apps: [
            AudioAppSnapshot(identity: music, displayName: "Music", bundleIdentifier: music.rawValue, isActive: false)
        ])
        let store = try makeStore(backend: backend)
        await store.waitUntilReady()
        store.settings.customization.showInactiveApps = false
        try await store.refresh()

        XCTAssertTrue(store.displayRows.isEmpty)

        try await store.pin(music)

        XCTAssertEqual(store.displayRows.map(\.identity), [music])
        XCTAssertTrue(store.displayRows[0].isPinned)
        XCTAssertFalse(store.displayRows[0].isActive)
    }

    func testVolumeMuteBoostAndEQMutationsPersistAndNotifyBackend() async throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let backend = MockAudioBackend(apps: [
            AudioAppSnapshot(identity: music, displayName: "Music", bundleIdentifier: music.rawValue)
        ])
        let store = try makeStore(backend: backend)
        try await store.refresh()

        try await store.setVolume(0.25, for: music)
        try await store.setMuted(true, for: music)
        try await store.setBoost(.x3, for: music)
        try await store.setEQGain(6, band: 0, for: music)

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

    func testBackendModeChangeReplacesBackendAndRefreshesRows() async throws {
        let mockIdentity = AudioAppIdentity(rawValue: "com.example.Mock")
        let realIdentity = AudioAppIdentity(rawValue: "com.example.Real")
        let initialBackend = MockAudioBackend(apps: [
            AudioAppSnapshot(identity: mockIdentity, displayName: "Mock App")
        ])
        let replacementBackend = LockedValue(MockAudioBackend(apps: [
            AudioAppSnapshot(identity: realIdentity, displayName: "Real App")
        ]))
        let settingsStore = SettingsStore(settingsURL: uniqueSettingsURL())
        var settings = PersistedSettings()
        settings.customization.backendMode = .mock
        try settingsStore.save(settings)
        let requestedModes = LockedValue<[BackendMode]>([])
        let store = try AudioControlStore(
            settingsStore: settingsStore,
            backend: initialBackend,
            backendFactory: { mode in
                requestedModes.withValue { $0.append(mode) }
                return replacementBackend.value
            }
        )
        try await store.refresh()

        var customization = store.settings.customization
        customization.backendMode = .coreAudioDiscovery
        try await store.applyCustomization(customization)

        XCTAssertEqual(requestedModes.value, [.coreAudioDiscovery])
        XCTAssertEqual(store.displayRows.map(\.identity), [realIdentity])
    }

    func testRefreshSynchronizesTapsWithIgnoredApps() async throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let backend = TapSynchronizingMockBackend(apps: [
            AudioAppSnapshot(identity: music, displayName: "Music")
        ])
        let store = try AudioControlStore(
            settingsStore: SettingsStore(settingsURL: uniqueSettingsURL()),
            backend: backend,
            permissionClient: grantedClient()
        )

        try await store.refresh()
        try await store.ignore(music)

        XCTAssertEqual(backend.synchronizedActiveIDs, [music])
        XCTAssertEqual(backend.synchronizedIgnoredIDs, [music])
        XCTAssertEqual(backend.tornDownIDs, [music])
    }

    func testRefreshKeepsRowsWhenTapSynchronizationFails() async throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let backend = TapSynchronizingMockBackend(apps: [
            AudioAppSnapshot(identity: music, displayName: "Music")
        ])
        backend.syncError = NSError(domain: "EQMacRepTests", code: 17)
        let store = try AudioControlStore(
            settingsStore: SettingsStore(settingsURL: uniqueSettingsURL()),
            backend: backend,
            permissionClient: grantedClient()
        )

        try await store.refresh()

        XCTAssertEqual(store.displayRows.map(\.identity), [music])
        XCTAssertTrue(store.statusMessage.contains("Tap setup error"))
    }

    func testBackendUpdateEventRefreshesSnapshots() async throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let safari = AudioAppIdentity(rawValue: "com.example.Safari")
        let backend = EventingBackend(snapshots: [
            AudioBackendSnapshot(apps: [
                AudioAppSnapshot(identity: music, displayName: "Music")
            ]),
            AudioBackendSnapshot(apps: [
                AudioAppSnapshot(identity: music, displayName: "Music"),
                AudioAppSnapshot(identity: safari, displayName: "Safari")
            ])
        ])
        let store = try AudioControlStore(
            settingsStore: SettingsStore(settingsURL: uniqueSettingsURL()),
            backend: backend
        )

        try await store.refresh()
        XCTAssertEqual(store.displayRows.map(\.identity), [music])

        await store.startBackendObservation(debounceNanoseconds: 1_000_000)
        let updated = expectation(description: "backend update published")
        let cancellable = store.$displayRows
            .dropFirst()
            .sink { rows in
                if rows.map(\.identity) == [music, safari] {
                    updated.fulfill()
                }
            }
        backend.emitUpdate()
        await fulfillment(of: [updated], timeout: 1)

        XCTAssertEqual(store.displayRows.map(\.identity), [music, safari])
        await store.stopBackendObservation()
        withExtendedLifetime(cancellable) {}
    }

    func testBackendObservationDebouncesEventBursts() async throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let backend = EventingBackend(
            repeatingSnapshot: AudioBackendSnapshot(apps: [
                AudioAppSnapshot(identity: music, displayName: "Music")
            ])
        )
        let store = try AudioControlStore(
            settingsStore: SettingsStore(settingsURL: uniqueSettingsURL()),
            backend: backend
        )
        try await store.refresh()
        let baselineFetches = backend.fetchCount
        let refreshed = expectation(description: "debounced topology refresh")
        backend.onFetch = { count in
            if count == baselineFetches + 1 {
                refreshed.fulfill()
            }
        }

        await store.startBackendObservation(debounceNanoseconds: 40_000_000)
        for _ in 0..<10 { backend.emitUpdate() }
        await fulfillment(of: [refreshed], timeout: 1)
        backend.onFetch = nil
        await store.stopBackendObservation()

        // Newest-only buffering plus debounce collapses the whole burst into
        // exactly one bounded refresh.
        XCTAssertEqual(backend.fetchCount - baselineFetches, 1)
        XCTAssertEqual(store.topologyRefreshCount, 1)
    }

    func testPermissionRefreshUpdatesPublishedStateAndStatus() async throws {
        let client = FakePermissionClient(state: AudioCapturePermissionState(
            screenCapture: .denied,
            audioUsageDescription: .present
        ))
        let store = try makeStore(backend: MockAudioBackend(), permissionClient: client)
        await store.waitUntilReady()

        store.refreshPermissionState()

        XCTAssertEqual(store.permissionState.summary, "Screen & System Audio Recording denied")
        XCTAssertEqual(store.statusMessage, "Screen & System Audio Recording denied")
    }

    func testDeniedPermissionGatesTapSynchronization() async throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let backend = TapSynchronizingMockBackend(apps: [
            AudioAppSnapshot(identity: music, displayName: "Music")
        ])
        let client = FakePermissionClient(state: AudioCapturePermissionState(
            screenCapture: .denied,
            audioUsageDescription: .present
        ))
        let store = try AudioControlStore(
            settingsStore: SettingsStore(settingsURL: uniqueSettingsURL()),
            backend: backend,
            permissionClient: client
        )

        try await store.refresh()

        // Taps must not be created; teardown-all is called instead as the safe path.
        XCTAssertTrue(backend.synchronizedActiveIDs.isEmpty)
        XCTAssertGreaterThanOrEqual(backend.tearDownAllCount, 1)
    }

    func testRouteMutationPersistsAndNotifiesBackend() async throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let backend = MockAudioBackend(apps: [
            AudioAppSnapshot(identity: music, displayName: "Music", bundleIdentifier: music.rawValue)
        ])
        let store = try makeStore(backend: backend)
        try await store.refresh()

        try await store.setRoute(.selectedDevice("built-in-output"), for: music)

        let saved = try store.settingsStore.load()
        XCTAssertEqual(saved.appSettings[music]?.route, .selectedDevice("built-in-output"))
        XCTAssertEqual(backend.commands.last, .setRoute(music, .selectedDevice("built-in-output")))
    }

    func testRefreshRestoresPersistedMultiOutputStateBeforeTapSynchronization() async throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        var eq = EQCurve()
        eq.setGain(4, at: 2)
        var restoredSettings = AppAudioSettings(
            displayName: "Music",
            volume: 0.35,
            isMuted: true,
            boost: .x3,
            eq: eq
        )
        // Simulate an older/non-normalized saved payload. Restoration should send
        // canonical route intent to the backend before it creates any tap.
        restoredSettings.route = .multiOutput(["usb", "usb", "hdmi"])

        let settingsStore = SettingsStore(settingsURL: uniqueSettingsURL())
        try settingsStore.save(PersistedSettings(appSettings: [music: restoredSettings]))
        let backend = RestoreOrderingBackend(apps: [
            AudioAppSnapshot(identity: music, displayName: "Music")
        ])
        let store = try AudioControlStore(
            settingsStore: settingsStore,
            backend: backend,
            permissionClient: grantedClient()
        )

        try await store.refresh()

        XCTAssertEqual(
            backend.events,
            [
                .command(.setRoute(music, .multiOutput(["usb", "hdmi"]))),
                .command(.setVolume(music, 0.35)),
                .command(.setMuted(music, true)),
                .command(.setBoost(music, .x3)),
                .command(.setEQ(music, eq)),
                .synchronize
            ]
        )

        try await store.refresh()
        XCTAssertEqual(backend.events.filter { if case .command = $0 { true } else { false } }.count, 5)
        XCTAssertEqual(backend.events.last, .synchronize)
    }

    func testBackendSwitchReplaysPersistedStateBeforeNewBackendSynchronization() async throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        var eq = EQCurve()
        eq.setGain(-3, at: 4)
        let restoredSettings = AppAudioSettings(
            displayName: "Music",
            volume: 0.4,
            isMuted: true,
            boost: .x2,
            eq: eq,
            route: .multiOutput(["usb", "hdmi"])
        )
        let settingsStore = SettingsStore(settingsURL: uniqueSettingsURL())
        try settingsStore.save(PersistedSettings(appSettings: [music: restoredSettings]))
        let firstBackend = RestoreOrderingBackend(apps: [
            AudioAppSnapshot(identity: music, displayName: "Music")
        ])
        let replacementBackend = LockedValue(RestoreOrderingBackend(apps: [
            AudioAppSnapshot(identity: music, displayName: "Music")
        ]))
        let store = try AudioControlStore(
            settingsStore: settingsStore,
            backend: firstBackend,
            backendFactory: { _ in replacementBackend.value },
            permissionClient: grantedClient()
        )
        try await store.refresh()

        var customization = store.settings.customization
        customization.backendMode = .mock
        try await store.applyCustomization(customization)

        XCTAssertEqual(
            replacementBackend.value.events,
            [
                .command(.setRoute(music, .multiOutput(["usb", "hdmi"]))),
                .command(.setVolume(music, 0.4)),
                .command(.setMuted(music, true)),
                .command(.setBoost(music, .x2)),
                .command(.setEQ(music, eq)),
                .synchronize
            ]
        )
    }

    func testIgnoringAppStopsActiveTapAndKeepsSettings() async throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let backend = MockAudioBackend(apps: [
            AudioAppSnapshot(identity: music, displayName: "Music", bundleIdentifier: music.rawValue)
        ])
        let store = try makeStore(backend: backend)
        try await store.refresh()
        try await store.setVolume(0.4, for: music)

        try await store.ignore(music)

        XCTAssertTrue(store.settings.ignoredAppIDs.contains(music))
        XCTAssertEqual(store.settings.appSettings[music]?.volume, 0.4)
    }

    func testAppDisplayOrderMergesNewAppsAtEnd() async throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let safari = AudioAppIdentity(rawValue: "com.example.Safari")
        let browser = AudioAppIdentity(rawValue: "com.example.Browser")
        let backend = MockAudioBackend(apps: [
            AudioAppSnapshot(identity: music, displayName: "Music"),
            AudioAppSnapshot(identity: safari, displayName: "Safari")
        ])
        let store = try makeStore(backend: backend)
        try await store.refresh()
        try await store.moveApp(safari, before: music)

        backend.snapshot.apps.append(AudioAppSnapshot(identity: browser, displayName: "Browser"))
        try await store.refresh()

        XCTAssertEqual(store.displayRows.map(\.identity), [safari, music, browser])
    }

    func testMissingSelectedRouteStillDisplaysStoredRoute() async throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let backend = MockAudioBackend(
            apps: [AudioAppSnapshot(identity: music, displayName: "Music", bundleIdentifier: music.rawValue)],
            devices: [AudioDeviceSnapshot(id: "built-in-output", name: "MacBook Speakers", isDefault: true)]
        )
        let store = try makeStore(backend: backend)
        try await store.refresh()
        try await store.setRoute(.selectedDevice("usb"), for: music)
        try await store.refresh()

        XCTAssertEqual(store.displayRows[0].settings.route, .selectedDevice("usb"))
    }

    func testFailedVolumeIntentRollsBackAndPublishesIssue() async throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let backend = FailingApplyBackend(apps: [AudioAppSnapshot(identity: music, displayName: "Music")])
        let store = try AudioControlStore(
            settingsStore: SettingsStore(settingsURL: uniqueSettingsURL()),
            backend: backend,
            permissionClient: grantedClient()
        )
        try await store.refresh()

        store.setVolumeIntent(0.25, for: music)
        await store.waitForPendingOperations()

        XCTAssertEqual(store.displayRows.first?.settings.volume, 1)
        XCTAssertEqual(store.issues.last?.affectedApp, music)
        XCTAssertEqual(store.issues.last?.severity, .error)
    }

    func testRefreshFailurePreservesLastSuccessfulRows() async throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let backend = FailsAfterFirstFetchBackend(apps: [AudioAppSnapshot(identity: music, displayName: "Music")])
        let store = try AudioControlStore(settingsStore: SettingsStore(settingsURL: uniqueSettingsURL()), backend: backend)
        try await store.refresh()

        store.refreshIntent()
        await store.waitForPendingOperations()

        XCTAssertEqual(store.displayRows.map(\.identity), [music])
        if case .failed = store.operationState {} else { XCTFail("Expected failed operation state") }
        XCTAssertEqual(store.issues.last?.recovery, .retry)
    }

    func testVolumeGestureCoalescesChangesAndFlushesFinalValue() async throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let backend = MockAudioBackend(apps: [AudioAppSnapshot(identity: music, displayName: "Music")])
        let store = try makeStore(backend: backend)
        try await store.refresh()

        store.beginVolumeEditing(for: music)
        for value in 1...20 { store.setVolumeIntent(Double(value) / 20, for: music) }
        store.endVolumeEditing(for: music)
        await store.waitForPendingOperations()

        XCTAssertEqual(backend.commands, [.setVolume(music, 1)])
        XCTAssertEqual(try store.settingsStore.load().appSettings[music]?.volume, 1)
    }

    func testEQGestureFlushAndAtomicResetEachSendOneCurve() async throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let backend = MockAudioBackend(apps: [AudioAppSnapshot(identity: music, displayName: "Music")])
        let store = try makeStore(backend: backend)
        try await store.refresh()

        store.beginEQEditing(band: 0, for: music)
        for value in 1...20 { store.setEQGainIntent(Double(value) / 2, band: 0, for: music) }
        store.endEQEditing(band: 0, for: music)
        await store.waitForPendingOperations()
        XCTAssertEqual(backend.commands.count, 1)

        store.resetEQIntent(for: music)
        await store.waitForPendingOperations()
        XCTAssertEqual(backend.commands.count, 2)
        XCTAssertEqual(try store.settingsStore.load().appSettings[music]?.eq, EQCurve())
    }

    func testPersistenceFailureCompensatesBackendAndRetriesTheRolledBackState() async throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        var baselineEQ = EQCurve()
        baselineEQ.setGain(4, at: 0)
        let baseline = AppAudioSettings(
            displayName: "Music",
            volume: 0.7,
            isMuted: false,
            boost: .x2,
            eq: baselineEQ,
            route: .followDefault
        )
        let settingsURL = uniqueSettingsURL()
        let settingsStore = SettingsStore(settingsURL: settingsURL)
        try settingsStore.save(PersistedSettings(appSettings: [music: baseline]))
        let backend = MockAudioBackend(apps: [AudioAppSnapshot(identity: music, displayName: "Music")])
        let store = try AudioControlStore(settingsStore: settingsStore, backend: backend, permissionClient: grantedClient())
        try await store.refresh()
        try blockPersistence(at: settingsURL)
        defer { try? FileManager.default.removeItem(at: settingsURL.deletingLastPathComponent()) }

        await assertThrows { try await store.setVolume(0.2, for: music) }
        await assertThrows { try await store.setMuted(true, for: music) }
        await assertThrows { try await store.setBoost(.x4, for: music) }
        await assertThrows { try await store.setRoute(.selectedDevice("usb"), for: music) }
        store.resetEQIntent(for: music)
        await store.waitForPendingOperations()

        var resetEQ = baselineEQ
        resetEQ.reset()
        XCTAssertEqual(
            backend.commands,
            [
                .setVolume(music, baseline.volume),
                .setBoost(music, baseline.boost),
                .setEQ(music, baseline.eq),
                .setVolume(music, 0.2),
                .setVolume(music, baseline.volume),
                .setMuted(music, true),
                .setMuted(music, baseline.isMuted),
                .setBoost(music, .x4),
                .setBoost(music, baseline.boost),
                .setRoute(music, .selectedDevice("usb")),
                .setRoute(music, baseline.route),
                .setEQ(music, resetEQ),
                .setEQ(music, baseline.eq)
            ]
        )
        XCTAssertEqual(store.settings.appSettings[music], baseline)
        XCTAssertEqual(store.displayRows.first?.settings, baseline)

        let settingsDirectory = settingsURL.deletingLastPathComponent()
        try FileManager.default.removeItem(at: settingsDirectory)
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
        await store.waitForPendingPersistence()

        XCTAssertEqual(try settingsStore.load().appSettings[music], baseline)
    }

    func testEQPersistenceFailureCompensatesAndPublishesIssue() async throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        var baselineEQ = EQCurve()
        baselineEQ.setGain(3, at: 0)
        let baseline = AppAudioSettings(displayName: "Music", volume: 1, eq: baselineEQ)
        let settingsURL = uniqueSettingsURL()
        let settingsStore = SettingsStore(settingsURL: settingsURL)
        try settingsStore.save(PersistedSettings(appSettings: [music: baseline]))
        let backend = MockAudioBackend(apps: [AudioAppSnapshot(identity: music, displayName: "Music")])
        let store = try AudioControlStore(settingsStore: settingsStore, backend: backend, permissionClient: grantedClient())
        try await store.refresh()
        try blockPersistence(at: settingsURL)
        defer { try? FileManager.default.removeItem(at: settingsURL.deletingLastPathComponent()) }

        var changedEQ = baselineEQ
        changedEQ.setGain(-6, at: 1)
        store.setEQGainIntent(-6, band: 1, for: music)
        await store.waitForPendingOperations()

        XCTAssertEqual(
            backend.commands,
            [.setEQ(music, baselineEQ), .setEQ(music, changedEQ), .setEQ(music, baselineEQ)]
        )
        XCTAssertEqual(store.displayRows.first?.settings.eq, baselineEQ)
        XCTAssertEqual(store.issues.last?.id, "eq-\(music.rawValue)-persistence")
        XCTAssertEqual(store.issues.last?.domain, .persistence)
        XCTAssertEqual(store.issues.last?.affectedApp, music)
        XCTAssertEqual(store.issues.last?.severity, .error)
        XCTAssertEqual(store.issues.last?.recovery, .retry)
    }

    func testResetKeepsSettingsWhenBackendTeardownFails() async throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        var persisted = PersistedSettings(
            appSettings: [music: AppAudioSettings(displayName: "Music", volume: 0.4)],
            pinnedAppIDs: [music],
            hasCompletedOnboarding: true
        )
        persisted.customization.backendMode = .mock
        let settingsStore = SettingsStore(settingsURL: uniqueSettingsURL())
        try settingsStore.save(persisted)
        let backend = TapSynchronizingMockBackend(apps: [])
        backend.tearDownAllError = NSError(domain: "Teardown", code: 23)
        let requestedModes = LockedValue<[BackendMode]>([])
        let store = try AudioControlStore(
            settingsStore: settingsStore,
            backend: backend,
            backendFactory: { mode in
                requestedModes.withValue { $0.append(mode) }
                return MockAudioBackend()
            },
            permissionClient: grantedClient()
        )

        await assertThrows { try await store.reset() }

        XCTAssertEqual(store.settings, persisted)
        XCTAssertEqual(try settingsStore.load(), persisted)
        XCTAssertTrue(requestedModes.value.isEmpty)
    }

    private func makeStore(
        backend: MockAudioBackend,
        permissionClient: any AudioCapturePermissionClient = FakePermissionClient(
            state: AudioCapturePermissionState(screenCapture: .granted, audioUsageDescription: .present)
        )
    ) throws -> AudioControlStore {
        let store = SettingsStore(settingsURL: uniqueSettingsURL())
        return try AudioControlStore(settingsStore: store, backend: backend, permissionClient: permissionClient)
    }

    func testRefreshReadsOutputVolumeFromBackend() async throws {
        let backend = MockAudioBackend()
        backend.outputVolume = 0.4
        backend.outputMuted = true
        let store = try makeStore(backend: backend)

        try await store.refresh()

        XCTAssertEqual(store.outputVolumeState.volume, 0.4, accuracy: 0.001)
        XCTAssertTrue(store.outputVolumeState.isMuted)
        XCTAssertEqual(store.outputVolumeState.deviceName, "MacBook Speakers")
    }

    func testSetOutputVolumeIntentAppliesAndClamps() async throws {
        let backend = MockAudioBackend()
        let store = try makeStore(backend: backend)
        try await store.refresh()

        store.setOutputVolumeIntent(0.55)
        await store.waitForPendingOperations()
        XCTAssertEqual(backend.outputVolume, 0.55, accuracy: 0.001)
        XCTAssertEqual(store.outputVolumeState.volume, 0.55, accuracy: 0.001)

        store.setOutputVolumeIntent(1.4)
        await store.waitForPendingOperations()
        XCTAssertEqual(backend.outputVolume, 1, accuracy: 0.001)
        store.setOutputVolumeIntent(-0.2)
        await store.waitForPendingOperations()
        XCTAssertEqual(backend.outputVolume, 0, accuracy: 0.001)
    }

    func testToggleOutputMuteIntentFlipsMute() async throws {
        let backend = MockAudioBackend()
        let store = try makeStore(backend: backend)
        try await store.refresh()
        XCTAssertFalse(store.outputVolumeState.isMuted)

        store.toggleOutputMuteIntent()
        await store.waitForPendingOperations()
        XCTAssertTrue(backend.outputMuted)
        XCTAssertTrue(store.outputVolumeState.isMuted)

        store.toggleOutputMuteIntent()
        await store.waitForPendingOperations()
        XCTAssertFalse(backend.outputMuted)
        XCTAssertFalse(store.outputVolumeState.isMuted)
    }

    func testRefreshReadsDeviceVolumeStatesForAllDevices() async throws {
        let usb = AudioDeviceSnapshot(id: "usb", name: "USB DAC")
        let hdmi = AudioDeviceSnapshot(id: "hdmi", name: "HDMI")
        let backend = MockAudioBackend(devices: [usb, hdmi])
        backend.perDeviceVolume = ["usb": 0.4, "hdmi": 0.8]
        backend.perDeviceMuted = ["usb": false, "hdmi": true]
        let store = try makeStore(backend: backend)

        try await store.refresh()

        XCTAssertEqual(store.deviceVolumeStates["usb"]?.volume ?? -1, 0.4, accuracy: 0.001)
        XCTAssertEqual(store.deviceVolumeStates["hdmi"]?.volume ?? -1, 0.8, accuracy: 0.001)
        XCTAssertFalse(store.deviceVolumeStates["usb"]?.isMuted ?? true)
        XCTAssertTrue(store.deviceVolumeStates["hdmi"]?.isMuted ?? false)
        XCTAssertEqual(store.deviceVolumeStates["usb"]?.deviceName, "USB DAC")
    }

    func testSetDeviceVolumeIntentAppliesPerDeviceAndClamps() async throws {
        let usb = AudioDeviceSnapshot(id: "usb", name: "USB DAC")
        let backend = MockAudioBackend(devices: [usb])
        let store = try makeStore(backend: backend)
        try await store.refresh()

        store.setDeviceVolumeIntent(0.55, for: "usb")
        await store.waitForPendingOperations()
        XCTAssertEqual(backend.perDeviceVolume["usb"] ?? -1, 0.55, accuracy: 0.001)
        XCTAssertEqual(store.deviceVolumeStates["usb"]?.volume ?? -1, 0.55, accuracy: 0.001)

        store.setDeviceVolumeIntent(1.5, for: "usb")
        await store.waitForPendingOperations()
        XCTAssertEqual(backend.perDeviceVolume["usb"] ?? -1, 1, accuracy: 0.001)
        store.setDeviceVolumeIntent(-0.3, for: "usb")
        await store.waitForPendingOperations()
        XCTAssertEqual(backend.perDeviceVolume["usb"] ?? -1, 0, accuracy: 0.001)
    }

    func testToggleDeviceMuteIntentFlipsPerDeviceMute() async throws {
        let usb = AudioDeviceSnapshot(id: "usb", name: "USB DAC")
        let backend = MockAudioBackend(devices: [usb])
        let store = try makeStore(backend: backend)
        try await store.refresh()
        XCTAssertFalse(store.deviceVolumeStates["usb"]?.isMuted ?? true)

        store.toggleDeviceMuteIntent(for: "usb")
        await store.waitForPendingOperations()
        XCTAssertTrue(backend.perDeviceMuted["usb"] ?? false)
        XCTAssertTrue(store.deviceVolumeStates["usb"]?.isMuted ?? false)

        store.toggleDeviceMuteIntent(for: "usb")
        await store.waitForPendingOperations()
        XCTAssertFalse(backend.perDeviceMuted["usb"] ?? true)
        XCTAssertFalse(store.deviceVolumeStates["usb"]?.isMuted ?? true)
    }

    private func grantedClient() -> FakePermissionClient {
        FakePermissionClient(state: AudioCapturePermissionState(screenCapture: .granted, audioUsageDescription: .present))
    }

    private func uniqueSettingsURL() -> URL {
        temporaryFileURL(prefix: "EQMacRepStore", filename: "settings.json")
    }

    private func blockPersistence(at settingsURL: URL) throws {
        let settingsDirectory = settingsURL.deletingLastPathComponent()
        try FileManager.default.removeItem(at: settingsDirectory)
        try Data().write(to: settingsDirectory)
    }

    private func assertThrows(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected operation to throw", file: file, line: line)
        } catch {}
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value { lock.withLock { storage } }

    func withValue(_ body: (inout Value) -> Void) {
        lock.withLock { body(&storage) }
    }
}

private final class FailingApplyBackend: AudioBackend {
    let snapshot: AudioBackendSnapshot
    init(apps: [AudioAppSnapshot]) { snapshot = AudioBackendSnapshot(apps: apps) }
    func fetchSnapshot() throws -> AudioBackendSnapshot { snapshot }
    func apply(_ command: AudioBackendCommand) throws { throw NSError(domain: "Apply", code: 1) }
}

private final class FailsAfterFirstFetchBackend: AudioBackend {
    let snapshot: AudioBackendSnapshot
    var fetches = 0
    init(apps: [AudioAppSnapshot]) { snapshot = AudioBackendSnapshot(apps: apps) }
    func fetchSnapshot() throws -> AudioBackendSnapshot {
        fetches += 1
        if fetches > 1 { throw NSError(domain: "Fetch", code: 2) }
        return snapshot
    }
    func apply(_ command: AudioBackendCommand) throws {}
}

private final class LevelProvidingBackend: AudioBackend, AudioBackendAppLevelProviding {
    let snapshot: AudioBackendSnapshot
    private let lock = NSLock()
    private var storedLevels: [AudioAppIdentity: Double] = [:]
    private var storedFetchCount = 0

    var levels: [AudioAppIdentity: Double] {
        get { lock.withLock { storedLevels } }
        set { lock.withLock { storedLevels = newValue } }
    }

    var fetchCount: Int { lock.withLock { storedFetchCount } }

    init(apps: [AudioAppSnapshot]) {
        snapshot = AudioBackendSnapshot(apps: apps)
    }

    func fetchSnapshot() throws -> AudioBackendSnapshot {
        lock.withLock { storedFetchCount += 1 }
        return snapshot
    }

    func apply(_ command: AudioBackendCommand) throws {}
    func consumeAppLevels() -> [AudioAppIdentity: Double] {
        lock.withLock { storedLevels }
    }
}

private struct FakePermissionClient: AudioCapturePermissionClient {
    var state: AudioCapturePermissionState

    func currentState() -> AudioCapturePermissionState { state }
    func requestScreenCaptureAccess() -> AudioCapturePermissionState { state }
    func openPrivacySettings() {}
    func relaunchApp() async throws {}
}

private final class EventingBackend: AudioBackend, AudioBackendUpdatePublishing {
    private var snapshots: [AudioBackendSnapshot]
    private let repeatingSnapshot: AudioBackendSnapshot?
    private(set) var fetchCount = 0
    var onFetch: ((Int) -> Void)?
    private var continuation: AsyncStream<Void>.Continuation?

    private lazy var stream: AsyncStream<Void> = AsyncStream { continuation in
        self.continuation = continuation
    }

    init(snapshots: [AudioBackendSnapshot]) {
        self.snapshots = snapshots
        self.repeatingSnapshot = nil
    }

    init(repeatingSnapshot: AudioBackendSnapshot) {
        self.snapshots = []
        self.repeatingSnapshot = repeatingSnapshot
    }

    var updateEvents: AsyncStream<Void> { stream }

    func emitUpdate() {
        continuation?.yield(())
    }

    func fetchSnapshot() throws -> AudioBackendSnapshot {
        fetchCount += 1
        onFetch?(fetchCount)
        if let repeatingSnapshot { return repeatingSnapshot }
        return snapshots.isEmpty ? AudioBackendSnapshot() : snapshots.removeFirst()
    }

    func apply(_ command: AudioBackendCommand) throws {}
}

private final class TapSynchronizingMockBackend: AudioBackend, AudioBackendTapSynchronizing {    var snapshot: AudioBackendSnapshot
    var syncError: Error?
    var tearDownAllError: Error?
    private(set) var synchronizedActiveIDs: Set<AudioAppIdentity> = []
    private(set) var synchronizedIgnoredIDs: Set<AudioAppIdentity> = []
    private(set) var tornDownIDs: [AudioAppIdentity] = []
    private(set) var tearDownAllCount = 0

    init(apps: [AudioAppSnapshot], devices: [AudioDeviceSnapshot] = []) {
        snapshot = AudioBackendSnapshot(apps: apps, devices: devices)
    }

    func fetchSnapshot() throws -> AudioBackendSnapshot {
        snapshot
    }

    func apply(_ command: AudioBackendCommand) throws {}

    func synchronizeTaps(activeAppIDs: Set<AudioAppIdentity>, ignoredAppIDs: Set<AudioAppIdentity>) throws {
        if let syncError { throw syncError }
        synchronizedActiveIDs = activeAppIDs
        synchronizedIgnoredIDs = ignoredAppIDs
    }

    func tearDownTap(for identity: AudioAppIdentity) throws {
        tornDownIDs.append(identity)
    }

    func tearDownAllTaps() throws {
        tearDownAllCount += 1
        if let tearDownAllError { throw tearDownAllError }
    }
}

private enum RestoreBackendEvent: Equatable {
    case command(AudioBackendCommand)
    case synchronize
}

private final class RestoreOrderingBackend: AudioBackend, AudioBackendTapSynchronizing {
    let snapshot: AudioBackendSnapshot
    private(set) var events: [RestoreBackendEvent] = []

    init(apps: [AudioAppSnapshot]) {
        snapshot = AudioBackendSnapshot(apps: apps)
    }

    func fetchSnapshot() throws -> AudioBackendSnapshot { snapshot }

    func apply(_ command: AudioBackendCommand) throws {
        events.append(.command(command))
    }

    func synchronizeTaps(activeAppIDs: Set<AudioAppIdentity>, ignoredAppIDs: Set<AudioAppIdentity>) throws {
        events.append(.synchronize)
    }

    func tearDownTap(for identity: AudioAppIdentity) throws {}
    func tearDownAllTaps() throws {}
}
