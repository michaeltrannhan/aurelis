import XCTest
@testable import Auralis

@MainActor
final class AudioCoordinatorTests: XCTestCase {
    func testEngineActorForwardsSnapshotCommandAndStatus() async throws {
        let backend = CoordinatorBackend()
        backend.snapshot = AudioBackendSnapshot(apps: [AudioAppSnapshot(identity: .init(rawValue: "music"), displayName: "Music")])
        let engine = AudioEngineActor(
            backend: backend,
            initialMode: .mock,
            backendFactory: { _ in CoordinatorBackend() }
        )

        let snapshot = try await engine.fetchSnapshot(
            settings: PersistedSettings(),
            permissionAllowsTaps: true
        )
        XCTAssertEqual(snapshot.backend.apps.count, 1)
        try await engine.apply(.setMuted(.init(rawValue: "music"), true))
        XCTAssertEqual(backend.commands.count, 1)
        XCTAssertEqual(snapshot.statusMessage, "healthy 1/0")
    }

    func testDeniedSynchronizationTearsDownAndGrantedSynchronizationForwards() async throws {
        let backend = CoordinatorBackend()
        let engine = AudioEngineActor(
            backend: backend,
            initialMode: .mock,
            backendFactory: { _ in CoordinatorBackend() }
        )
        let music = AudioAppIdentity(rawValue: "music")

        try await engine.synchronizeTaps(activeAppIDs: [music], ignoredAppIDs: [], permissionAllowsTaps: false)
        XCTAssertEqual(backend.tearDownAllCount, 1)
        XCTAssertTrue(backend.synchronized.isEmpty)

        try await engine.synchronizeTaps(activeAppIDs: [music], ignoredAppIDs: [], permissionAllowsTaps: true)
        XCTAssertEqual(backend.synchronized, [music])
    }

    func testBackendSwitchAndShutdownTearDownOwnedBackends() async throws {
        let initial = CoordinatorBackend()
        let replacement = CoordinatorBackend()
        let engine = AudioEngineActor(
            backend: initial,
            initialMode: .coreAudioDiscovery,
            backendFactory: { _ in replacement }
        )

        let token = try await engine.beginBackendSwitch(to: .mock)
        try await engine.commitBackendSwitch(token)
        XCTAssertEqual(initial.tearDownAllCount, 1)
        let report = await engine.shutdown()
        XCTAssertEqual(replacement.tearDownAllCount, 1)
        XCTAssertTrue(report.succeeded)
    }

    func testTopologyObservationStopsSymmetricallyAndRestartsWithFreshStream() async {
        let backend = ObservingCoordinatorBackend()
        let engine = AudioEngineActor(
            backend: backend,
            initialMode: .mock,
            backendFactory: { _ in ObservingCoordinatorBackend() }
        )
        await engine.startObservation(debounceNanoseconds: 0)
        XCTAssertEqual(backend.startCount, 1)
        await engine.stopObservation()
        XCTAssertEqual(backend.stopCount, 1)
        await engine.startObservation(debounceNanoseconds: 0)
        XCTAssertEqual(backend.startCount, 2)
        let report = await engine.shutdown()
        XCTAssertTrue(report.stoppedTopologyObservation)
        XCTAssertEqual(backend.stopCount, 2)
        await engine.startObservation()
        XCTAssertEqual(backend.startCount, 2, "Shutdown must close observation admission")
    }

    func testConcurrentShutdownClosesDirectBackendAdmission() async throws {
        let backend = CoordinatorBackend()
        let engine = AudioEngineActor(
            backend: backend,
            initialMode: .mock,
            backendFactory: { _ in CoordinatorBackend() }
        )
        async let first = engine.shutdown()
        async let second = engine.shutdown()
        let reports = await (first, second)
        XCTAssertEqual(reports.0, reports.1)
        XCTAssertEqual(backend.tearDownAllCount, 1)
        do {
            _ = try await engine.fetchTopologySnapshot()
            XCTFail("A stopped engine must reject discovery")
        } catch {}
        do {
            try await engine.apply(.setMuted(.init(rawValue: "music"), true))
            XCTFail("A stopped engine must reject commands")
        } catch {}
        do {
            _ = try await engine.beginBackendSwitch(to: .coreAudioDiscovery)
            XCTFail("A stopped engine must reject backend replacement")
        } catch {}
        XCTAssertTrue(backend.commands.isEmpty)
        XCTAssertEqual(backend.tearDownAllCount, 1)
    }

    func testMeterObservationTaskDoesNotRetainReleasedEngine() async {
        weak var releasedEngine: AudioEngineActor?
        var engine: AudioEngineActor? = AudioEngineActor(
            backend: MeteringCoordinatorBackend(),
            initialMode: .mock,
            backendFactory: { _ in MeteringCoordinatorBackend() }
        )
        releasedEngine = engine

        await engine?.startObservation(meterIntervalNanoseconds: 60_000_000_000)
        engine = nil
        for _ in 0..<100 where releasedEngine != nil {
            await Task.yield()
        }

        XCTAssertNil(releasedEngine, "The engine's meter task must not form an owner-task retain cycle")
    }

    func testPermissionCoordinatorMapsAndDelegates() {
        let client = CoordinatorPermissionClient(state: .init(screenCapture: .denied, audioUsageDescription: .present))
        let coordinator = AudioPermissionCoordinator(client: client)

        XCTAssertEqual(coordinator.state.screenCapture, .denied)
        XCTAssertEqual(coordinator.requestAudioCapture().screenCapture, .denied)
        coordinator.openAudioPrivacySettings()
        XCTAssertEqual(client.openCount, 1)
    }

    func testPendingRestartStaysStickyAcrossRefresh() async throws {
        // Request returns pendingRestart; the OS keeps reporting notDetermined until
        // relaunch. refresh() must not regress the surfaced state back to notRequested.
        let client = CoordinatorPermissionClient(
            state: .init(screenCapture: .notDetermined, audioUsageDescription: .present),
            requestState: .init(screenCapture: .pendingRestart, audioUsageDescription: .present)
        )
        let coordinator = AudioPermissionCoordinator(client: client)

        XCTAssertEqual(coordinator.requestAudioCapture().screenCapture, .pendingRestart)
        XCTAssertEqual(coordinator.refresh().screenCapture, .pendingRestart)
        try await coordinator.relaunchApp()
        XCTAssertEqual(client.relaunchCount, 1)
    }

    func testDeviceSettingsRestoreOnStartupAndReconnectWithoutFightingLiveChanges() async throws {
        let device = AudioDeviceSnapshot(id: "home-speaker", name: "Home Speaker")
        let backend = ReconnectOutputBackend(device: device, volume: 0.2, isMuted: false)
        let engine = AudioEngineActor(
            backend: backend,
            initialMode: .mock,
            backendFactory: { _ in MockAudioBackend() }
        )
        let settings = PersistedSettings(
            deviceSettings: [
                device.id: DeviceAudioSettings(
                    displayName: device.name,
                    volume: 0.68,
                    isMuted: true
                )
            ],
            preferredOutputDeviceID: device.id
        )

        var snapshot = try await engine.fetchSnapshot(
            settings: settings,
            permissionAllowsTaps: false
        )
        XCTAssertEqual(snapshot.output.devices[device.id]?.volume ?? -1, 0.68, accuracy: 0.001)
        XCTAssertTrue(snapshot.output.devices[device.id]?.isMuted ?? false)
        XCTAssertEqual(backend.selectedDefaultOutputDeviceID, device.id)

        backend.setState(volume: 0.31, isMuted: false, for: device.id)
        snapshot = try await engine.fetchSnapshot(
            settings: settings,
            permissionAllowsTaps: false
        )
        XCTAssertEqual(snapshot.output.devices[device.id]?.volume ?? -1, 0.31, accuracy: 0.001)
        XCTAssertFalse(snapshot.output.devices[device.id]?.isMuted ?? true)

        backend.setDevices([])
        _ = try await engine.fetchSnapshot(settings: settings, permissionAllowsTaps: false)
        backend.setDevices([device])
        snapshot = try await engine.fetchSnapshot(
            settings: settings,
            permissionAllowsTaps: false
        )
        XCTAssertEqual(snapshot.output.devices[device.id]?.volume ?? -1, 0.68, accuracy: 0.001)
        XCTAssertTrue(snapshot.output.devices[device.id]?.isMuted ?? false)
    }
}

private final class ReconnectOutputBackend: AudioBackend, AudioBackendOutputVolumeControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var devices: [AudioDeviceSnapshot]
    private var volumes: [String: Double]
    private var muted: [String: Bool]
    private var selectedDefault: String?

    init(device: AudioDeviceSnapshot, volume: Double, isMuted: Bool) {
        devices = [device]
        volumes = [device.id: volume]
        muted = [device.id: isMuted]
    }

    var selectedDefaultOutputDeviceID: String? {
        lock.withLock { selectedDefault }
    }

    func setDevices(_ devices: [AudioDeviceSnapshot]) {
        lock.withLock { self.devices = devices }
    }

    func setState(volume: Double, isMuted: Bool, for uid: String) {
        lock.withLock {
            volumes[uid] = volume
            muted[uid] = isMuted
        }
    }

    func fetchSnapshot() throws -> AudioBackendSnapshot {
        lock.withLock { AudioBackendSnapshot(devices: devices) }
    }

    func apply(_ command: AudioBackendCommand) throws {}

    func readOutputVolume(forUID uid: String) throws -> OutputVolumeState {
        lock.withLock {
            OutputVolumeState(
                volume: volumes[uid] ?? 1,
                isMuted: muted[uid] ?? false,
                deviceName: devices.first(where: { $0.id == uid })?.name,
                capabilities: .controllable
            )
        }
    }

    func setOutputVolume(_ volume: Double, forUID uid: String) throws {
        lock.withLock { volumes[uid] = volume }
    }

    func setOutputMuted(_ muted: Bool, forUID uid: String) throws {
        lock.withLock { self.muted[uid] = muted }
    }

    func setDefaultOutputDevice(forUID uid: String) throws {
        lock.withLock {
            selectedDefault = uid
            devices = devices.map {
                AudioDeviceSnapshot(id: $0.id, name: $0.name, isDefault: $0.id == uid)
            }
        }
    }

    func startObservingOutputVolume(_ onChange: @escaping @Sendable () -> Void) {}
    func stopObservingOutputVolume() {}
}

private final class CoordinatorBackend: AudioBackend, AudioBackendStatusProviding, AudioBackendTapSynchronizing, @unchecked Sendable {
    private let lock = NSLock()
    private var storedSnapshot = AudioBackendSnapshot()
    private var storedCommands: [AudioBackendCommand] = []
    private var storedSynchronized: Set<AudioAppIdentity> = []
    private var storedTearDownAllCount = 0

    var snapshot: AudioBackendSnapshot {
        get { lock.withLock { storedSnapshot } }
        set { lock.withLock { storedSnapshot = newValue } }
    }
    var commands: [AudioBackendCommand] { lock.withLock { storedCommands } }
    var synchronized: Set<AudioAppIdentity> { lock.withLock { storedSynchronized } }
    var tearDownAllCount: Int { lock.withLock { storedTearDownAllCount } }

    func fetchSnapshot() throws -> AudioBackendSnapshot { snapshot }
    func apply(_ command: AudioBackendCommand) throws { lock.withLock { storedCommands.append(command) } }
    func statusMessage(appCount: Int, deviceCount: Int) -> String { "healthy \(appCount)/\(deviceCount)" }
    func synchronizeTaps(activeAppIDs: Set<AudioAppIdentity>, ignoredAppIDs: Set<AudioAppIdentity>) throws {
        lock.withLock { storedSynchronized = activeAppIDs.subtracting(ignoredAppIDs) }
    }
    func tearDownTap(for identity: AudioAppIdentity) throws {}
    func tearDownAllTaps() throws { lock.withLock { storedTearDownAllCount += 1 } }
}

private final class MeteringCoordinatorBackend: AudioBackend, AudioBackendAppLevelProviding {
    func fetchSnapshot() throws -> AudioBackendSnapshot { AudioBackendSnapshot() }
    func apply(_ command: AudioBackendCommand) throws {}
    func consumeAppLevels() -> [AudioAppIdentity: Double] { [:] }
}

private final class CoordinatorPermissionClient: AudioCapturePermissionClient {
    let state: AudioCapturePermissionState
    let requestState: AudioCapturePermissionState
    var openCount = 0
    var relaunchCount = 0
    init(state: AudioCapturePermissionState, requestState: AudioCapturePermissionState? = nil) {
        self.state = state
        self.requestState = requestState ?? state
    }
    func currentState() -> AudioCapturePermissionState { state }
    func requestScreenCaptureAccess() -> AudioCapturePermissionState { requestState }
    func openPrivacySettings() { openCount += 1 }
    func relaunchApp() async throws { relaunchCount += 1 }
}

private final class ObservingCoordinatorBackend: AudioBackend, AudioBackendUpdatePublishing, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<Void>.Continuation?
    private var starts = 0
    private var stops = 0

    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }

    var updateEvents: AsyncStream<Void> {
        lock.withLock {
            starts += 1
            let events = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            continuation = events.continuation
            return events.stream
        }
    }

    func stopPublishingUpdates() {
        lock.withLock {
            stops += 1
            continuation?.finish()
            continuation = nil
        }
    }

    func fetchSnapshot() throws -> AudioBackendSnapshot { AudioBackendSnapshot() }
    func apply(_ command: AudioBackendCommand) throws {}
}
