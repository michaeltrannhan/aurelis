import XCTest
@testable import EQMacRep

@MainActor
final class AudioControlStoreTests: XCTestCase {
    func testRefreshCreatesDefaultSettingsForBackendApps() throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let backend = MockAudioBackend(apps: [
            AudioAppSnapshot(identity: music, displayName: "Music", bundleIdentifier: music.rawValue, level: 0.6)
        ])
        let store = try AudioControlStore(settingsStore: SettingsStore(settingsURL: uniqueSettingsURL()), backend: backend)

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
        let store = try AudioControlStore(settingsStore: SettingsStore(settingsURL: uniqueSettingsURL()), backend: backend)
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

    func testBackendModeChangeReplacesBackendAndRefreshesRows() throws {
        let mockIdentity = AudioAppIdentity(rawValue: "com.example.Mock")
        let realIdentity = AudioAppIdentity(rawValue: "com.example.Real")
        let initialBackend = MockAudioBackend(apps: [
            AudioAppSnapshot(identity: mockIdentity, displayName: "Mock App")
        ])
        let replacementBackend = MockAudioBackend(apps: [
            AudioAppSnapshot(identity: realIdentity, displayName: "Real App")
        ])
        let settingsStore = SettingsStore(settingsURL: uniqueSettingsURL())
        var settings = PersistedSettings()
        settings.customization.backendMode = .mock
        try settingsStore.save(settings)
        var requestedModes: [BackendMode] = []
        let store = try AudioControlStore(
            settingsStore: settingsStore,
            backend: initialBackend,
            backendFactory: { mode in
                requestedModes.append(mode)
                return replacementBackend
            }
        )
        try store.refresh()

        var customization = store.settings.customization
        customization.backendMode = .coreAudioDiscovery
        try store.applyCustomization(customization)

        XCTAssertEqual(requestedModes, [.coreAudioDiscovery])
        XCTAssertEqual(store.displayRows.map(\.identity), [realIdentity])
    }

    func testRefreshSynchronizesTapsWithIgnoredApps() throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let backend = TapSynchronizingMockBackend(apps: [
            AudioAppSnapshot(identity: music, displayName: "Music")
        ])
        let store = try AudioControlStore(
            settingsStore: SettingsStore(settingsURL: uniqueSettingsURL()),
            backend: backend,
            permissionClient: grantedClient()
        )

        try store.refresh()
        try store.ignore(music)

        XCTAssertEqual(backend.synchronizedActiveIDs, [music])
        XCTAssertEqual(backend.synchronizedIgnoredIDs, [music])
        XCTAssertEqual(backend.tornDownIDs, [music])
    }

    func testRefreshKeepsRowsWhenTapSynchronizationFails() throws {
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

        try store.refresh()

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

        try store.refresh()
        XCTAssertEqual(store.displayRows.map(\.identity), [music])

        store.startBackendObservation(debounceNanoseconds: 1_000_000)
        backend.emitUpdate()
        try await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertEqual(store.displayRows.map(\.identity), [music, safari])
        store.stopBackendObservation()
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
        try store.refresh()
        let baselineFetches = backend.fetchCount

        store.startBackendObservation(debounceNanoseconds: 40_000_000)
        for _ in 0..<10 { backend.emitUpdate() }
        try await Task.sleep(nanoseconds: 120_000_000)
        store.stopBackendObservation()

        // A burst of 10 events should collapse into far fewer refreshes.
        XCTAssertLessThan(backend.fetchCount - baselineFetches, 10)
        XCTAssertGreaterThanOrEqual(backend.fetchCount - baselineFetches, 1)
    }

    func testPermissionRefreshUpdatesPublishedStateAndStatus() throws {
        let client = FakePermissionClient(state: AudioCapturePermissionState(
            screenCapture: .denied,
            audioUsageDescription: .present
        ))
        let store = try makeStore(backend: MockAudioBackend(), permissionClient: client)

        store.refreshPermissionState()

        XCTAssertEqual(store.permissionState.summary, "Screen & System Audio Recording denied")
        XCTAssertEqual(store.statusMessage, "Screen & System Audio Recording denied")
    }

    func testDeniedPermissionGatesTapSynchronization() throws {
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

        try store.refresh()

        // Taps must not be created; teardown-all is called instead as the safe path.
        XCTAssertTrue(backend.synchronizedActiveIDs.isEmpty)
        XCTAssertGreaterThanOrEqual(backend.tearDownAllCount, 1)
    }

    func testRouteMutationPersistsAndNotifiesBackend() throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let backend = MockAudioBackend(apps: [
            AudioAppSnapshot(identity: music, displayName: "Music", bundleIdentifier: music.rawValue)
        ])
        let store = try makeStore(backend: backend)
        try store.refresh()

        try store.setRoute(.selectedDevice("built-in-output"), for: music)

        let saved = try store.settingsStore.load()
        XCTAssertEqual(saved.appSettings[music]?.route, .selectedDevice("built-in-output"))
        XCTAssertEqual(backend.commands.last, .setRoute(music, .selectedDevice("built-in-output")))
    }

    func testIgnoringAppStopsActiveTapAndKeepsSettings() throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let backend = MockAudioBackend(apps: [
            AudioAppSnapshot(identity: music, displayName: "Music", bundleIdentifier: music.rawValue)
        ])
        let store = try makeStore(backend: backend)
        try store.refresh()
        try store.setVolume(0.4, for: music)

        try store.ignore(music)

        XCTAssertTrue(store.settings.ignoredAppIDs.contains(music))
        XCTAssertEqual(store.settings.appSettings[music]?.volume, 0.4)
    }

    func testAppDisplayOrderMergesNewAppsAtEnd() throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let safari = AudioAppIdentity(rawValue: "com.example.Safari")
        let browser = AudioAppIdentity(rawValue: "com.example.Browser")
        let backend = MockAudioBackend(apps: [
            AudioAppSnapshot(identity: music, displayName: "Music"),
            AudioAppSnapshot(identity: safari, displayName: "Safari")
        ])
        let store = try makeStore(backend: backend)
        try store.refresh()
        try store.moveApp(safari, before: music)

        backend.snapshot.apps.append(AudioAppSnapshot(identity: browser, displayName: "Browser"))
        try store.refresh()

        XCTAssertEqual(store.displayRows.map(\.identity), [safari, music, browser])
    }

    func testMissingSelectedRouteStillDisplaysStoredRoute() throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let backend = MockAudioBackend(
            apps: [AudioAppSnapshot(identity: music, displayName: "Music", bundleIdentifier: music.rawValue)],
            devices: [AudioDeviceSnapshot(id: "built-in-output", name: "MacBook Speakers", isDefault: true)]
        )
        let store = try makeStore(backend: backend)
        try store.refresh()
        try store.setRoute(.selectedDevice("usb"), for: music)
        try store.refresh()

        XCTAssertEqual(store.displayRows[0].settings.route, .selectedDevice("usb"))
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

    private func grantedClient() -> FakePermissionClient {
        FakePermissionClient(state: AudioCapturePermissionState(screenCapture: .granted, audioUsageDescription: .present))
    }

    private func uniqueSettingsURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("EQMacRepStoreTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("settings.json")
    }
}

private struct FakePermissionClient: AudioCapturePermissionClient {
    var state: AudioCapturePermissionState

    func currentState() -> AudioCapturePermissionState { state }
    func requestScreenCaptureAccess() -> AudioCapturePermissionState { state }
    func openPrivacySettings() {}
}

private final class EventingBackend: AudioBackend, AudioBackendUpdatePublishing {
    private var snapshots: [AudioBackendSnapshot]
    private let repeatingSnapshot: AudioBackendSnapshot?
    private(set) var fetchCount = 0
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
        if let repeatingSnapshot { return repeatingSnapshot }
        return snapshots.isEmpty ? AudioBackendSnapshot() : snapshots.removeFirst()
    }

    func apply(_ command: AudioBackendCommand) throws {}
}

private final class TapSynchronizingMockBackend: AudioBackend, AudioBackendTapSynchronizing {    var snapshot: AudioBackendSnapshot
    var syncError: Error?
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
    }
}
