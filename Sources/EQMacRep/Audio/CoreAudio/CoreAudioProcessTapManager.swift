import CoreAudio
import Foundation

protocol CoreAudioTapManaging: AnyObject {
    var activeSessions: [CoreAudioTapSession] { get }
    func reconcile(targets: [CoreAudioTapTarget]) throws
    func tearDown(identity: AudioAppIdentity) throws
    func tearDownAll() throws
}

protocol CoreAudioRealtimeTapControlling: AnyObject {
    func setVolume(_ volume: Double, for identity: AudioAppIdentity)
    func setMuted(_ muted: Bool, for identity: AudioAppIdentity)
    func setBoost(_ boost: BoostLevel, for identity: AudioAppIdentity)
    func setEQ(_ eq: EQCurve, for identity: AudioAppIdentity)
}

protocol CoreAudioRouteControlling: AnyObject {
    func setAvailableOutputUIDs(
        _ outputUIDs: [String],
        defaultOutputUIDs: [String],
        nominalSampleRatesByUID: [String: Double]
    )
    func setRoute(_ identity: AudioAppIdentity, _ route: DeviceRoute) throws
}

protocol CoreAudioTapHealthReporting: AnyObject {
    var health: CoreAudioTapHealth { get }
}

protocol CoreAudioTapLevelReporting: AnyObject {
    func consumePeakLevels() -> [AudioAppIdentity: Double]
}

protocol CoreAudioTapOperating: AnyObject {
    func createTap(for target: CoreAudioTapTarget) throws -> CoreAudioTapSession
    func destroyTap(_ tapObjectID: AudioObjectID) throws
}

enum CoreAudioTapError: LocalizedError {
    case unsupportedOS
    case createFailed(identity: AudioAppIdentity, status: OSStatus)
    case setupFailed(identity: AudioAppIdentity, operation: String, status: OSStatus)
    case destroyFailed(tapObjectID: AudioObjectID, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return "CoreAudio process taps require macOS 14.2 or newer"
        case let .createFailed(identity, status):
            return "Failed to create process tap for \(identity.rawValue): \(status)"
        case let .setupFailed(identity, operation, status):
            return "\(operation) failed for \(identity.rawValue): \(status)"
        case let .destroyFailed(tapObjectID, status):
            return "Failed to destroy process tap \(tapObjectID): \(status)"
        }
    }
}

final class SystemCoreAudioTapOperations: CoreAudioTapOperating {
    func createTap(for target: CoreAudioTapTarget) throws -> CoreAudioTapSession {
        guard #available(macOS 14.2, *) else {
            throw CoreAudioTapError.unsupportedOS
        }

        let description = CATapDescription(stereoMixdownOfProcesses: target.processObjectIDs)
        description.name = "EQMacRep \(target.displayName)"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else {
            throw CoreAudioTapError.createFailed(identity: target.identity, status: status)
        }
        return CoreAudioTapSession(
            identity: target.identity,
            tapObjectID: tapID,
            processObjectIDs: target.processObjectIDs
        )
    }

    func destroyTap(_ tapObjectID: AudioObjectID) throws {
        guard #available(macOS 14.2, *) else {
            throw CoreAudioTapError.unsupportedOS
        }

        let status = AudioHardwareDestroyProcessTap(tapObjectID)
        guard status == noErr else {
            throw CoreAudioTapError.destroyFailed(tapObjectID: tapObjectID, status: status)
        }
    }
}

enum CoreAudioTapLifecyclePhase: String, Equatable, Sendable {
    case absent
    case desired
    case starting
    case running
    case retrying
    case unhealthy
    case failed
    case stopping
}

struct CoreAudioTapLifecycleSnapshot: Equatable, Sendable {
    let phase: CoreAudioTapLifecyclePhase
    let hasTarget: Bool
    let hasSession: Bool
    let ownedControllerCount: Int
    let attemptCount: Int
    let failure: CoreAudioTapFailureDecision?
}

struct CoreAudioTapTeardownFailure: Equatable, Sendable {
    let identity: AudioAppIdentity
    let message: String
}

struct CoreAudioTapTeardownAggregateError: Error, Equatable, LocalizedError, Sendable {
    let failures: [CoreAudioTapTeardownFailure]

    var errorDescription: String? {
        failures.map { "\($0.identity.rawValue): \($0.message)" }.joined(separator: "; ")
    }
}

enum CoreAudioTapLifecycleError: Error, LocalizedError {
    case blocked(CoreAudioTapFailureDecision)

    var errorDescription: String? {
        switch self {
        case let .blocked(decision): decision.message
        }
    }
}

/// All lifecycle state is serialized on `lifecycleQueue`. Each identity owns one
/// state value containing its target, live resources, retry, route, gain, and
/// failure information; there are no independently mutable parallel maps.
final class CoreAudioProcessTapManager: CoreAudioTapManaging, CoreAudioRouteControlling, CoreAudioTapHealthReporting, CoreAudioTapLevelReporting {
    typealias RetryScheduler = (
        DispatchQueue,
        TimeInterval,
        DispatchWorkItem
    ) -> Void

    private struct OutputConfiguration: Equatable {
        var outputUIDs: [String]
    }

    private enum RetiringCleanupOutcome: Equatable {
        case preserveFailure(CoreAudioTapFailureDecision)
        case resumeExistingController
    }

    private enum RetryPurpose: Equatable {
        case configure(OutputConfiguration)
        case teardown
        case cleanupRetiring(RetiringCleanupOutcome)
    }

    private struct TapSessionState {
        var phase: CoreAudioTapLifecyclePhase = .absent
        var target: CoreAudioTapTarget?
        var session: CoreAudioTapSession?
        var controller: (any CoreAudioActiveTapControlling)?
        var retiringControllers: [any CoreAudioActiveTapControlling] = []
        var route: DeviceRoute = .followDefault
        var gainState = CoreAudioRealtimeGainState(volume: 1, boost: .x1, isMuted: false)
        var outputConfiguration: OutputConfiguration?
        var requestedConfiguration: OutputConfiguration?
        var requiresControllerReplacement = false
        var failure: CoreAudioTapFailureDecision?
        var attemptCount = 0
        var retryPurpose: RetryPurpose?
        var retryWorkItem: DispatchWorkItem?

        var ownedControllerCount: Int {
            (controller == nil ? 0 : 1) + retiringControllers.count
        }
    }

    private static let defaultGainState = CoreAudioRealtimeGainState(
        volume: 1,
        boost: .x1,
        isMuted: false
    )

    private let operations: CoreAudioTapOperating
    private let controllerFactory: (CoreAudioTapTarget, [String], CoreAudioRealtimeGainState) throws -> CoreAudioActiveTapControlling
    private let maxStartAttempts: Int
    private let automaticRetryCooldown: TimeInterval
    private let retryScheduler: RetryScheduler
    private let lifecycleQueue = DispatchQueue(label: "EQMacRep.CoreAudioTapLifecycle")
    private let lifecycleQueueKey = DispatchSpecificKey<UInt8>()

    private var statesByIdentity: [AudioAppIdentity: TapSessionState] = [:]
    private var availableOutputUIDs: [String] = []
    private var storedDefaultOutputDeviceUIDs: [String] = []

    var defaultOutputDeviceUIDs: [String] {
        get { onLifecycleQueue { storedDefaultOutputDeviceUIDs } }
        set { onLifecycleQueue { storedDefaultOutputDeviceUIDs = newValue } }
    }

    var defaultOutputDeviceUID: String? {
        get { defaultOutputDeviceUIDs.first }
        set { defaultOutputDeviceUIDs = newValue.map { [$0] } ?? [] }
    }

    init(
        operations: CoreAudioTapOperating = SystemCoreAudioTapOperations(),
        maxStartAttempts: Int = 3,
        automaticRetryCooldown: TimeInterval = 1,
        retryScheduler: @escaping RetryScheduler = { queue, delay, workItem in
            queue.asyncAfter(deadline: .now() + delay, execute: workItem)
        },
        controllerFactory: @escaping (CoreAudioTapTarget, [String], CoreAudioRealtimeGainState) throws -> CoreAudioActiveTapControlling = {
            CoreAudioTapIOController(target: $0, outputDeviceUIDs: $1, initialGainState: $2)
        }
    ) {
        self.operations = operations
        self.maxStartAttempts = max(maxStartAttempts, 1)
        self.automaticRetryCooldown = max(automaticRetryCooldown, 0)
        self.retryScheduler = retryScheduler
        self.controllerFactory = controllerFactory
        lifecycleQueue.setSpecific(key: lifecycleQueueKey, value: 1)
    }

    deinit {
        for state in statesByIdentity.values {
            state.retryWorkItem?.cancel()
        }
    }

    var health: CoreAudioTapHealth {
        onLifecycleQueue {
            var failures: [AudioAppIdentity: String] = [:]
            var activeCount = 0
            for (identity, state) in statesByIdentity {
                if state.controller != nil { activeCount += 1 }
                if let failure = state.failure { failures[identity] = failure.message }
            }
            return CoreAudioTapHealth(
                activeAppCount: activeCount,
                failedAppMessages: failures,
                backendMessage: ""
            )
        }
    }

    var activeSessions: [CoreAudioTapSession] {
        onLifecycleQueue {
            statesByIdentity.values.compactMap(\.session).sorted {
                $0.identity.rawValue < $1.identity.rawValue
            }
        }
    }

    func consumePeakLevels() -> [AudioAppIdentity: Double] {
        onLifecycleQueue {
            var levels: [AudioAppIdentity: Double] = [:]
            levels.reserveCapacity(statesByIdentity.count)
            for (identity, state) in statesByIdentity {
                guard let controller = state.controller else { continue }
                levels[identity] = Double(controller.consumePeakLevel())
            }
            return levels
        }
    }

    func lifecycleSnapshot(for identity: AudioAppIdentity) -> CoreAudioTapLifecycleSnapshot? {
        onLifecycleQueue {
            statesByIdentity[identity].map {
                CoreAudioTapLifecycleSnapshot(
                    phase: $0.phase,
                    hasTarget: $0.target != nil,
                    hasSession: $0.session != nil,
                    ownedControllerCount: $0.ownedControllerCount,
                    attemptCount: $0.attemptCount,
                    failure: $0.failure
                )
            }
        }
    }

    func reconcile(targets: [CoreAudioTapTarget]) throws {
        try onLifecycleQueue {
            let targets = Self.coalescedTargets(targets)
            let desiredIDs = Set(targets.map(\.identity))
            var teardownFailures: [CoreAudioTapTeardownFailure] = []

            for identity in Array(statesByIdentity.keys) {
                guard statesByIdentity[identity]?.target != nil,
                      !desiredIDs.contains(identity) else { continue }
                do {
                    try tearDownState(identity: identity, retainingTarget: nil, resetAttempts: true)
                } catch {
                    teardownFailures.append(.init(identity: identity, message: error.localizedDescription))
                }
            }

            for target in targets {
                var state = statesByIdentity[target.identity] ?? TapSessionState()
                let targetChanged = state.target?.processObjectIDs != target.processObjectIDs
                state.target = target

                if targetChanged, state.ownedControllerCount > 0 || state.session != nil {
                    statesByIdentity[target.identity] = state
                    do {
                        try tearDownState(identity: target.identity, retainingTarget: target, resetAttempts: true)
                    } catch {
                        continue
                    }
                    state = statesByIdentity[target.identity] ?? state
                }

                if state.retryWorkItem != nil
                    || isTerminalFailure(state.failure)
                    || isRetryExhausted(state) {
                    statesByIdentity[target.identity] = state
                    continue
                }

                statesByIdentity[target.identity] = state
                do {
                    try ensureConfigured(identity: target.identity, resetAttempts: state.phase == .absent)
                } catch {
                    // Failure state and any retry are already recorded.
                }
            }

            if !teardownFailures.isEmpty {
                throw CoreAudioTapTeardownAggregateError(failures: teardownFailures)
            }
        }
    }

    func tearDown(identity: AudioAppIdentity) throws {
        try onLifecycleQueue {
            try tearDownState(identity: identity, retainingTarget: nil, resetAttempts: true)
        }
    }

    func tearDownAll() throws {
        try onLifecycleQueue {
            var failures: [CoreAudioTapTeardownFailure] = []
            for identity in Array(statesByIdentity.keys).sorted(by: { $0.rawValue < $1.rawValue }) {
                do {
                    try tearDownState(identity: identity, retainingTarget: nil, resetAttempts: true)
                } catch {
                    failures.append(.init(identity: identity, message: error.localizedDescription))
                }
            }
            if !failures.isEmpty {
                throw CoreAudioTapTeardownAggregateError(failures: failures)
            }
        }
    }

    /// Compatibility entry point used by shutdown. Failed resources deliberately
    /// remain in their identity state for the next retry/recovery pass.
    func stopAll() {
        try? tearDownAll()
    }

    func gainState(for identity: AudioAppIdentity) -> CoreAudioRealtimeGainState? {
        onLifecycleQueue { statesByIdentity[identity]?.gainState }
    }

    // MARK: Routing

    func setAvailableOutputUIDs(
        _ outputUIDs: [String],
        defaultOutputUIDs: [String],
        nominalSampleRatesByUID: [String: Double]
    ) {
        onLifecycleQueue {
            // Aggregate-device nominal-rate listeners are the single source of
            // DSP rate changes. Physical-rate notifications no longer rebuild a
            // tap controller and race that listener.
            _ = nominalSampleRatesByUID
            let outputs = Self.uniqueNonempty(outputUIDs)
            let defaults = Self.uniqueNonempty(defaultOutputUIDs)
            let topologyChanged = availableOutputUIDs != outputs
                || storedDefaultOutputDeviceUIDs != defaults
            availableOutputUIDs = outputs
            storedDefaultOutputDeviceUIDs = defaults
            guard topologyChanged else { return }

            for identity in Array(statesByIdentity.keys) {
                guard var state = statesByIdentity[identity], state.target != nil else { continue }
                let configuration = resolvedOutputConfiguration(for: identity, state: state)
                if configuration != state.requestedConfiguration {
                    cancelRetry(in: &state)
                    state.attemptCount = 0
                    if state.failure?.shouldRetry == true { state.failure = nil }
                    statesByIdentity[identity] = state
                } else if state.retryWorkItem != nil
                            || isRetryExhausted(state)
                            || isTerminalFailure(state.failure) {
                    continue
                }
                do {
                    try ensureConfigured(identity: identity, resetAttempts: false)
                } catch {
                    // Unified retry scheduling is handled by ensureConfigured.
                }
            }
        }
    }

    func setAvailableOutputUIDs(_ outputUIDs: [String], defaultOutputUIDs: [String]) {
        setAvailableOutputUIDs(
            outputUIDs,
            defaultOutputUIDs: defaultOutputUIDs,
            nominalSampleRatesByUID: [:]
        )
    }

    func setAvailableOutputUIDs(_ outputUIDs: [String], defaultOutputUID: String?) {
        setAvailableOutputUIDs(
            outputUIDs,
            defaultOutputUIDs: defaultOutputUID.map { [$0] } ?? [],
            nominalSampleRatesByUID: [:]
        )
    }

    func setRoute(_ identity: AudioAppIdentity, _ route: DeviceRoute) throws {
        try onLifecycleQueue {
            var state = statesByIdentity[identity] ?? TapSessionState()
            let previousRoute = state.route
            state.route = route.normalized
            cancelRetry(in: &state)
            state.attemptCount = 0
            statesByIdentity[identity] = state

            guard state.target != nil else {
                pruneIfEligible(identity)
                return
            }
            if let failure = state.failure, isTerminalFailure(failure) {
                state.route = previousRoute
                statesByIdentity[identity] = state
                throw CoreAudioTapLifecycleError.blocked(failure)
            }

            do {
                try ensureConfigured(identity: identity, resetAttempts: false)
            } catch {
                var failedState = statesByIdentity[identity] ?? state
                failedState.route = previousRoute
                cancelRetry(in: &failedState)
                let rolledBackConfiguration = resolvedOutputConfiguration(
                    for: identity,
                    state: failedState
                )
                failedState.requestedConfiguration = rolledBackConfiguration

                if failedState.requiresControllerReplacement {
                    scheduleRetryIfAllowed(
                        .configure(rolledBackConfiguration),
                        in: &failedState,
                        identity: identity
                    )
                } else if !failedState.retiringControllers.isEmpty,
                          failedState.controller != nil {
                    // The requested replacement failed and its rollback also
                    // failed. Clean up that retained replacement, but do not
                    // retry the rejected route or disturb the old controller.
                    failedState.phase = .stopping
                    scheduleRetryIfAllowed(
                        .cleanupRetiring(.resumeExistingController),
                        in: &failedState,
                        identity: identity
                    )
                } else if !failedState.retiringControllers.isEmpty,
                          let failure = failedState.failure,
                          isTerminalFailure(failure) {
                    failedState.phase = .stopping
                    scheduleRetryIfAllowed(
                        .cleanupRetiring(.preserveFailure(failure)),
                        in: &failedState,
                        identity: identity
                    )
                } else if failedState.controller != nil,
                          failedState.outputConfiguration == rolledBackConfiguration {
                    // The old controller was never disturbed, so rollback is
                    // complete even though applying the requested route failed.
                    completeSuccessfulTransition(in: &failedState)
                } else if failedState.failure?.shouldRetry == true {
                    scheduleRetryIfAllowed(
                        .configure(rolledBackConfiguration),
                        in: &failedState,
                        identity: identity
                    )
                }
                statesByIdentity[identity] = failedState
                throw error
            }
        }
    }

    func resolvedOutputUIDs(for identity: AudioAppIdentity) -> [String] {
        onLifecycleQueue {
            let state = statesByIdentity[identity] ?? TapSessionState()
            return resolvedOutputConfiguration(for: identity, state: state).outputUIDs
        }
    }

    func resolvedOutputUID(for identity: AudioAppIdentity) -> String? {
        resolvedOutputUIDs(for: identity).first
    }

    // MARK: State transitions

    private func ensureConfigured(identity: AudioAppIdentity, resetAttempts: Bool) throws {
        guard var state = statesByIdentity[identity], state.target != nil else { return }
        if resetAttempts {
            cancelRetry(in: &state)
            state.attemptCount = 0
        }
        if isTerminalFailure(state.failure) { return }

        let configuration = resolvedOutputConfiguration(for: identity, state: state)
        state.requestedConfiguration = configuration
        if state.controller != nil,
           state.outputConfiguration == configuration,
           !state.requiresControllerReplacement,
           state.retiringControllers.isEmpty {
            state.phase = .running
            state.failure = nil
            state.attemptCount = 0
            cancelRetry(in: &state)
            statesByIdentity[identity] = state
            return
        }

        if !state.retiringControllers.isEmpty {
            let attemptsBeforeCleanup = state.attemptCount
            state.attemptCount += 1
            do {
                try destroyRetiringControllers(in: &state, identity: identity)
                // A successful cleanup makes way for the configuration attempt;
                // it does not consume that attempt as well.
                state.attemptCount = attemptsBeforeCleanup
            } catch {
                recordFailure(error, purpose: .configure(configuration), in: &state, identity: identity)
                statesByIdentity[identity] = state
                throw error
            }
        }

        if state.controller != nil,
           state.outputConfiguration == configuration,
           !state.requiresControllerReplacement {
            completeSuccessfulTransition(in: &state)
            statesByIdentity[identity] = state
            return
        }

        guard !configuration.outputUIDs.isEmpty else {
            state.attemptCount += 1
            let error = CoreAudioTapStartFailure.deviceUnavailable
            recordFailure(error, purpose: .configure(configuration), in: &state, identity: identity)
            statesByIdentity[identity] = state
            throw error
        }

        do {
            if state.controller == nil {
                try startInitialController(
                    identity: identity,
                    configuration: configuration,
                    state: &state
                )
            } else {
                try replaceController(
                    identity: identity,
                    configuration: configuration,
                    state: &state
                )
            }
        } catch {
            statesByIdentity[identity] = state
            throw error
        }
        statesByIdentity[identity] = state
    }

    private func startInitialController(
        identity: AudioAppIdentity,
        configuration: OutputConfiguration,
        state: inout TapSessionState
    ) throws {
        guard let target = state.target else { return }
        state.phase = .starting
        state.attemptCount += 1
        let controller: any CoreAudioActiveTapControlling
        do {
            controller = try controllerFactory(target, configuration.outputUIDs, state.gainState)
        } catch {
            recordFailure(error, purpose: .configure(configuration), in: &state, identity: identity)
            throw error
        }

        do {
            let session = try controller.start()
            state.controller = controller
            state.session = session
            state.outputConfiguration = configuration
            state.requiresControllerReplacement = false
            completeSuccessfulTransition(in: &state)
        } catch let startError {
            do {
                try controller.stop()
            } catch {
                state.retiringControllers.append(controller)
                let decision = classifyFailure(startError)
                if decision.shouldRetry {
                    recordFailure(
                        startError,
                        purpose: .configure(configuration),
                        in: &state,
                        identity: identity
                    )
                } else {
                    state.failure = decision
                    state.phase = .stopping
                    scheduleRetryIfAllowed(
                        .cleanupRetiring(.preserveFailure(decision)),
                        in: &state,
                        identity: identity
                    )
                }
                throw startError
            }
            recordFailure(startError, purpose: .configure(configuration), in: &state, identity: identity)
            throw startError
        }
    }

    private func replaceController(
        identity: AudioAppIdentity,
        configuration: OutputConfiguration,
        state: inout TapSessionState
    ) throws {
        guard let target = state.target,
              let oldController = state.controller else { return }
        state.phase = .starting
        state.attemptCount += 1

        let replacement: any CoreAudioActiveTapControlling
        do {
            replacement = try controllerFactory(target, configuration.outputUIDs, state.gainState)
        } catch {
            recordFailure(error, purpose: .configure(configuration), in: &state, identity: identity)
            throw error
        }

        let replacementSession: CoreAudioTapSession
        do {
            replacementSession = try replacement.start()
        } catch let startError {
            do {
                try replacement.stop()
            } catch {
                state.retiringControllers.append(replacement)
                let decision = classifyFailure(startError)
                if decision.shouldRetry {
                    recordFailure(
                        startError,
                        purpose: .configure(configuration),
                        in: &state,
                        identity: identity
                    )
                } else {
                    state.failure = decision
                    state.phase = .stopping
                    scheduleRetryIfAllowed(
                        .cleanupRetiring(.preserveFailure(decision)),
                        in: &state,
                        identity: identity
                    )
                }
                throw startError
            }
            recordFailure(startError, purpose: .configure(configuration), in: &state, identity: identity)
            throw startError
        }

        do {
            try oldController.stop()
        } catch {
            // Roll back to the prior controller/configuration. If replacement
            // rollback itself cannot finish, retain it explicitly for teardown.
            if (try? replacement.stop()) == nil {
                state.retiringControllers.append(replacement)
            }
            state.requiresControllerReplacement = true
            let teardownError = CoreAudioTapTeardownAggregateError(failures: [
                .init(identity: identity, message: error.localizedDescription)
            ])
            recordFailure(
                teardownError,
                purpose: .configure(configuration),
                in: &state,
                identity: identity
            )
            throw error
        }

        state.controller = replacement
        state.session = replacementSession
        state.outputConfiguration = configuration
        state.requiresControllerReplacement = false
        completeSuccessfulTransition(in: &state)
    }

    private func tearDownState(
        identity: AudioAppIdentity,
        retainingTarget: CoreAudioTapTarget?,
        resetAttempts: Bool
    ) throws {
        guard var state = statesByIdentity[identity] else { return }
        state.target = retainingTarget
        cancelRetry(in: &state)
        if resetAttempts { state.attemptCount = 0 }
        state.phase = .stopping
        state.attemptCount += 1

        var failures: [CoreAudioTapTeardownFailure] = []
        if let controller = state.controller {
            do {
                try controller.stop()
                state.controller = nil
                state.session = nil
                state.outputConfiguration = nil
                state.requestedConfiguration = nil
                state.requiresControllerReplacement = false
            } catch {
                failures.append(.init(identity: identity, message: error.localizedDescription))
            }
        } else if let session = state.session {
            do {
                try operations.destroyTap(session.tapObjectID)
                state.session = nil
                state.outputConfiguration = nil
                state.requestedConfiguration = nil
            } catch {
                failures.append(.init(identity: identity, message: error.localizedDescription))
            }
        }

        var remainingRetiring: [any CoreAudioActiveTapControlling] = []
        for controller in state.retiringControllers {
            do {
                try controller.stop()
            } catch {
                remainingRetiring.append(controller)
                failures.append(.init(identity: identity, message: error.localizedDescription))
            }
        }
        state.retiringControllers = remainingRetiring

        if !failures.isEmpty {
            let error = CoreAudioTapTeardownAggregateError(failures: failures)
            state.failure = .recoverable(error.localizedDescription)
            state.phase = .stopping
            scheduleRetryIfAllowed(.teardown, in: &state, identity: identity)
            statesByIdentity[identity] = state
            throw error
        }

        state.failure = nil
        state.attemptCount = 0
        state.phase = retainingTarget == nil ? .absent : .desired
        statesByIdentity[identity] = state
        if retainingTarget == nil {
            pruneIfEligible(identity)
        } else {
            do {
                try ensureConfigured(identity: identity, resetAttempts: true)
            } catch {
                // Desired target remains represented and owns its retry state.
            }
        }
    }

    private func destroyRetiringControllers(
        in state: inout TapSessionState,
        identity: AudioAppIdentity
    ) throws {
        var failures: [CoreAudioTapTeardownFailure] = []
        var remaining: [any CoreAudioActiveTapControlling] = []
        for controller in state.retiringControllers {
            do {
                try controller.stop()
            } catch {
                remaining.append(controller)
                failures.append(.init(identity: identity, message: error.localizedDescription))
            }
        }
        state.retiringControllers = remaining
        if !failures.isEmpty {
            throw CoreAudioTapTeardownAggregateError(failures: failures)
        }
    }

    private func recordFailure(
        _ error: Error,
        purpose: RetryPurpose,
        in state: inout TapSessionState,
        identity: AudioAppIdentity
    ) {
        let decision = classifyFailure(error)
        state.failure = decision
        state.phase = state.controller == nil ? .failed : .unhealthy
        guard decision.shouldRetry else {
            cancelRetry(in: &state)
            return
        }
        if state.attemptCount < maxStartAttempts {
            state.phase = state.controller == nil ? .retrying : .unhealthy
            scheduleRetryIfAllowed(purpose, in: &state, identity: identity)
        } else {
            cancelRetry(in: &state)
        }
    }

    private func scheduleRetryIfAllowed(
        _ purpose: RetryPurpose,
        in state: inout TapSessionState,
        identity: AudioAppIdentity
    ) {
        cancelRetry(in: &state)
        guard state.attemptCount < maxStartAttempts else { return }
        let exponent = max(state.attemptCount - 1, 0)
        let delay = automaticRetryCooldown * pow(2, Double(exponent))
        let workItem = DispatchWorkItem { [weak self] in
            self?.onLifecycleQueue {
                self?.performRetry(identity: identity, purpose: purpose)
            }
        }
        state.retryPurpose = purpose
        state.retryWorkItem = workItem
        retryScheduler(lifecycleQueue, delay, workItem)
    }

    private func performRetry(identity: AudioAppIdentity, purpose: RetryPurpose) {
        guard var state = statesByIdentity[identity], state.retryPurpose == purpose else { return }
        state.retryWorkItem = nil
        state.retryPurpose = nil
        statesByIdentity[identity] = state

        switch purpose {
        case .teardown:
            do {
                try tearDownState(
                    identity: identity,
                    retainingTarget: state.target,
                    resetAttempts: false
                )
            } catch {
                // The teardown state retained every failed handle and rescheduled.
            }
        case let .cleanupRetiring(outcome):
            state.phase = .stopping
            state.attemptCount += 1
            do {
                try destroyRetiringControllers(in: &state, identity: identity)
                state.attemptCount = 0
                switch outcome {
                case let .preserveFailure(failure):
                    state.failure = failure
                    state.phase = state.controller == nil ? .failed : .unhealthy
                case .resumeExistingController:
                    if state.controller != nil {
                        state.requestedConfiguration = state.outputConfiguration
                        completeSuccessfulTransition(in: &state)
                    } else {
                        state.failure = nil
                        state.phase = state.target == nil ? .absent : .desired
                    }
                }
            } catch {
                state.failure = .recoverable(error.localizedDescription)
                state.phase = .stopping
                scheduleRetryIfAllowed(
                    .cleanupRetiring(outcome),
                    in: &state,
                    identity: identity
                )
            }
            statesByIdentity[identity] = state
            if state.phase == .absent { pruneIfEligible(identity) }
        case let .configure(expectedConfiguration):
            guard state.target != nil else { return }
            let current = resolvedOutputConfiguration(for: identity, state: state)
            guard current == expectedConfiguration else {
                state.attemptCount = 0
                statesByIdentity[identity] = state
                do { try ensureConfigured(identity: identity, resetAttempts: false) }
                catch { }
                return
            }
            do { try ensureConfigured(identity: identity, resetAttempts: false) }
            catch { }
        }
    }

    private func completeSuccessfulTransition(in state: inout TapSessionState) {
        cancelRetry(in: &state)
        state.attemptCount = 0
        state.failure = nil
        state.phase = .running
    }

    private func cancelRetry(in state: inout TapSessionState) {
        state.retryWorkItem?.cancel()
        state.retryWorkItem = nil
        state.retryPurpose = nil
    }

    private func classifyFailure(_ error: Error) -> CoreAudioTapFailureDecision {
        if let failure = error as? CoreAudioTapStartFailure {
            return CoreAudioTapFailurePolicy.classify(failure)
        }
        if error is CoreAudioTapResourceTeardownError
            || error is CoreAudioTapTeardownAggregateError
            || error is CoreAudioAggregateOwnershipJournalError {
            return .recoverable(error.localizedDescription)
        }
        if let tapError = error as? CoreAudioTapError {
            switch tapError {
            case .unsupportedOS:
                return .unsupported("App cannot be tapped")
            case let .createFailed(_, status):
                return CoreAudioTapFailurePolicy.classify(.osStatus(status, operation: "Tap create"))
            case let .setupFailed(_, operation, status):
                return CoreAudioTapFailurePolicy.classify(.osStatus(status, operation: operation))
            case let .destroyFailed(_, status):
                return CoreAudioTapFailurePolicy.classify(.osStatus(status, operation: "Tap destroy"))
            }
        }
        return .fatal(error.localizedDescription)
    }

    private func isTerminalFailure(_ decision: CoreAudioTapFailureDecision?) -> Bool {
        guard let decision else { return false }
        return !decision.shouldRetry
    }

    private func isRetryExhausted(_ state: TapSessionState) -> Bool {
        state.failure?.shouldRetry == true
            && state.retryWorkItem == nil
            && state.attemptCount >= maxStartAttempts
    }

    private func resolvedOutputConfiguration(
        for identity: AudioAppIdentity,
        state: TapSessionState
    ) -> OutputConfiguration {
        let resolver = CoreAudioRouteResolver(
            availableOutputUIDs: availableOutputUIDs,
            defaultOutputUIDs: storedDefaultOutputDeviceUIDs
        )
        return OutputConfiguration(
            outputUIDs: resolver.resolve(state.route).outputDeviceUIDs
        )
    }

    private func pruneIfEligible(_ identity: AudioAppIdentity) {
        guard let state = statesByIdentity[identity],
              state.target == nil,
              state.session == nil,
              state.ownedControllerCount == 0,
              state.route == .followDefault,
              state.gainState == Self.defaultGainState else { return }
        state.retryWorkItem?.cancel()
        statesByIdentity.removeValue(forKey: identity)
    }

    private func onLifecycleQueue<T>(_ operation: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: lifecycleQueueKey) != nil {
            return try operation()
        }
        return try lifecycleQueue.sync(execute: operation)
    }

    private static func uniqueNonempty(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value in
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !value.isEmpty && seen.insert(value).inserted ? value : nil
        }
    }

    private static func coalescedTargets(_ targets: [CoreAudioTapTarget]) -> [CoreAudioTapTarget] {
        var order: [AudioAppIdentity] = []
        var values: [AudioAppIdentity: CoreAudioTapTarget] = [:]
        for target in targets {
            if var existing = values[target.identity] {
                var seen = Set(existing.processObjectIDs)
                existing.processObjectIDs.append(contentsOf: target.processObjectIDs.filter { seen.insert($0).inserted })
                if existing.displayName.isEmpty { existing.displayName = target.displayName }
                values[target.identity] = existing
            } else {
                order.append(target.identity)
                values[target.identity] = target
            }
        }
        return order.compactMap { values[$0] }
    }
}

extension CoreAudioProcessTapManager: CoreAudioRealtimeTapControlling {
    func setVolume(_ volume: Double, for identity: AudioAppIdentity) {
        onLifecycleQueue {
            var state = statesByIdentity[identity] ?? TapSessionState()
            state.gainState.volume = Float(AppCustomization.clampedVolume(
                volume,
                fallback: Double(state.gainState.volume)
            ))
            statesByIdentity[identity] = state
            state.controller?.updateGainState(state.gainState)
            pruneIfEligible(identity)
        }
    }

    func setMuted(_ muted: Bool, for identity: AudioAppIdentity) {
        onLifecycleQueue {
            var state = statesByIdentity[identity] ?? TapSessionState()
            state.gainState.isMuted = muted
            statesByIdentity[identity] = state
            state.controller?.updateGainState(state.gainState)
            pruneIfEligible(identity)
        }
    }

    func setBoost(_ boost: BoostLevel, for identity: AudioAppIdentity) {
        onLifecycleQueue {
            var state = statesByIdentity[identity] ?? TapSessionState()
            state.gainState.boost = boost
            statesByIdentity[identity] = state
            state.controller?.updateGainState(state.gainState)
            pruneIfEligible(identity)
        }
    }

    func setEQ(_ eq: EQCurve, for identity: AudioAppIdentity) {
        onLifecycleQueue {
            var state = statesByIdentity[identity] ?? TapSessionState()
            state.gainState.eq = eq
            statesByIdentity[identity] = state
            state.controller?.updateGainState(state.gainState)
            pruneIfEligible(identity)
        }
    }
}
