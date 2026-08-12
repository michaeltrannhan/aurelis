import Foundation

struct AudioOutputSnapshot: Equatable, Sendable {
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
    private var restoredOutputDeviceUIDs: Set<String> = []
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
        let previousRestoredOutputDeviceUIDs: Set<String>
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
        let topology = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let output = AsyncStream<AudioOutputSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let levels = AsyncStream<[AudioAppIdentity: Double]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.topologyEvents = topology.stream
        self.outputEvents = output.stream
        self.levelEvents = levels.stream
        self.topologyContinuation = topology.continuation
        self.outputContinuation = output.continuation
        self.levelContinuation = levels.continuation
        self.backend = backend
        self.mode = initialMode
        self.backendFactory = backendFactory
    }

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
        var snapshot = try backend.fetchSnapshot()

        var restoreIssues: [String] = []
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
                restoreIssues.append(error.localizedDescription)
            }
        }

        restoreOutputSettings(
            settings,
            snapshot: &snapshot,
            backend: backend,
            issues: &restoreIssues
        )
        lastDevices = snapshot.devices

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
            restoreIssue: restoreIssues.first,
            tapIssue: tapIssue
        )
    }

    /// Lightweight topology revision for settle polling — no meter, listener,
    /// routing, or profile side effects beyond reading the current snapshot.
    func topologyRevision() throws -> TopologyRevision {
        let snapshot = try fetchTopologySnapshot()
        return TopologyRevision(
            defaultOutputUID: snapshot.devices.first(where: \.isDefault)?.id,
            availableOutputUIDs: Set(snapshot.devices.map(\.id))
        )
    }

    func fetchTopologySnapshot() throws -> AudioBackendSnapshot {
        try ensureBackend().fetchSnapshot()
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

    func setOutputVolume(_ volume: Double, forUID uid: String) throws {
        try (ensureBackend() as? AudioBackendOutputVolumeControlling)?.setOutputVolume(volume, forUID: uid)
    }

    func setOutputMuted(_ muted: Bool, forUID uid: String) throws {
        try (ensureBackend() as? AudioBackendOutputVolumeControlling)?.setOutputMuted(muted, forUID: uid)
    }

    func setDefaultOutputDevice(forUID uid: String) throws {
        try (ensureBackend() as? AudioBackendOutputVolumeControlling)?.setDefaultOutputDevice(forUID: uid)
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
                previousRestoredOutputDeviceUIDs: restoredOutputDeviceUIDs,
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
            previousRestoredOutputDeviceUIDs: restoredOutputDeviceUIDs,
            wasObserving: wasObserving,
            isNoOp: false
        )
        backend = backendFactory(newMode)
        mode = newMode
        restoredBackendIdentities.removeAll()
        restoredOutputDeviceUIDs.removeAll()
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
        restoredOutputDeviceUIDs = pending.previousRestoredOutputDeviceUIDs
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
            return AudioOutputSnapshot(devices: [:])
        }
        var deviceStates: [String: OutputVolumeState] = [:]
        for device in devices {
            deviceStates[device.id] = (try? output.readOutputVolume(forUID: device.id))
                ?? OutputVolumeState(deviceName: device.name)
        }
        return AudioOutputSnapshot(devices: deviceStates)
    }

    private func restoreOutputSettings(
        _ settings: PersistedSettings,
        snapshot: inout AudioBackendSnapshot,
        backend: any AudioBackend,
        issues: inout [String]
    ) {
        let availableUIDs = Set(snapshot.devices.map(\.id))
        restoredOutputDeviceUIDs.formIntersection(availableUIDs)
        let newlyAvailableUIDs = availableUIDs.subtracting(restoredOutputDeviceUIDs)
        guard !newlyAvailableUIDs.isEmpty else { return }
        let output = backend as? AudioBackendOutputVolumeControlling

        var failedUIDs = Set<String>()
        if let output,
           let preferred = settings.preferredOutputDeviceID,
           newlyAvailableUIDs.contains(preferred),
           snapshot.devices.contains(where: { $0.id == preferred && !$0.isDefault }) {
            do {
                try output.setDefaultOutputDevice(forUID: preferred)
                snapshot.devices = snapshot.devices.map {
                    AudioDeviceSnapshot(id: $0.id, name: $0.name, isDefault: $0.id == preferred)
                }
            } catch {
                failedUIDs.insert(preferred)
                issues.append("Couldn’t restore preferred output: \(error.localizedDescription)")
            }
        }

        for uid in newlyAvailableUIDs {
            let desired = settings.deviceSettings[uid]
            do {
                if let output, let desired {
                    let current = try output.readOutputVolume(forUID: uid)
                    if current.capabilities.canSetVolume {
                        try output.setOutputVolume(desired.volume, forUID: uid)
                    }
                    if current.capabilities.canSetMute {
                        try output.setOutputMuted(desired.isMuted, forUID: uid)
                    }
                }
                try backend.apply(.setOutputEQ(uid, desired?.eq ?? EQCurve()))
                if !failedUIDs.contains(uid) {
                    restoredOutputDeviceUIDs.insert(uid)
                }
            } catch {
                failedUIDs.insert(uid)
                let name = desired?.displayName
                    ?? snapshot.devices.first(where: { $0.id == uid })?.name
                    ?? "output"
                issues.append("Couldn’t restore \(name): \(error.localizedDescription)")
            }
        }
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
