import Foundation

struct AudioOutputSnapshot: Equatable, Sendable {
    let defaultOutput: OutputVolumeState
    let devices: [String: OutputVolumeState]
}

struct AudioEngineSnapshot: Equatable, Sendable {
    let backend: AudioBackendSnapshot
    let output: AudioOutputSnapshot
    let statusMessage: String
    let restoreIssue: String?
    let tapIssue: String?
}

struct AudioBackendSwitchToken: Hashable, Sendable {
    fileprivate let id: UUID
}

struct AudioEngineShutdownReport: Equatable, Sendable {
    let stoppedTopologyObservation: Bool
    let stoppedOutputObservation: Bool
    let stoppedMeterObservation: Bool
    let teardownErrorDescription: String?

    var succeeded: Bool { teardownErrorDescription == nil }
}

private enum AudioEngineError: LocalizedError {
    case backendUnavailable
    case switchAlreadyPending
    case invalidSwitchToken

    var errorDescription: String? {
        switch self {
        case .backendUnavailable: "The audio backend is unavailable."
        case .switchAlreadyPending: "Another audio backend switch is already pending."
        case .invalidSwitchToken: "The audio backend switch token is no longer valid."
        }
    }
}

/// Exclusive owner of backend discovery, HAL listeners, output observation,
/// metering, and process-tap lifecycle. No backend method is called by the
/// main-actor store directly.
actor AudioEngineActor {
    typealias BackendFactory = @Sendable (BackendMode) -> any AudioBackend

    nonisolated let topologyEvents: AsyncStream<Void>
    nonisolated let outputEvents: AsyncStream<AudioOutputSnapshot>
    nonisolated let levelEvents: AsyncStream<[AudioAppIdentity: Double]>

    private let topologyContinuation: AsyncStream<Void>.Continuation
    private let outputContinuation: AsyncStream<AudioOutputSnapshot>.Continuation
    private let levelContinuation: AsyncStream<[AudioAppIdentity: Double]>.Continuation
    private let backendFactory: BackendFactory
    private var backend: (any AudioBackend)?
    private var mode: BackendMode
    private var restoredBackendIdentities: Set<AudioAppIdentity> = []
    private var lastDevices: [AudioDeviceSnapshot] = []

    private var topologyObservationTask: Task<Void, Never>?
    private var pendingTopologyTask: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?
    private var observingOutput = false
    private var observationDebounceNanoseconds: UInt64 = 250_000_000
    private var meterIntervalNanoseconds: UInt64 = 100_000_000

    private struct PendingSwitch {
        let token: AudioBackendSwitchToken
        let previousBackend: any AudioBackend
        let previousMode: BackendMode
        let previousRestoredIdentities: Set<AudioAppIdentity>
        let wasObserving: Bool
        let isNoOp: Bool
    }
    private var pendingSwitch: PendingSwitch?
    private var shutdownReport: AudioEngineShutdownReport?

    init(
        backend: sending (any AudioBackend)? = nil,
        initialMode: BackendMode,
        backendFactory: @escaping BackendFactory
    ) {
        var topologyContinuation: AsyncStream<Void>.Continuation!
        var outputContinuation: AsyncStream<AudioOutputSnapshot>.Continuation!
        var levelContinuation: AsyncStream<[AudioAppIdentity: Double]>.Continuation!
        self.topologyEvents = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            topologyContinuation = $0
        }
        self.outputEvents = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            outputContinuation = $0
        }
        self.levelEvents = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            levelContinuation = $0
        }
        self.topologyContinuation = topologyContinuation
        self.outputContinuation = outputContinuation
        self.levelContinuation = levelContinuation
        self.backend = backend
        self.mode = initialMode
        self.backendFactory = backendFactory
    }

    func currentMode() -> BackendMode { mode }

    func selectInitialMode(_ initialMode: BackendMode) {
        guard pendingSwitch == nil,
              restoredBackendIdentities.isEmpty,
              !isObserving,
              shutdownReport == nil else { return }
        mode = initialMode
    }

    func fetchSnapshot(
        settings: PersistedSettings,
        permissionAllowsTaps: Bool
    ) throws -> AudioEngineSnapshot {
        let backend = ensureBackend()
        let snapshot = try backend.fetchSnapshot()
        lastDevices = snapshot.devices

        var restoreIssue: String?
        for app in snapshot.apps where !restoredBackendIdentities.contains(app.identity) {
            let appSettings = settings.appSettings[app.identity] ?? AppAudioSettings(
                displayName: app.displayName,
                volume: settings.customization.defaultNewAppVolume,
                eq: EQCurve(range: settings.customization.eqGainRange)
            )
            do {
                for command in Self.restoreCommands(for: app.identity, settings: appSettings) {
                    try backend.apply(command)
                }
                restoredBackendIdentities.insert(app.identity)
            } catch {
                if restoreIssue == nil { restoreIssue = error.localizedDescription }
            }
        }

        let tapIssue: String?
        do {
            try synchronizeTaps(
                activeAppIDs: Set(snapshot.apps.map(\.identity)),
                ignoredAppIDs: settings.ignoredAppIDs,
                permissionAllowsTaps: permissionAllowsTaps
            )
            tapIssue = nil
        } catch {
            tapIssue = error.localizedDescription
        }

        let output = readOutputSnapshot(using: backend, devices: snapshot.devices)
        let status = (backend as? AudioBackendStatusProviding)?.statusMessage(
            appCount: snapshot.apps.count,
            deviceCount: snapshot.devices.count
        ) ?? "Loaded \(snapshot.apps.count) app\(snapshot.apps.count == 1 ? "" : "s")"
        return AudioEngineSnapshot(
            backend: snapshot,
            output: output,
            statusMessage: status,
            restoreIssue: restoreIssue,
            tapIssue: tapIssue
        )
    }

    func apply(_ command: AudioBackendCommand) throws {
        try ensureBackend().apply(command)
    }

    func apply(_ commands: [AudioBackendCommand]) throws {
        let backend = ensureBackend()
        for command in commands { try backend.apply(command) }
    }

    func synchronizeTaps(
        activeAppIDs: Set<AudioAppIdentity>,
        ignoredAppIDs: Set<AudioAppIdentity>,
        permissionAllowsTaps: Bool
    ) throws {
        guard let tapBackend = ensureBackend() as? AudioBackendTapSynchronizing else { return }
        guard permissionAllowsTaps else {
            try tapBackend.tearDownAllTaps()
            return
        }
        try tapBackend.synchronizeTaps(activeAppIDs: activeAppIDs, ignoredAppIDs: ignoredAppIDs)
    }

    func tearDownTap(for identity: AudioAppIdentity) throws {
        try (ensureBackend() as? AudioBackendTapSynchronizing)?.tearDownTap(for: identity)
    }

    func setOutputVolume(_ volume: Double) throws {
        try (ensureBackend() as? AudioBackendOutputVolumeControlling)?.setOutputVolume(volume)
    }

    func setOutputVolume(_ volume: Double, forUID uid: String) throws {
        try (ensureBackend() as? AudioBackendOutputVolumeControlling)?.setOutputVolume(volume, forUID: uid)
    }

    func setOutputMuted(_ muted: Bool) throws {
        try (ensureBackend() as? AudioBackendOutputVolumeControlling)?.setOutputMuted(muted)
    }

    func setOutputMuted(_ muted: Bool, forUID uid: String) throws {
        try (ensureBackend() as? AudioBackendOutputVolumeControlling)?.setOutputMuted(muted, forUID: uid)
    }

    func startObservation(
        debounceNanoseconds: UInt64 = 250_000_000,
        meterIntervalNanoseconds: UInt64 = 100_000_000
    ) {
        guard topologyObservationTask == nil, meterTask == nil, !observingOutput else { return }
        observationDebounceNanoseconds = debounceNanoseconds
        self.meterIntervalNanoseconds = meterIntervalNanoseconds
        startObservationInternal()
    }

    func stopObservation() {
        stopObservationInternal()
    }

    func beginBackendSwitch(
        to newMode: BackendMode,
        forceRecreate: Bool = false
    ) throws -> AudioBackendSwitchToken {
        guard pendingSwitch == nil else { throw AudioEngineError.switchAlreadyPending }
        let current = ensureBackend()
        let token = AudioBackendSwitchToken(id: UUID())
        let wasObserving = isObserving
        if newMode == mode, !forceRecreate {
            pendingSwitch = PendingSwitch(
                token: token,
                previousBackend: current,
                previousMode: mode,
                previousRestoredIdentities: restoredBackendIdentities,
                wasObserving: wasObserving,
                isNoOp: true
            )
            return token
        }

        stopObservationInternal()
        do {
            try (current as? AudioBackendTapSynchronizing)?.tearDownAllTaps()
        } catch {
            if wasObserving { startObservationInternal() }
            throw error
        }

        pendingSwitch = PendingSwitch(
            token: token,
            previousBackend: current,
            previousMode: mode,
            previousRestoredIdentities: restoredBackendIdentities,
            wasObserving: wasObserving,
            isNoOp: false
        )
        backend = backendFactory(newMode)
        mode = newMode
        restoredBackendIdentities.removeAll()
        lastDevices = []
        if wasObserving { startObservationInternal() }
        return token
    }

    func commitBackendSwitch(_ token: AudioBackendSwitchToken) throws {
        guard pendingSwitch?.token == token else { throw AudioEngineError.invalidSwitchToken }
        pendingSwitch = nil
    }

    func rollbackBackendSwitch(_ token: AudioBackendSwitchToken) throws {
        guard let pending = pendingSwitch, pending.token == token else {
            throw AudioEngineError.invalidSwitchToken
        }
        if pending.isNoOp {
            pendingSwitch = nil
            return
        }

        stopObservationInternal()
        do {
            try (backend as? AudioBackendTapSynchronizing)?.tearDownAllTaps()
        } catch {
            if pending.wasObserving { startObservationInternal() }
            throw error
        }
        backend = pending.previousBackend
        mode = pending.previousMode
        restoredBackendIdentities = pending.previousRestoredIdentities
        pendingSwitch = nil
        if pending.wasObserving { startObservationInternal() }
    }

    func shutdown() -> AudioEngineShutdownReport {
        if let shutdownReport { return shutdownReport }
        let stoppedTopology = topologyObservationTask != nil || pendingTopologyTask != nil
        let stoppedOutput = observingOutput
        let stoppedMeter = meterTask != nil
        stopObservationInternal()
        let teardownError: String?
        do {
            try (backend as? AudioBackendTapSynchronizing)?.tearDownAllTaps()
            teardownError = nil
        } catch {
            teardownError = error.localizedDescription
        }
        let report = AudioEngineShutdownReport(
            stoppedTopologyObservation: stoppedTopology,
            stoppedOutputObservation: stoppedOutput,
            stoppedMeterObservation: stoppedMeter,
            teardownErrorDescription: teardownError
        )
        shutdownReport = report
        return report
    }

    private var isObserving: Bool {
        topologyObservationTask != nil || meterTask != nil || observingOutput
    }

    private func ensureBackend() -> any AudioBackend {
        if let backend { return backend }
        let created = backendFactory(mode)
        backend = created
        return created
    }

    private func startObservationInternal() {
        let backend = ensureBackend()
        if let publisher = backend as? AudioBackendUpdatePublishing {
            let events = publisher.updateEvents
            topologyObservationTask = Task { [weak self] in
                for await _ in events {
                    guard !Task.isCancelled else { return }
                    await self?.scheduleTopologyEvent()
                }
            }
        }
        if let outputBackend = backend as? AudioBackendOutputVolumeControlling {
            observingOutput = true
            outputBackend.startObservingOutputVolume { [weak self] in
                Task { await self?.publishOutputSnapshot() }
            }
        }
        if backend is AudioBackendAppLevelProviding {
            meterTask = Task { [weak self] in
                await self?.runMeterLoop()
            }
        }
    }

    private func runMeterLoop() async {
        while !Task.isCancelled {
            do { try await Task.sleep(nanoseconds: meterIntervalNanoseconds) }
            catch { return }
            guard !Task.isCancelled,
                  let levels = (backend as? AudioBackendAppLevelProviding)?.consumeAppLevels() else { continue }
            levelContinuation.yield(levels)
        }
    }

    private func stopObservationInternal() {
        topologyObservationTask?.cancel()
        topologyObservationTask = nil
        pendingTopologyTask?.cancel()
        pendingTopologyTask = nil
        meterTask?.cancel()
        meterTask = nil
        if observingOutput {
            (backend as? AudioBackendOutputVolumeControlling)?.stopObservingOutputVolume()
            observingOutput = false
        }
    }

    private func scheduleTopologyEvent() {
        pendingTopologyTask?.cancel()
        let delay = observationDebounceNanoseconds
        pendingTopologyTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) }
            catch { return }
            guard !Task.isCancelled, let self else { return }
            await self.emitTopologyEvent()
        }
    }

    private func emitTopologyEvent() {
        topologyContinuation.yield(())
        pendingTopologyTask = nil
    }

    private func publishOutputSnapshot() {
        let backend = ensureBackend()
        outputContinuation.yield(readOutputSnapshot(using: backend, devices: lastDevices))
    }

    private func readOutputSnapshot(
        using backend: any AudioBackend,
        devices: [AudioDeviceSnapshot]
    ) -> AudioOutputSnapshot {
        guard let output = backend as? AudioBackendOutputVolumeControlling else {
            return AudioOutputSnapshot(defaultOutput: OutputVolumeState(), devices: [:])
        }
        let defaultState = (try? output.readOutputVolume()) ?? OutputVolumeState()
        var deviceStates: [String: OutputVolumeState] = [:]
        for device in devices {
            deviceStates[device.id] = (try? output.readOutputVolume(forUID: device.id))
                ?? OutputVolumeState(deviceName: device.name)
        }
        return AudioOutputSnapshot(defaultOutput: defaultState, devices: deviceStates)
    }

    private static func restoreCommands(
        for identity: AudioAppIdentity,
        settings: AppAudioSettings
    ) -> [AudioBackendCommand] {
        var commands: [AudioBackendCommand] = []
        let route = settings.route.normalized
        if route != .followDefault { commands.append(.setRoute(identity, route)) }
        if settings.volume != 1 { commands.append(.setVolume(identity, settings.volume)) }
        if settings.isMuted { commands.append(.setMuted(identity, true)) }
        if settings.boost != .x1 { commands.append(.setBoost(identity, settings.boost)) }
        if settings.eq.gains.contains(where: { $0 != 0 }) { commands.append(.setEQ(identity, settings.eq)) }
        return commands
    }
}
