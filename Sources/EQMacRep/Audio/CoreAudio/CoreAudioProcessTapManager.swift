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

/// Route control seam the backend uses to feed the available device list and
/// per-app route selection into the tap manager.
protocol CoreAudioRouteControlling: AnyObject {
    func setAvailableOutputUIDs(
        _ outputUIDs: [String],
        defaultOutputUIDs: [String],
        nominalSampleRatesByUID: [String: Double]
    )
    func setRoute(_ identity: AudioAppIdentity, _ route: DeviceRoute) throws
}

/// Health-reporting seam so the backend can surface active-tap and issue counts.
protocol CoreAudioTapHealthReporting: AnyObject {
    var health: CoreAudioTapHealth { get }
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

final class CoreAudioProcessTapManager: CoreAudioTapManaging, CoreAudioRouteControlling, CoreAudioTapHealthReporting {
    private struct OutputConfiguration: Equatable {
        var outputUIDs: [String]
        var nominalSampleRatesByUID: [String: Double]
    }

    var defaultOutputDeviceUIDs: [String] = []
    var defaultOutputDeviceUID: String? {
        get { defaultOutputDeviceUIDs.first }
        set { defaultOutputDeviceUIDs = newValue.map { [$0] } ?? [] }
    }

    private let operations: CoreAudioTapOperating
    private let controllerFactory: (CoreAudioTapTarget, [String], CoreAudioRealtimeGainState) throws -> CoreAudioActiveTapControlling
    private var sessionsByIdentity: [AudioAppIdentity: CoreAudioTapSession] = [:]
    private var controllersByIdentity: [AudioAppIdentity: CoreAudioActiveTapControlling] = [:]
    private var gainStatesByIdentity: [AudioAppIdentity: CoreAudioRealtimeGainState] = [:]
    private var targetsByIdentity: [AudioAppIdentity: CoreAudioTapTarget] = [:]
    private var routesByIdentity: [AudioAppIdentity: DeviceRoute] = [:]
    private var outputConfigurationsByIdentity: [AudioAppIdentity: OutputConfiguration] = [:]
    private var availableOutputUIDs: [String] = []
    private var nominalSampleRatesByUID: [String: Double] = [:]
    private let maxStartAttempts: Int
    private var attemptsByIdentity: [AudioAppIdentity: Int] = [:]
    private var failuresByIdentity: [AudioAppIdentity: CoreAudioTapFailureDecision] = [:]
    private var failedAutomaticConfigurationsByIdentity: [AudioAppIdentity: OutputConfiguration] = [:]
    private var automaticRetryAfterByIdentity: [AudioAppIdentity: Date] = [:]
    private var automaticRetryCountsByIdentity: [AudioAppIdentity: Int] = [:]
    private var automaticRetryWorkItemsByIdentity: [AudioAppIdentity: DispatchWorkItem] = [:]
    private let automaticRetryCooldown: TimeInterval
    private let now: () -> Date

    init(
        operations: CoreAudioTapOperating = SystemCoreAudioTapOperations(),
        maxStartAttempts: Int = 3,
        automaticRetryCooldown: TimeInterval = 1,
        now: @escaping () -> Date = Date.init,
        controllerFactory: @escaping (CoreAudioTapTarget, [String], CoreAudioRealtimeGainState) throws -> CoreAudioActiveTapControlling = {
            CoreAudioTapIOController(target: $0, outputDeviceUIDs: $1, initialGainState: $2)
        }
    ) {
        self.operations = operations
        self.maxStartAttempts = max(maxStartAttempts, 1)
        self.automaticRetryCooldown = max(automaticRetryCooldown, 0)
        self.now = now
        self.controllerFactory = controllerFactory
    }

    /// Current tap health for status reporting.
    var health: CoreAudioTapHealth {
        CoreAudioTapHealth(
            activeAppCount: controllersByIdentity.count,
            failedAppMessages: failuresByIdentity.mapValues(\.message),
            backendMessage: ""
        )
    }

    var activeSessions: [CoreAudioTapSession] {
        sessionsByIdentity.values.sorted {
            $0.identity.rawValue < $1.identity.rawValue
        }
    }

    func reconcile(targets: [CoreAudioTapTarget]) throws {
        let targetIDs = Set(targets.map(\.identity))
        for identity in Array(sessionsByIdentity.keys) where !targetIDs.contains(identity) {
            try tearDown(identity: identity)
        }
        // Clear failure/attempt state for apps that are no longer targeted so a
        // returning app gets a fresh start rather than staying capped.
        for identity in Array(failuresByIdentity.keys) where !targetIDs.contains(identity) {
            failuresByIdentity.removeValue(forKey: identity)
            attemptsByIdentity.removeValue(forKey: identity)
        }

        for target in targets where sessionsByIdentity[target.identity]?.processObjectIDs != target.processObjectIDs {
            // Respect the retry cap: stop hammering an app that keeps failing.
            if let attempts = attemptsByIdentity[target.identity], attempts >= maxStartAttempts {
                continue
            }
            if sessionsByIdentity[target.identity] != nil {
                try tearDown(identity: target.identity)
            }
            do {
                let session = try createSession(for: target)
                sessionsByIdentity[target.identity] = session
                attemptsByIdentity[target.identity] = 0
                updateRouteAvailabilityHealth(for: target.identity)
            } catch {
                attemptsByIdentity[target.identity, default: 0] += 1
                failuresByIdentity[target.identity] = classifyFailure(error)
            }
        }
    }

    func tearDown(identity: AudioAppIdentity) throws {
        outputConfigurationsByIdentity.removeValue(forKey: identity)
        targetsByIdentity.removeValue(forKey: identity)
        attemptsByIdentity.removeValue(forKey: identity)
        failuresByIdentity.removeValue(forKey: identity)
        failedAutomaticConfigurationsByIdentity.removeValue(forKey: identity)
        automaticRetryAfterByIdentity.removeValue(forKey: identity)
        automaticRetryCountsByIdentity.removeValue(forKey: identity)
        automaticRetryWorkItemsByIdentity.removeValue(forKey: identity)?.cancel()
        guard let session = sessionsByIdentity.removeValue(forKey: identity) else { return }
        if let controller = controllersByIdentity.removeValue(forKey: identity) {
            controller.stop()
        } else {
            try operations.destroyTap(session.tapObjectID)
        }
    }

    func tearDownAll() throws {
        for identity in Array(sessionsByIdentity.keys) {
            try tearDown(identity: identity)
        }
    }

    /// Forced stop of all active controllers, ignoring throw ordering. Used as a
    /// deterministic last-resort teardown on shutdown.
    func stopAll() {
        for controller in controllersByIdentity.values {
            controller.stop()
        }
        controllersByIdentity.removeAll()
        sessionsByIdentity.removeAll()
        outputConfigurationsByIdentity.removeAll()
        attemptsByIdentity.removeAll()
        failuresByIdentity.removeAll()
        failedAutomaticConfigurationsByIdentity.removeAll()
        automaticRetryAfterByIdentity.removeAll()
        automaticRetryCountsByIdentity.removeAll()
        for workItem in automaticRetryWorkItemsByIdentity.values { workItem.cancel() }
        automaticRetryWorkItemsByIdentity.removeAll()
        targetsByIdentity.removeAll()
    }

    private func classifyFailure(_ error: Error) -> CoreAudioTapFailureDecision {
        if let failure = error as? CoreAudioTapStartFailure {
            return CoreAudioTapFailurePolicy.classify(failure)
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
        return .recoverable(error.localizedDescription)
    }

    func gainState(for identity: AudioAppIdentity) -> CoreAudioRealtimeGainState? {
        gainStatesByIdentity[identity]
    }

    // MARK: Routing

    /// Updates the set of available output devices and the current default, then
    /// rebuilds only controllers whose resolved UID/rate configuration changed
    /// (e.g. a followed default flipped, a device disappeared, or its rate moved).
    func setAvailableOutputUIDs(
        _ outputUIDs: [String],
        defaultOutputUIDs: [String],
        nominalSampleRatesByUID: [String: Double]
    ) {
        let topologyChanged = availableOutputUIDs != outputUIDs
            || defaultOutputDeviceUIDs != defaultOutputUIDs
            || self.nominalSampleRatesByUID != nominalSampleRatesByUID
        availableOutputUIDs = outputUIDs
        defaultOutputDeviceUIDs = defaultOutputUIDs
        self.nominalSampleRatesByUID = nominalSampleRatesByUID
        if topologyChanged {
            for identity in targetsByIdentity.keys where sessionsByIdentity[identity] == nil {
                attemptsByIdentity[identity] = 0
            }
        }
        for identity in Array(sessionsByIdentity.keys) {
            let attemptedConfiguration = resolvedOutputConfiguration(for: identity)
            let isCoolingDown = failedAutomaticConfigurationsByIdentity[identity] == attemptedConfiguration
                && automaticRetryAfterByIdentity[identity, default: .distantPast] > now()
            guard !isCoolingDown else {
                continue
            }
            do {
                if controllersByIdentity[identity] == nil {
                    try replaceTapOnlySessionIfOutputBecameAvailable(identity)
                } else {
                    try rebuildControllerIfResolvedRouteChanged(identity)
                }
                failedAutomaticConfigurationsByIdentity.removeValue(forKey: identity)
                automaticRetryAfterByIdentity.removeValue(forKey: identity)
                automaticRetryCountsByIdentity.removeValue(forKey: identity)
                automaticRetryWorkItemsByIdentity.removeValue(forKey: identity)?.cancel()
                updateRouteAvailabilityHealth(for: identity)
            } catch {
                recordAutomaticFailure(error, configuration: attemptedConfiguration, for: identity)
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

    /// Source-compatible convenience for callers with an ordinary single
    /// system-default output.
    func setAvailableOutputUIDs(_ outputUIDs: [String], defaultOutputUID: String?) {
        setAvailableOutputUIDs(
            outputUIDs,
            defaultOutputUIDs: defaultOutputUID.map { [$0] } ?? [],
            nominalSampleRatesByUID: [:]
        )
    }

    /// Sets the per-app route and rebuilds that one controller if its ordered
    /// output UID list changed. Rebuild happens outside the realtime callback.
    func setRoute(_ identity: AudioAppIdentity, _ route: DeviceRoute) throws {
        let previousRoute = routesByIdentity[identity]
        routesByIdentity[identity] = route.normalized
        // Applying a route is an explicit retry, even when the same automatic
        // topology signature previously failed.
        failedAutomaticConfigurationsByIdentity.removeValue(forKey: identity)
        automaticRetryAfterByIdentity.removeValue(forKey: identity)
        automaticRetryCountsByIdentity.removeValue(forKey: identity)
        automaticRetryWorkItemsByIdentity.removeValue(forKey: identity)?.cancel()
        attemptsByIdentity[identity] = 0
        do {
            if controllersByIdentity[identity] == nil {
                try replaceTapOnlySessionIfOutputBecameAvailable(identity)
            } else {
                try rebuildControllerIfResolvedRouteChanged(identity)
            }
            updateRouteAvailabilityHealth(for: identity)
        } catch {
            routesByIdentity[identity] = previousRoute
            failuresByIdentity[identity] = classifyFailure(error)
            throw error
        }
    }

    func resolvedOutputUIDs(for identity: AudioAppIdentity) -> [String] {
        let resolver = CoreAudioRouteResolver(
            availableOutputUIDs: availableOutputUIDs,
            defaultOutputUIDs: defaultOutputDeviceUIDs
        )
        return resolver.resolve(routesByIdentity[identity] ?? .followDefault).outputDeviceUIDs
    }

    private func resolvedOutputConfiguration(for identity: AudioAppIdentity) -> OutputConfiguration {
        let outputUIDs = resolvedOutputUIDs(for: identity)
        var resolvedRates: [String: Double] = [:]
        for uid in outputUIDs {
            if let sampleRate = nominalSampleRatesByUID[uid] {
                resolvedRates[uid] = sampleRate
            }
        }
        return OutputConfiguration(outputUIDs: outputUIDs, nominalSampleRatesByUID: resolvedRates)
    }

    /// Compatibility helper for consumers that only need the clock/main output.
    func resolvedOutputUID(for identity: AudioAppIdentity) -> String? {
        resolvedOutputUIDs(for: identity).first
    }

    private func rebuildControllerIfResolvedRouteChanged(_ identity: AudioAppIdentity) throws {
        guard let target = targetsByIdentity[identity],
              controllersByIdentity[identity] != nil else { return }
        let newConfiguration = resolvedOutputConfiguration(for: identity)
        let newUIDs = newConfiguration.outputUIDs
        guard newConfiguration != outputConfigurationsByIdentity[identity] else { return }
        guard !newUIDs.isEmpty else { throw CoreAudioTapStartFailure.deviceUnavailable }

        // Deterministic switch: build+start the new controller, then stop the old.
        let gainState = gainStatesByIdentity[identity] ?? CoreAudioRealtimeGainState(volume: 1, boost: .x1, isMuted: false)
        let controller = try controllerFactory(target, newUIDs, gainState)
        let session = try controller.start()
        let old = controllersByIdentity[identity]
        controllersByIdentity[identity] = controller
        sessionsByIdentity[identity] = session
        outputConfigurationsByIdentity[identity] = newConfiguration
        old?.stop()
    }

    /// A target can initially have only an unmuted process tap when no route is
    /// available. Promote that placeholder to a full controller as soon as an
    /// output appears; otherwise the controller-only rebuild guard would leave it
    /// permanently unrouted.
    private func replaceTapOnlySessionIfOutputBecameAvailable(_ identity: AudioAppIdentity) throws {
        guard controllersByIdentity[identity] == nil,
              let target = targetsByIdentity[identity],
              let oldSession = sessionsByIdentity[identity] else { return }
        let outputDeviceUIDs = resolvedOutputUIDs(for: identity)
        guard !outputDeviceUIDs.isEmpty else { return }

        // Start the routed controller before removing the placeholder, so a
        // failed promotion leaves the existing unmuted tap intact and retryable.
        let gainState = gainStatesByIdentity[identity] ?? CoreAudioRealtimeGainState(volume: 1, boost: .x1, isMuted: false)
        let controller = try controllerFactory(target, outputDeviceUIDs, gainState)
        let session = try controller.start()
        do {
            try operations.destroyTap(oldSession.tapObjectID)
        } catch {
            controller.stop()
            throw error
        }

        controllersByIdentity[identity] = controller
        sessionsByIdentity[identity] = session
        outputConfigurationsByIdentity[identity] = resolvedOutputConfiguration(for: identity)
        attemptsByIdentity[identity] = 0
    }

    private func createSession(for target: CoreAudioTapTarget) throws -> CoreAudioTapSession {
        targetsByIdentity[target.identity] = target
        let outputDeviceUIDs = resolvedOutputUIDs(for: target.identity)
        guard !outputDeviceUIDs.isEmpty else {
            return try operations.createTap(for: target)
        }

        let gainState = gainStatesByIdentity[target.identity] ?? CoreAudioRealtimeGainState(volume: 1, boost: .x1, isMuted: false)
        let controller = try controllerFactory(target, outputDeviceUIDs, gainState)
        let session = try controller.start()
        controllersByIdentity[target.identity] = controller
        outputConfigurationsByIdentity[target.identity] = resolvedOutputConfiguration(for: target.identity)
        return session
    }

    private func updateRouteAvailabilityHealth(for identity: AudioAppIdentity) {
        if sessionsByIdentity[identity] != nil, controllersByIdentity[identity] == nil {
            failuresByIdentity[identity] = CoreAudioTapFailurePolicy.classify(.deviceUnavailable)
        } else {
            failuresByIdentity.removeValue(forKey: identity)
        }
    }

    private func recordAutomaticFailure(
        _ error: Error,
        configuration: OutputConfiguration,
        for identity: AudioAppIdentity
    ) {
        if failedAutomaticConfigurationsByIdentity[identity] != configuration {
            automaticRetryCountsByIdentity[identity] = 0
        }
        failedAutomaticConfigurationsByIdentity[identity] = configuration
        let attempt = automaticRetryCountsByIdentity[identity, default: 0] + 1
        automaticRetryCountsByIdentity[identity] = attempt
        failuresByIdentity[identity] = classifyFailure(error)

        automaticRetryWorkItemsByIdentity.removeValue(forKey: identity)?.cancel()
        guard attempt < maxStartAttempts else {
            // Keep this exact failed configuration suppressed after the cap.
            // A topology/rate change bypasses the signature and explicit route
            // application clears it immediately.
            automaticRetryAfterByIdentity[identity] = .distantFuture
            return
        }

        let delay = automaticRetryCooldown * pow(2, Double(attempt - 1))
        automaticRetryAfterByIdentity[identity] = now().addingTimeInterval(delay)
        let workItem = DispatchWorkItem { [weak self] in
            self?.performAutomaticRetry(for: identity, expectedConfiguration: configuration)
        }
        automaticRetryWorkItemsByIdentity[identity] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func performAutomaticRetry(
        for identity: AudioAppIdentity,
        expectedConfiguration: OutputConfiguration
    ) {
        automaticRetryWorkItemsByIdentity.removeValue(forKey: identity)
        guard sessionsByIdentity[identity] != nil,
              failedAutomaticConfigurationsByIdentity[identity] == expectedConfiguration,
              resolvedOutputConfiguration(for: identity) == expectedConfiguration else { return }

        do {
            if controllersByIdentity[identity] == nil {
                try replaceTapOnlySessionIfOutputBecameAvailable(identity)
            } else {
                try rebuildControllerIfResolvedRouteChanged(identity)
            }
            failedAutomaticConfigurationsByIdentity.removeValue(forKey: identity)
            automaticRetryAfterByIdentity.removeValue(forKey: identity)
            automaticRetryCountsByIdentity.removeValue(forKey: identity)
            updateRouteAvailabilityHealth(for: identity)
        } catch {
            recordAutomaticFailure(error, configuration: expectedConfiguration, for: identity)
        }
    }
}

extension CoreAudioProcessTapManager: CoreAudioRealtimeTapControlling {
    func setVolume(_ volume: Double, for identity: AudioAppIdentity) {
        var state = gainStatesByIdentity[identity] ?? CoreAudioRealtimeGainState(volume: 1, boost: .x1, isMuted: false)
        state.volume = Float(AppCustomization.clampedVolume(volume, fallback: Double(state.volume)))
        gainStatesByIdentity[identity] = state
        controllersByIdentity[identity]?.updateGainState(state)
    }

    func setMuted(_ muted: Bool, for identity: AudioAppIdentity) {
        var state = gainStatesByIdentity[identity] ?? CoreAudioRealtimeGainState(volume: 1, boost: .x1, isMuted: false)
        state.isMuted = muted
        gainStatesByIdentity[identity] = state
        controllersByIdentity[identity]?.updateGainState(state)
    }

    func setBoost(_ boost: BoostLevel, for identity: AudioAppIdentity) {
        var state = gainStatesByIdentity[identity] ?? CoreAudioRealtimeGainState(volume: 1, boost: .x1, isMuted: false)
        state.boost = boost
        gainStatesByIdentity[identity] = state
        controllersByIdentity[identity]?.updateGainState(state)
    }

    func setEQ(_ eq: EQCurve, for identity: AudioAppIdentity) {
        var state = gainStatesByIdentity[identity] ?? CoreAudioRealtimeGainState(volume: 1, boost: .x1, isMuted: false)
        state.eq = eq
        gainStatesByIdentity[identity] = state
        controllersByIdentity[identity]?.updateGainState(state)
    }
}
