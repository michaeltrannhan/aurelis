import Foundation

enum ControlTarget: Hashable, Sendable {
    case app(AudioAppIdentity)
    case outputDevice(String)
    case activeApps
}

enum ControlMutation: Hashable, Sendable {
    case adjustVolume(Double)
    case setVolume(Double)
    case toggleMute
    case setMuted(Bool)
    case setBoost(BoostLevel)
    case setEQ(EQCurve)
    case setEQBand(band: Int, gain: Double)
    case setRoute(DeviceRoute)
}

enum ControlSource: Hashable, Sendable {
    case ui
    case mediaKey
    case hotkey
    case widget(commandID: UUID, sequence: UInt64?)
}

struct ControlProjectedState: Equatable, Sendable {
    var volume: Double?
    var isMuted: Bool?
    var boost: BoostLevel?
    var eq: EQCurve?
    var route: DeviceRoute?
    var displayName: String?
}

struct ControlReceipt: Equatable, Sendable {
    let id: UUID
    let accepted: Bool
    let target: ControlTarget
    let mutation: ControlMutation
    let source: ControlSource
    let projected: ControlProjectedState?
    let failure: UserFacingFailure?

    static func accepted(
        id: UUID = UUID(),
        target: ControlTarget,
        mutation: ControlMutation,
        source: ControlSource,
        projected: ControlProjectedState
    ) -> ControlReceipt {
        ControlReceipt(
            id: id,
            accepted: true,
            target: target,
            mutation: mutation,
            source: source,
            projected: projected,
            failure: nil
        )
    }

    static func rejected(
        id: UUID = UUID(),
        target: ControlTarget,
        mutation: ControlMutation,
        source: ControlSource,
        failure: UserFacingFailure
    ) -> ControlReceipt {
        ControlReceipt(
            id: id,
            accepted: false,
            target: target,
            mutation: mutation,
            source: source,
            projected: nil,
            failure: failure
        )
    }
}

enum ControlResult: Equatable, Sendable {
    case applied(ControlProjectedState)
    case rejected(UserFacingFailure)
    case timedOut
    case cancelled
}

enum ControlActionState: Equatable, Sendable {
    case idle
    case pending(projected: ControlProjectedState)
    case applied(actual: ControlProjectedState)
    case failed(previous: ControlProjectedState?, failure: UserFacingFailure)
}

@MainActor
protocol AudioControlCommanding: AnyObject {
    func submit(_ command: ControlCommand) -> ControlReceipt
    func result(for receiptID: UUID) async -> ControlResult
}

struct ControlCommand: Equatable, Hashable, Sendable {
    let target: ControlTarget
    let mutation: ControlMutation
    let source: ControlSource

    init(target: ControlTarget, mutation: ControlMutation, source: ControlSource = .ui) {
        self.target = target
        self.mutation = mutation
        self.source = source
    }
}
