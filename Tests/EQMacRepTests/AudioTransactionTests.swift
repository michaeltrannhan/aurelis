import Foundation
import XCTest
@testable import EQMacRep

@MainActor
final class AudioTransactionTests: XCTestCase {
    private let music = AudioAppIdentity(rawValue: "com.example.Music")
    private let chat = AudioAppIdentity(rawValue: "com.example.Chat")

    func testPinAndUnpinCommitOnceAndPersistenceFailureRollsBack() async throws {
        let context = try await makeContext()
        defer { removeContext(context.url) }

        try await context.store.pin(music)
        XCTAssertTrue(context.store.settings.pinnedAppIDs.contains(music))
        XCTAssertTrue(try context.settingsStore.load().pinnedAppIDs.contains(music))

        try blockPersistence(at: context.url)
        await assertThrows { try await context.store.unpin(self.music) }

        XCTAssertTrue(context.store.settings.pinnedAppIDs.contains(music))
        XCTAssertEqual(context.store.issues.last?.domain, .persistence)
        XCTAssertTrue(context.backend.commands.isEmpty)
    }

    func testIgnoreEngineFailureCompensatesToPreviousTapSet() async throws {
        let context = try await makeContext()
        defer { removeContext(context.url) }
        context.backend.failNextTapTeardown()

        await assertThrows { try await context.store.ignore(self.music) }

        XCTAssertFalse(context.store.settings.ignoredAppIDs.contains(music))
        XCTAssertEqual(context.backend.tapTeardownIdentities, [music])
        XCTAssertEqual(context.backend.synchronizationHistory.last, [])
        XCTAssertEqual(context.store.issues.last?.domain, .tap)
    }

    func testIgnorePersistenceFailureResynchronizesPreviousTapSet() async throws {
        let context = try await makeContext()
        defer { removeContext(context.url) }
        try blockPersistence(at: context.url)

        await assertThrows { try await context.store.ignore(self.music) }

        XCTAssertFalse(context.store.settings.ignoredAppIDs.contains(music))
        XCTAssertEqual(Array(context.backend.synchronizationHistory.suffix(2)), [[music], []])
        XCTAssertEqual(context.store.issues.last?.domain, .persistence)
    }

    func testTapCompensationFailureIsReportedSeparately() async throws {
        let context = try await makeContext()
        defer { removeContext(context.url) }
        context.backend.failNextSynchronizations(count: 2)

        await assertThrows { try await context.store.ignore(self.music) }

        XCTAssertFalse(context.store.settings.ignoredAppIDs.contains(music))
        let compensation = try XCTUnwrap(
            context.store.issues.first { $0.id == "ignore-\(self.music.rawValue)-compensation" }
        )
        XCTAssertEqual(compensation.domain, .tap)
        XCTAssertEqual(compensation.severity, .error)
    }

    func testUnignoreAndRestoreAllEachPerformOneTapTransaction() async throws {
        var settings = PersistedSettings(
            appSettings: [
                music: AppAudioSettings(displayName: "Music", volume: 1),
                chat: AppAudioSettings(displayName: "Chat", volume: 1)
            ],
            ignoredAppIDs: [music, chat]
        )
        settings.customization.backendMode = .mock
        let context = try await makeContext(settings: settings, apps: [
            AudioAppSnapshot(identity: music, displayName: "Music"),
            AudioAppSnapshot(identity: chat, displayName: "Chat")
        ])
        defer { removeContext(context.url) }
        let baselineSyncCount = context.backend.synchronizationHistory.count

        try await context.store.unignore(music)
        try await context.store.restoreAllIgnoredApps()

        XCTAssertTrue(context.store.settings.ignoredAppIDs.isEmpty)
        XCTAssertTrue(try context.settingsStore.load().ignoredAppIDs.isEmpty)
        XCTAssertEqual(
            Array(context.backend.synchronizationHistory.dropFirst(baselineSyncCount)),
            [[chat], []]
        )
    }

    func testUnignorePersistenceFailureRestoresPriorIgnoredSet() async throws {
        var settings = PersistedSettings(
            appSettings: [music: AppAudioSettings(displayName: "Music", volume: 1)],
            ignoredAppIDs: [music]
        )
        settings.customization.backendMode = .mock
        let context = try await makeContext(settings: settings)
        defer { removeContext(context.url) }
        try blockPersistence(at: context.url)

        await assertThrows { try await context.store.unignore(self.music) }

        XCTAssertEqual(context.store.settings.ignoredAppIDs, [music])
        XCTAssertEqual(Array(context.backend.synchronizationHistory.suffix(2)), [[], [music]])
    }

    func testRestoreAllEngineFailureCompensatesEntireIgnoredSet() async throws {
        var settings = PersistedSettings(
            appSettings: [
                music: AppAudioSettings(displayName: "Music", volume: 1),
                chat: AppAudioSettings(displayName: "Chat", volume: 1)
            ],
            ignoredAppIDs: [music, chat]
        )
        settings.customization.backendMode = .mock
        let context = try await makeContext(settings: settings, apps: [
            AudioAppSnapshot(identity: music, displayName: "Music"),
            AudioAppSnapshot(identity: chat, displayName: "Chat")
        ])
        defer { removeContext(context.url) }
        context.backend.failNextSynchronizations()

        await assertThrows { try await context.store.restoreAllIgnoredApps() }

        XCTAssertEqual(context.store.settings.ignoredAppIDs, [music, chat])
        XCTAssertEqual(
            Array(context.backend.synchronizationHistory.suffix(2)),
            [[], [music, chat]]
        )
        XCTAssertEqual(context.store.issues.last?.domain, .tap)
    }

    func testRestoreAllPersistenceFailureCompensatesEntireIgnoredSet() async throws {
        var settings = PersistedSettings(
            appSettings: [
                music: AppAudioSettings(displayName: "Music", volume: 1),
                chat: AppAudioSettings(displayName: "Chat", volume: 1)
            ],
            ignoredAppIDs: [music, chat]
        )
        settings.customization.backendMode = .mock
        let context = try await makeContext(settings: settings, apps: [
            AudioAppSnapshot(identity: music, displayName: "Music"),
            AudioAppSnapshot(identity: chat, displayName: "Chat")
        ])
        defer { removeContext(context.url) }
        try blockPersistence(at: context.url)

        await assertThrows { try await context.store.restoreAllIgnoredApps() }

        XCTAssertEqual(context.store.settings.ignoredAppIDs, [music, chat])
        XCTAssertEqual(
            Array(context.backend.synchronizationHistory.suffix(2)),
            [[], [music, chat]]
        )
        XCTAssertEqual(context.store.issues.last?.domain, .persistence)
    }

    func testRouteEngineFailureCompensatesAndUsesTapIssueDomain() async throws {
        let context = try await makeContext()
        defer { removeContext(context.url) }
        context.backend.failNextApplies(count: 1)

        await assertThrows {
            try await context.store.setRoute(.selectedDevice("usb"), for: self.music)
        }

        XCTAssertEqual(context.store.settings.appSettings[music]?.route, .followDefault)
        XCTAssertEqual(
            context.backend.commands,
            [.setRoute(music, .selectedDevice("usb")), .setRoute(music, .followDefault)]
        )
        XCTAssertEqual(context.store.issues.last?.domain, .tap)
    }

    func testBackendSwitchPersistenceFailureRollsBackOldBackend() async throws {
        var settings = PersistedSettings(
            appSettings: [music: AppAudioSettings(displayName: "Music", volume: 1)]
        )
        settings.customization.backendMode = .mock
        let replacement = TransactionBackend(apps: [
            AudioAppSnapshot(identity: chat, displayName: "Chat")
        ])
        let context = try await makeContext(
            settings: settings,
            backendFactory: { _ in replacement }
        )
        defer { removeContext(context.url) }
        try blockPersistence(at: context.url)
        var desired = context.store.settings.customization
        desired.backendMode = .coreAudioDiscovery

        await assertThrows { try await context.store.applyCustomization(desired) }

        XCTAssertEqual(context.store.settings.customization.backendMode, .mock)
        XCTAssertEqual(context.backend.tearDownAllCount, 1)
        XCTAssertEqual(replacement.tearDownAllCount, 1)
        XCTAssertEqual(context.store.issues.last?.domain, .persistence)
    }

    func testBackendSwitchEngineFailureLeavesSettingsAndFactoryUntouched() async throws {
        var settings = PersistedSettings(
            appSettings: [music: AppAudioSettings(displayName: "Music", volume: 1)]
        )
        settings.customization.backendMode = .mock
        let replacement = TransactionBackend(apps: [
            AudioAppSnapshot(identity: chat, displayName: "Chat")
        ])
        let context = try await makeContext(
            settings: settings,
            backendFactory: { _ in replacement }
        )
        defer { removeContext(context.url) }
        context.backend.failNextTearDownAll()
        var desired = context.store.settings.customization
        desired.backendMode = .coreAudioDiscovery

        await assertThrows { try await context.store.applyCustomization(desired) }

        XCTAssertEqual(context.store.settings.customization.backendMode, .mock)
        XCTAssertEqual(context.backend.tearDownAllCount, 1)
        XCTAssertEqual(replacement.tearDownAllCount, 0)
        XCTAssertEqual(context.store.issues.last?.domain, .backend)
    }

    func testBackendSwitchCompensationFailureKeepsDesiredEngineStateDirty() async throws {
        var settings = PersistedSettings(
            appSettings: [music: AppAudioSettings(displayName: "Music", volume: 1)]
        )
        settings.customization.backendMode = .mock
        let replacement = TransactionBackend(apps: [
            AudioAppSnapshot(identity: chat, displayName: "Chat")
        ])
        replacement.failNextTearDownAll()
        let context = try await makeContext(
            settings: settings,
            backendFactory: { _ in replacement }
        )
        defer { removeContext(context.url) }
        try blockPersistence(at: context.url)
        var desired = context.store.settings.customization
        desired.backendMode = .coreAudioDiscovery

        await assertThrows { try await context.store.applyCustomization(desired) }

        XCTAssertEqual(context.store.settings.customization.backendMode, .coreAudioDiscovery)
        XCTAssertNotNil(context.store.issues.first { $0.id == "customization-compensation" })
        let diagnostics = await context.store.persistenceDiagnostics()
        XCTAssertTrue(diagnostics.hasDirtyState)
    }

    func testResetPersistenceFailureRollsBackBackendAndSettings() async throws {
        var settings = PersistedSettings(
            appSettings: [music: AppAudioSettings(displayName: "Music", volume: 0.4)],
            pinnedAppIDs: [music],
            hasCompletedOnboarding: true
        )
        settings.customization.backendMode = .mock
        let replacement = TransactionBackend()
        let context = try await makeContext(
            settings: settings,
            backendFactory: { _ in replacement }
        )
        defer { removeContext(context.url) }
        let previous = context.store.settings
        try blockPersistence(at: context.url)

        await assertThrows { try await context.store.reset() }

        XCTAssertEqual(context.store.settings, previous)
        XCTAssertEqual(context.backend.tearDownAllCount, 1)
        XCTAssertEqual(replacement.tearDownAllCount, 1)
    }

    func testResetSuccessCommitsDefaultsAndRefreshesReplacementBackend() async throws {
        var settings = PersistedSettings(
            appSettings: [music: AppAudioSettings(displayName: "Music", volume: 0.4)],
            pinnedAppIDs: [music],
            ignoredAppIDs: [chat],
            hasCompletedOnboarding: true
        )
        settings.customization.backendMode = .mock
        let replacement = TransactionBackend(apps: [
            AudioAppSnapshot(identity: chat, displayName: "Chat")
        ])
        let context = try await makeContext(
            settings: settings,
            backendFactory: { _ in replacement }
        )
        defer { removeContext(context.url) }

        try await context.store.reset()

        XCTAssertTrue(context.store.settings.pinnedAppIDs.isEmpty)
        XCTAssertTrue(context.store.settings.ignoredAppIDs.isEmpty)
        XCTAssertFalse(context.store.settings.hasCompletedOnboarding)
        XCTAssertEqual(context.store.settings.customization.backendMode, .coreAudioDiscovery)
        XCTAssertEqual(context.store.displayRows.map(\.identity), [chat])
        XCTAssertEqual(context.backend.tearDownAllCount, 1)
    }

    func testOnboardingCompletionDismissalContractRequiresDurableCommit() async throws {
        let success = try await makeContext()
        defer { removeContext(success.url) }

        try await success.store.completeOnboarding()

        XCTAssertTrue(success.store.settings.hasCompletedOnboarding)
        XCTAssertTrue(try success.settingsStore.load().hasCompletedOnboarding)

        let failure = try await makeContext()
        defer { removeContext(failure.url) }
        try blockPersistence(at: failure.url)

        await assertThrows { try await failure.store.completeOnboarding() }

        XCTAssertFalse(failure.store.settings.hasCompletedOnboarding)
        XCTAssertEqual(failure.store.issues.last?.domain, .persistence)
    }

    func testUnsupportedOutputControlsAreExplicitAndCannotReachBackend() async throws {
        let context = try await makeContext()
        defer { removeContext(context.url) }

        XCTAssertEqual(context.store.outputVolumeState.capabilities, .unavailable)
        await assertThrows { try await context.store.setOutputVolume(0.2) }
        await assertThrows { try await context.store.setOutputMuted(true) }

        XCTAssertEqual(context.store.outputVolumeState.volume, 1)
        XCTAssertFalse(context.store.outputVolumeState.isMuted)
    }

    func testEditSessionsAreKeyedByAppControlBandAndGestureToken() async throws {
        let context = try await makeContext()
        defer { removeContext(context.url) }

        let volumeToken = context.store.beginVolumeEditing(for: music)
        let firstBandToken = context.store.beginEQEditing(band: 0, for: music)
        let repeatedBandToken = context.store.beginEQEditing(band: 0, for: music)
        let secondBandToken = context.store.beginEQEditing(band: 1, for: music)

        XCTAssertEqual(firstBandToken, repeatedBandToken)
        XCTAssertNotEqual(volumeToken, firstBandToken)
        XCTAssertNotEqual(firstBandToken, secondBandToken)
        XCTAssertEqual(context.store.activeEditSessionKeys.count, 3)
        XCTAssertEqual(
            Set(context.store.activeEditSessionKeys.map(\.control)),
            [.volume, .eqBand(0), .eqBand(1)]
        )

        context.store.endContinuousEdits(for: music)
        await context.store.waitForPendingOperations()
        XCTAssertTrue(context.store.activeEditSessionKeys.isEmpty)
    }

    func testShutdownAttemptsEditsPersistenceObservationAndTapTeardownOnce() async throws {
        let context = try await makeContext()
        defer { removeContext(context.url) }
        await context.store.startBackendObservation()
        context.backend.failNextTearDownAll()
        try blockPersistence(at: context.url)
        context.store.beginVolumeEditing(for: music)
        context.store.setVolumeIntent(0.2, for: music)

        let first = await context.store.shutdown()
        let second = await context.store.shutdown()

        XCTAssertFalse(first.editSessionErrorDescriptions.isEmpty)
        XCTAssertNotNil(first.persistenceErrorDescription)
        XCTAssertNotNil(first.engineReport.teardownErrorDescription)
        XCTAssertTrue(first.engineReport.stoppedTopologyObservation)
        XCTAssertEqual(first, second)
        XCTAssertEqual(context.backend.tearDownAllCount, 1)
    }

    private struct Context {
        let store: AudioControlStore
        let settingsStore: SettingsStore
        let backend: TransactionBackend
        let url: URL
    }

    private func makeContext(
        settings: PersistedSettings? = nil,
        apps: [AudioAppSnapshot]? = nil,
        backendFactory: @escaping @Sendable (BackendMode) -> any AudioBackend = { _ in TransactionBackend() }
    ) async throws -> Context {
        let url = uniqueSettingsURL()
        let settingsStore = SettingsStore(settingsURL: url)
        if let settings { try settingsStore.save(settings) }
        let backend = TransactionBackend(apps: apps ?? [
            AudioAppSnapshot(identity: music, displayName: "Music")
        ])
        let store = try AudioControlStore(
            settingsStore: settingsStore,
            backend: backend,
            backendFactory: backendFactory,
            permissionClient: TransactionPermissionClient()
        )
        try await store.refresh()
        return Context(store: store, settingsStore: settingsStore, backend: backend, url: url)
    }

    private func uniqueSettingsURL() -> URL {
        temporaryFileURL(prefix: "EQMacRepTransaction", filename: "settings.json")
    }

    private func blockPersistence(at settingsURL: URL) throws {
        let directory = settingsURL.deletingLastPathComponent()
        try FileManager.default.removeItem(at: directory)
        try Data("blocked".utf8).write(to: directory)
    }

    private func removeContext(_ settingsURL: URL) {
        try? FileManager.default.removeItem(at: settingsURL.deletingLastPathComponent())
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

private struct TransactionPermissionClient: AudioCapturePermissionClient {
    func currentState() -> AudioCapturePermissionState {
        AudioCapturePermissionState(screenCapture: .granted, audioUsageDescription: .present)
    }
    func requestScreenCaptureAccess() -> AudioCapturePermissionState { currentState() }
    func openPrivacySettings() {}
    func relaunchApp() async throws {}
}

private final class TransactionBackend: AudioBackend, AudioBackendTapSynchronizing,
    AudioBackendUpdatePublishing, @unchecked Sendable
{
    private let lock = NSLock()
    private let events: AsyncStream<Void>
    private var storedSnapshot: AudioBackendSnapshot
    private var storedCommands: [AudioBackendCommand] = []
    private var storedSynchronizationHistory: [Set<AudioAppIdentity>] = []
    private var storedTapTeardownIdentities: [AudioAppIdentity] = []
    private var storedTearDownAllCount = 0
    private var applyCallCount = 0
    private var synchronizationCallCount = 0
    private var tapTeardownCallCount = 0
    private var tearDownAllCallCount = 0
    private var failingApplyCalls: Set<Int> = []
    private var failingSynchronizationCalls: Set<Int> = []
    private var failingTapTeardownCalls: Set<Int> = []
    private var failingTearDownAllCalls: Set<Int> = []

    init(apps: [AudioAppSnapshot] = [], devices: [AudioDeviceSnapshot] = []) {
        storedSnapshot = AudioBackendSnapshot(apps: apps, devices: devices)
        events = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { _ in }
    }

    var commands: [AudioBackendCommand] { lock.withLock { storedCommands } }
    var synchronizationHistory: [Set<AudioAppIdentity>] {
        lock.withLock { storedSynchronizationHistory }
    }
    var tapTeardownIdentities: [AudioAppIdentity] {
        lock.withLock { storedTapTeardownIdentities }
    }
    var tearDownAllCount: Int { lock.withLock { storedTearDownAllCount } }
    var updateEvents: AsyncStream<Void> { events }

    func failNextApplies(count: Int = 1) {
        lock.withLock {
            for offset in 1...count { failingApplyCalls.insert(applyCallCount + offset) }
        }
    }

    func failNextSynchronizations(count: Int = 1) {
        lock.withLock {
            for offset in 1...count {
                failingSynchronizationCalls.insert(synchronizationCallCount + offset)
            }
        }
    }

    func failNextTapTeardown() {
        _ = lock.withLock { failingTapTeardownCalls.insert(tapTeardownCallCount + 1) }
    }

    func failNextTearDownAll() {
        _ = lock.withLock { failingTearDownAllCalls.insert(tearDownAllCallCount + 1) }
    }

    func fetchSnapshot() throws -> AudioBackendSnapshot {
        lock.withLock { storedSnapshot }
    }

    func apply(_ command: AudioBackendCommand) throws {
        let shouldFail = lock.withLock {
            applyCallCount += 1
            storedCommands.append(command)
            return failingApplyCalls.remove(applyCallCount) != nil
        }
        if shouldFail { throw TransactionBackendError.injected("apply") }
    }

    func synchronizeTaps(
        activeAppIDs: Set<AudioAppIdentity>,
        ignoredAppIDs: Set<AudioAppIdentity>
    ) throws {
        let shouldFail = lock.withLock {
            synchronizationCallCount += 1
            storedSynchronizationHistory.append(ignoredAppIDs)
            return failingSynchronizationCalls.remove(synchronizationCallCount) != nil
        }
        if shouldFail { throw TransactionBackendError.injected("synchronize") }
    }

    func tearDownTap(for identity: AudioAppIdentity) throws {
        let shouldFail = lock.withLock {
            tapTeardownCallCount += 1
            storedTapTeardownIdentities.append(identity)
            return failingTapTeardownCalls.remove(tapTeardownCallCount) != nil
        }
        if shouldFail { throw TransactionBackendError.injected("tap teardown") }
    }

    func tearDownAllTaps() throws {
        let shouldFail = lock.withLock {
            tearDownAllCallCount += 1
            storedTearDownAllCount += 1
            return failingTearDownAllCalls.remove(tearDownAllCallCount) != nil
        }
        if shouldFail { throw TransactionBackendError.injected("teardown all") }
    }
}

private enum TransactionBackendError: LocalizedError {
    case injected(String)

    var errorDescription: String? {
        switch self {
        case let .injected(operation): "Injected \(operation) failure."
        }
    }
}
