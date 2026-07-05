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

final class CoreAudioProcessTapManager: CoreAudioTapManaging {
    var defaultOutputDeviceUID: String?

    private let operations: CoreAudioTapOperating
    private let controllerFactory: (CoreAudioTapTarget, String, CoreAudioRealtimeGainState) throws -> CoreAudioTapIOController
    private var sessionsByIdentity: [AudioAppIdentity: CoreAudioTapSession] = [:]
    private var controllersByIdentity: [AudioAppIdentity: CoreAudioTapIOController] = [:]
    private var gainStatesByIdentity: [AudioAppIdentity: CoreAudioRealtimeGainState] = [:]

    init(
        operations: CoreAudioTapOperating = SystemCoreAudioTapOperations(),
        controllerFactory: @escaping (CoreAudioTapTarget, String, CoreAudioRealtimeGainState) throws -> CoreAudioTapIOController = {
            CoreAudioTapIOController(target: $0, outputDeviceUID: $1, initialGainState: $2)
        }
    ) {
        self.operations = operations
        self.controllerFactory = controllerFactory
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

        for target in targets where sessionsByIdentity[target.identity]?.processObjectIDs != target.processObjectIDs {
            if sessionsByIdentity[target.identity] != nil {
                try tearDown(identity: target.identity)
            }
            let session = try createSession(for: target)
            sessionsByIdentity[target.identity] = session
        }
    }

    func tearDown(identity: AudioAppIdentity) throws {
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

    func gainState(for identity: AudioAppIdentity) -> CoreAudioRealtimeGainState? {
        gainStatesByIdentity[identity]
    }

    private func createSession(for target: CoreAudioTapTarget) throws -> CoreAudioTapSession {
        guard let outputDeviceUID = defaultOutputDeviceUID else {
            return try operations.createTap(for: target)
        }

        let gainState = gainStatesByIdentity[target.identity] ?? CoreAudioRealtimeGainState(volume: 1, boost: .x1, isMuted: false)
        let controller = try controllerFactory(target, outputDeviceUID, gainState)
        let session = try controller.start()
        controllersByIdentity[target.identity] = controller
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
}
