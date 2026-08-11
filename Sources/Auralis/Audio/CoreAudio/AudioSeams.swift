import Foundation

/// Typed per-app tap status from synchronization — never silently report ready
/// after startup failure or retry exhaustion.
enum AudioTapStatus: Equatable, Sendable {
    case ready
    case starting
    case retrying(attempt: Int)
    case startupFailed(UserFacingFailure)
    case retryExhausted(UserFacingFailure)
    case unavailable(UserFacingFailure)

    var isReady: Bool {
        if case .ready = self { true } else { false }
    }
}

struct TapReconcileReport: Equatable, Sendable {
    var statuses: [AudioAppIdentity: AudioTapStatus]
    var created: [AudioAppIdentity]
    var removed: [AudioAppIdentity]
    var failed: [AudioAppIdentity]

    init(
        statuses: [AudioAppIdentity: AudioTapStatus] = [:],
        created: [AudioAppIdentity] = [],
        removed: [AudioAppIdentity] = [],
        failed: [AudioAppIdentity] = []
    ) {
        self.statuses = statuses
        self.created = created
        self.removed = removed
        self.failed = failed
    }

    var allReady: Bool {
        !statuses.isEmpty && statuses.values.allSatisfy(\.isReady)
    }
}

/// Aggregate or Multi-Output default modeled with its own UID and physical members.
struct SystemOutputRoute: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable {
        case physical
        case aggregate
        case multiOutput
    }

    var id: String { uid }
    var uid: String
    var name: String
    var kind: Kind
    var isDefault: Bool
    var physicalMemberUIDs: [String]
    /// First member is the clock source for multi-output aggregates.
    var clockSourceUID: String?

    init(
        uid: String,
        name: String,
        kind: Kind,
        isDefault: Bool,
        physicalMemberUIDs: [String] = [],
        clockSourceUID: String? = nil
    ) {
        self.uid = uid
        self.name = name
        self.kind = kind
        self.isDefault = isDefault
        self.physicalMemberUIDs = physicalMemberUIDs
        self.clockSourceUID = clockSourceUID ?? physicalMemberUIDs.first
    }
}

/// Output value that can be marked stale/unavailable instead of fabricating 100%/unmuted.
struct OutputValue<Value: Equatable & Sendable>: Equatable, Sendable {
    enum Availability: Equatable, Sendable {
        case available
        case stale
        case unavailable
    }

    var value: Value?
    var availability: Availability
    var lastKnown: Value?

    static func available(_ value: Value) -> OutputValue<Value> {
        OutputValue(value: value, availability: .available, lastKnown: value)
    }

    static func stale(_ lastKnown: Value) -> OutputValue<Value> {
        OutputValue(value: lastKnown, availability: .stale, lastKnown: lastKnown)
    }

    static func unavailable(lastKnown: Value? = nil) -> OutputValue<Value> {
        OutputValue(value: nil, availability: .unavailable, lastKnown: lastKnown)
    }

    var displayValue: Value? { value ?? lastKnown }
}

/// Lightweight topology revision for settle polling without meter/listener side effects.
struct TopologyRevision: Equatable, Sendable, Hashable {
    var defaultOutputUID: String?
    var availableOutputUIDs: Set<String>
    var generation: UInt64

    init(defaultOutputUID: String?, availableOutputUIDs: Set<String>, generation: UInt64 = 0) {
        self.defaultOutputUID = defaultOutputUID
        self.availableOutputUIDs = availableOutputUIDs
        self.generation = generation
    }
}
