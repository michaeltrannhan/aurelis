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
    func setAvailableOutputUIDs(_ outputUIDs: [String], defaultOutputUID: String?)
    func setRoute(_ identity: AudioAppIdentity, _ route: DeviceRoute)
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
    case destroyFailed(tapObjectID: AudioObjectID, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return "CoreAudio process taps require macOS 14.2 or newer"
        case let .createFailed(identity, status):
            return "Failed to create process tap for \(identity.rawValue): \(status)"
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
    var defaultOutputDeviceUID: String?

    private let operations: CoreAudioTapOperating
    private let controllerFactory: (CoreAudioTapTarget, String, CoreAudioRealtimeGainState) throws -> CoreAudioActiveTapControlling
    private var sessionsByIdentity: [AudioAppIdentity: CoreAudioTapSession] = [:]
    private var controllersByIdentity: [AudioAppIdentity: CoreAudioActiveTapControlling] = [:]
    private var gainStatesByIdentity: [AudioAppIdentity: CoreAudioRealtimeGainState] = [:]
    private var targetsByIdentity: [AudioAppIdentity: CoreAudioTapTarget] = [:]
    private var routesByIdentity: [AudioAppIdentity: DeviceRoute] = [:]
    private var resolvedOutputUIDByIdentity: [AudioAppIdentity: String] = [:]
    private var availableOutputUIDs: [String] = []
    private let maxStartAttempts: Int
    private var attemptsByIdentity: [AudioAppIdentity: Int] = [:]
    private var failuresByIdentity: [AudioAppIdentity: CoreAudioTapFailureDecision] = [:]

    init(
        operations: CoreAudioTapOperating = SystemCoreAudioTapOperations(),
        maxStartAttempts: Int = 3,
        controllerFactory: @escaping (CoreAudioTapTarget, String, CoreAudioRealtimeGainState) throws -> CoreAudioActiveTapControlling = {
            CoreAudioTapIOController(target: $0, outputDeviceUID: $1, initialGainState: $2)
        }
    ) {
        self.operations = operations
        self.maxStartAttempts = max(maxStartAttempts, 1)
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
                failuresByIdentity.removeValue(forKey: target.identity)
            } catch {
                attemptsByIdentity[target.identity, default: 0] += 1
                failuresByIdentity[target.identity] = classifyFailure(error)
            }
        }
    }

    func tearDown(identity: AudioAppIdentity) throws {
        resolvedOutputUIDByIdentity.removeValue(forKey: identity)
        targetsByIdentity.removeValue(forKey: identity)
        attemptsByIdentity.removeValue(forKey: identity)
        failuresByIdentity.removeValue(forKey: identity)
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
        resolvedOutputUIDByIdentity.removeAll()
        attemptsByIdentity.removeAll()
        failuresByIdentity.removeAll()
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
    /// rebuilds only the controllers whose resolved output UID changed (e.g. a
    /// followed default flipped, or a selected device disappeared).
    func setAvailableOutputUIDs(_ outputUIDs: [String], defaultOutputUID: String?) {
        availableOutputUIDs = outputUIDs
        defaultOutputDeviceUID = defaultOutputUID
        for identity in Array(sessionsByIdentity.keys) {
            rebuildControllerIfResolvedRouteChanged(identity)
        }
    }

    /// Sets the per-app route and rebuilds that one controller if its resolved
    /// output UID changed. Rebuild happens outside the realtime callback.
    func setRoute(_ identity: AudioAppIdentity, _ route: DeviceRoute) {
        routesByIdentity[identity] = route
        rebuildControllerIfResolvedRouteChanged(identity)
    }

    func resolvedOutputUID(for identity: AudioAppIdentity) -> String? {
        let resolver = CoreAudioRouteResolver(
            availableOutputUIDs: availableOutputUIDs,
            defaultOutputUID: defaultOutputDeviceUID
        )
        return resolver.resolve(routesByIdentity[identity] ?? .followDefault).outputDeviceUID
    }

    private func rebuildControllerIfResolvedRouteChanged(_ identity: AudioAppIdentity) {
        guard let target = targetsByIdentity[identity],
              controllersByIdentity[identity] != nil else { return }
        let newUID = resolvedOutputUID(for: identity)
        guard newUID != resolvedOutputUIDByIdentity[identity] else { return }
        guard let newUID else { return }

        // Deterministic switch: build+start the new controller, then stop the old.
        let gainState = gainStatesByIdentity[identity] ?? CoreAudioRealtimeGainState(volume: 1, boost: .x1, isMuted: false)
        guard let controller = try? controllerFactory(target, newUID, gainState),
              let session = try? controller.start() else {
            return
        }
        let old = controllersByIdentity[identity]
        controllersByIdentity[identity] = controller
        sessionsByIdentity[identity] = session
        resolvedOutputUIDByIdentity[identity] = newUID
        old?.stop()
    }

    private func createSession(for target: CoreAudioTapTarget) throws -> CoreAudioTapSession {
        targetsByIdentity[target.identity] = target
        let resolvedUID = resolvedOutputUID(for: target.identity) ?? defaultOutputDeviceUID
        guard let outputDeviceUID = resolvedUID else {
            return try operations.createTap(for: target)
        }

        let gainState = gainStatesByIdentity[target.identity] ?? CoreAudioRealtimeGainState(volume: 1, boost: .x1, isMuted: false)
        let controller = try controllerFactory(target, outputDeviceUID, gainState)
        let session = try controller.start()
        controllersByIdentity[target.identity] = controller
        resolvedOutputUIDByIdentity[target.identity] = outputDeviceUID
        return session
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
