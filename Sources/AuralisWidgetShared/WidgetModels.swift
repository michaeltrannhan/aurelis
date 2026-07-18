import Foundation

public enum WidgetHostState: String, Codable, Equatable, Sendable {
    case running
    case stopped
    case configurationError
}

/// Compact mixer state shared across the host app, widget extension, and tests.
/// Only fields rendered by the widget or needed to construct an absolute command
/// are included in the wire model.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public static let hostLeaseDuration: TimeInterval = 15

    public private(set) var generatedAt: Date
    public private(set) var hostState: WidgetHostState
    public private(set) var hostUpdatedAt: Date
    public private(set) var statusMessage: String
    public private(set) var activeAppCount: Int
    public private(set) var volumeStep: Double
    public private(set) var devices: [DeviceSummary]
    public private(set) var apps: [AppSummary]

    public init(
        generatedAt: Date,
        hostState: WidgetHostState,
        hostUpdatedAt: Date,
        statusMessage: String,
        activeAppCount: Int,
        volumeStep: Double,
        devices: [DeviceSummary],
        apps: [AppSummary]
    ) {
        self.generatedAt = Self.finiteDate(generatedAt)
        self.hostState = hostState
        self.hostUpdatedAt = Self.finiteDate(hostUpdatedAt)
        self.statusMessage = statusMessage
        self.activeAppCount = max(activeAppCount, 0)
        self.volumeStep = volumeStep.isFinite && volumeStep > 0 ? min(volumeStep, 1) : 0.05
        self.devices = devices
        self.apps = apps
    }

    private enum CodingKeys: String, CodingKey {
        case generatedAt
        case hostState
        case hostUpdatedAt
        case statusMessage
        case activeAppCount
        case volumeStep
        case devices
        case apps
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            generatedAt: container.widgetTolerant(Date.self, forKey: .generatedAt) ?? .distantPast,
            hostState: container.widgetTolerant(WidgetHostState.self, forKey: .hostState) ?? .stopped,
            hostUpdatedAt: container.widgetTolerant(Date.self, forKey: .hostUpdatedAt) ?? .distantPast,
            statusMessage: container.widgetTolerant(String.self, forKey: .statusMessage) ?? "Open Auralis to use widget controls.",
            activeAppCount: container.widgetTolerant(Int.self, forKey: .activeAppCount) ?? 0,
            volumeStep: container.widgetTolerantDouble(forKey: .volumeStep) ?? 0.05,
            devices: container.widgetTolerant(WidgetTolerantArray<DeviceSummary>.self, forKey: .devices)?.values ?? [],
            apps: container.widgetTolerant(WidgetTolerantArray<AppSummary>.self, forKey: .apps)?.values ?? []
        )
    }

    public func isHostAvailable(
        at date: Date = Date(),
        leaseDuration: TimeInterval = WidgetSnapshot.hostLeaseDuration
    ) -> Bool {
        guard hostState == .running,
              leaseDuration.isFinite,
              leaseDuration > 0 else { return false }
        let age = date.timeIntervalSince(hostUpdatedAt)
        return age.isFinite && age >= -60 && age <= leaseDuration
    }

    public struct DeviceSummary: Codable, Equatable, Identifiable, Sendable {
        public private(set) var id: String
        public private(set) var name: String
        public private(set) var volume: Double
        public private(set) var isMuted: Bool
        public private(set) var isDefault: Bool

        public init(id: String, name: String, volume: Double, isMuted: Bool, isDefault: Bool) {
            self.id = WidgetWireNormalization.identity(id, fallback: "unknown-device")
            self.name = name.isEmpty ? self.id : name
            self.volume = WidgetWireNormalization.unit(volume, fallback: 1)
            self.isMuted = isMuted
            self.isDefault = isDefault
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, volume, isMuted, isDefault
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let id = container.widgetTolerant(String.self, forKey: .id) ?? ""
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Device identity cannot be empty")
                )
            }
            self.init(
                id: id,
                name: container.widgetTolerant(String.self, forKey: .name) ?? id,
                volume: container.widgetTolerantDouble(forKey: .volume) ?? 1,
                isMuted: container.widgetTolerant(Bool.self, forKey: .isMuted) ?? false,
                isDefault: container.widgetTolerant(Bool.self, forKey: .isDefault) ?? false
            )
        }
    }

    public struct AppSummary: Codable, Equatable, Identifiable, Sendable {
        public private(set) var id: String
        public private(set) var displayName: String
        public private(set) var isActive: Bool
        public private(set) var isPinned: Bool
        public private(set) var level: Double
        public private(set) var volume: Double
        public private(set) var isMuted: Bool
        public private(set) var boost: Double
        public private(set) var routeLabel: String
        public private(set) var eqGains: [Double]
        public private(set) var eqRange: Double

        public init(
            id: String,
            displayName: String,
            isActive: Bool,
            isPinned: Bool,
            level: Double,
            volume: Double,
            isMuted: Bool,
            boost: Double,
            routeLabel: String,
            eqGains: [Double],
            eqRange: Double
        ) {
            self.id = WidgetWireNormalization.identity(id, fallback: "unknown-app")
            self.displayName = displayName.isEmpty ? self.id : displayName
            self.isActive = isActive
            self.isPinned = isPinned
            self.level = WidgetWireNormalization.unit(level, fallback: 0)
            self.volume = WidgetWireNormalization.unit(volume, fallback: 1)
            self.isMuted = isMuted
            self.boost = [1.0, 2.0, 3.0, 4.0].contains(boost) ? boost : 1
            self.routeLabel = routeLabel
            self.eqRange = WidgetWireNormalization.gainRange(eqRange)
            self.eqGains = WidgetWireNormalization.gains(eqGains, range: self.eqRange)
        }

        private enum CodingKeys: String, CodingKey {
            case id, displayName, isActive, isPinned, level, volume, isMuted, boost, routeLabel, eqGains, eqRange
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let id = container.widgetTolerant(String.self, forKey: .id) ?? ""
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "App identity cannot be empty")
                )
            }
            self.init(
                id: id,
                displayName: container.widgetTolerant(String.self, forKey: .displayName) ?? id,
                isActive: container.widgetTolerant(Bool.self, forKey: .isActive) ?? false,
                isPinned: container.widgetTolerant(Bool.self, forKey: .isPinned) ?? false,
                level: container.widgetTolerantDouble(forKey: .level) ?? 0,
                volume: container.widgetTolerantDouble(forKey: .volume) ?? 1,
                isMuted: container.widgetTolerant(Bool.self, forKey: .isMuted) ?? false,
                boost: container.widgetTolerantDouble(forKey: .boost) ?? 1,
                routeLabel: container.widgetTolerant(String.self, forKey: .routeLabel) ?? "Follow Default",
                eqGains: container.widgetTolerant(WidgetTolerantDoubleArray.self, forKey: .eqGains)?.values ?? [],
                eqRange: container.widgetTolerantDouble(forKey: .eqRange) ?? 12
            )
        }
    }

    public static let empty = WidgetSnapshot(
        generatedAt: .distantPast,
        hostState: .stopped,
        hostUpdatedAt: .distantPast,
        statusMessage: "Open Auralis to use widget controls.",
        activeAppCount: 0,
        volumeStep: 0.05,
        devices: [],
        apps: []
    )

    public static func configurationError(_ message: String) -> WidgetSnapshot {
        WidgetSnapshot(
            generatedAt: Date(),
            hostState: .configurationError,
            hostUpdatedAt: Date(),
            statusMessage: message,
            activeAppCount: 0,
            volumeStep: 0.05,
            devices: [],
            apps: []
        )
    }

    private static func finiteDate(_ date: Date) -> Date {
        date.timeIntervalSinceReferenceDate.isFinite ? date : .distantPast
    }
}

public enum WidgetCommandTargetType: String, Codable, Equatable, Sendable {
    case app
    case outputDevice
    case host
}

/// Absolute actions make duplicate delivery and replay after a host crash
/// harmless. Relative UI gestures are converted to these values in the widget
/// from the snapshot that rendered the control.
public enum WidgetCommandAction: Codable, Equatable, Sendable {
    case setMuted(Bool)
    case setVolume(Double)
    case setBoost(Double)
    case setEQBandGain(band: Int, gain: Double)
    case refresh

    private enum CodingKeys: String, CodingKey {
        case type, value, band, gain
    }

    private enum Kind: String, Codable {
        case setMuted, setVolume, setBoost, setEQBandGain, refresh
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)
        switch kind {
        case .setMuted:
            self = .setMuted(try container.decode(Bool.self, forKey: .value))
        case .setVolume:
            self = .setVolume(try container.decode(Double.self, forKey: .value))
        case .setBoost:
            self = .setBoost(try container.decode(Double.self, forKey: .value))
        case .setEQBandGain:
            self = .setEQBandGain(
                band: try container.decode(Int.self, forKey: .band),
                gain: try container.decode(Double.self, forKey: .gain)
            )
        case .refresh:
            self = .refresh
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .setMuted(value):
            try container.encode(Kind.setMuted, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .setVolume(value):
            try container.encode(Kind.setVolume, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .setBoost(value):
            try container.encode(Kind.setBoost, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .setEQBandGain(band, gain):
            try container.encode(Kind.setEQBandGain, forKey: .type)
            try container.encode(band, forKey: .band)
            try container.encode(gain, forKey: .gain)
        case .refresh:
            try container.encode(Kind.refresh, forKey: .type)
        }
    }
}

public enum WidgetCommandValidationError: String, Error, Codable, Equatable, LocalizedError, Sendable {
    case unsupportedSchema
    case invalidTimestamp
    case expired
    case invalidTarget
    case invalidIdentity
    case invalidAction
    case invalidValue

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema: "Unsupported widget command schema."
        case .invalidTimestamp: "Widget command timestamps are invalid."
        case .expired: "Widget command expired before it could be applied."
        case .invalidTarget: "Widget command target is invalid."
        case .invalidIdentity: "Widget command target identity is invalid."
        case .invalidAction: "Widget command action is not valid for its target."
        case .invalidValue: "Widget command value is outside the supported range."
        }
    }
}

/// Versioned per-file command envelope used by the widget command directory.
public struct WidgetCommand: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1
    public static let defaultLifetime: TimeInterval = 30
    public static let maximumLifetime: TimeInterval = 120

    public let schemaVersion: Int
    public let id: UUID
    public let createdAt: Date
    public let expiresAt: Date
    public let targetType: WidgetCommandTargetType
    public let targetIdentity: String?
    public let action: WidgetCommandAction

    public init(
        schemaVersion: Int = WidgetCommand.currentSchemaVersion,
        id: UUID = UUID(),
        createdAt: Date = Date(),
        expiresAt: Date? = nil,
        targetType: WidgetCommandTargetType,
        targetIdentity: String?,
        action: WidgetCommandAction
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.createdAt = createdAt
        self.expiresAt = expiresAt ?? createdAt.addingTimeInterval(Self.defaultLifetime)
        self.targetType = targetType
        self.targetIdentity = targetIdentity
        self.action = action
    }

    public static func app(
        id: UUID = UUID(),
        identity: String,
        action: WidgetCommandAction,
        createdAt: Date = Date(),
        lifetime: TimeInterval = WidgetCommand.defaultLifetime
    ) -> WidgetCommand {
        WidgetCommand(
            id: id,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(lifetime),
            targetType: .app,
            targetIdentity: identity,
            action: action
        )
    }

    public static func outputDevice(
        id: UUID = UUID(),
        identity: String,
        muted: Bool,
        createdAt: Date = Date(),
        lifetime: TimeInterval = WidgetCommand.defaultLifetime
    ) -> WidgetCommand {
        WidgetCommand(
            id: id,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(lifetime),
            targetType: .outputDevice,
            targetIdentity: identity,
            action: .setMuted(muted)
        )
    }

    public static func refresh(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        lifetime: TimeInterval = WidgetCommand.defaultLifetime
    ) -> WidgetCommand {
        WidgetCommand(
            id: id,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(lifetime),
            targetType: .host,
            targetIdentity: nil,
            action: .refresh
        )
    }

    public func validate(now: Date = Date()) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw WidgetCommandValidationError.unsupportedSchema
        }
        let created = createdAt.timeIntervalSinceReferenceDate
        let expires = expiresAt.timeIntervalSinceReferenceDate
        let current = now.timeIntervalSinceReferenceDate
        guard created.isFinite,
              expires.isFinite,
              current.isFinite,
              expires > created,
              expires - created <= Self.maximumLifetime,
              created - current <= 60 else {
            throw WidgetCommandValidationError.invalidTimestamp
        }
        guard current <= expires else { throw WidgetCommandValidationError.expired }

        let identity = targetIdentity?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let identity, identity.count > 512 {
            throw WidgetCommandValidationError.invalidIdentity
        }

        switch (targetType, action) {
        case (.host, .refresh):
            guard identity == nil || identity?.isEmpty == true else {
                throw WidgetCommandValidationError.invalidIdentity
            }
        case (.app, .setMuted):
            try Self.requireIdentity(identity)
        case let (.app, .setVolume(value)):
            try Self.requireIdentity(identity)
            guard value.isFinite, (0...1).contains(value) else {
                throw WidgetCommandValidationError.invalidValue
            }
        case let (.app, .setBoost(value)):
            try Self.requireIdentity(identity)
            guard value.isFinite, [1.0, 2.0, 3.0, 4.0].contains(value) else {
                throw WidgetCommandValidationError.invalidValue
            }
        case let (.app, .setEQBandGain(band, gain)):
            try Self.requireIdentity(identity)
            guard (0..<WidgetWireNormalization.bandCount).contains(band),
                  gain.isFinite,
                  (-24...24).contains(gain) else {
                throw WidgetCommandValidationError.invalidValue
            }
        case (.outputDevice, .setMuted):
            try Self.requireIdentity(identity)
        default:
            throw WidgetCommandValidationError.invalidAction
        }
    }

    private static func requireIdentity(_ identity: String?) throws {
        guard let identity, !identity.isEmpty else {
            throw WidgetCommandValidationError.invalidIdentity
        }
    }
}

public enum WidgetCommandResultStatus: String, Codable, Equatable, Sendable {
    case applied
    case rejected
    case failed
}

/// Durable acknowledgment written before a claimed command is deleted.
public struct WidgetCommandResult: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let commandID: UUID
    public let completedAt: Date
    public let status: WidgetCommandResultStatus
    public let message: String
    public let snapshotGeneratedAt: Date?

    public var id: UUID { commandID }

    public init(
        schemaVersion: Int = WidgetCommandResult.currentSchemaVersion,
        commandID: UUID,
        completedAt: Date = Date(),
        status: WidgetCommandResultStatus,
        message: String,
        snapshotGeneratedAt: Date?
    ) {
        self.schemaVersion = schemaVersion
        self.commandID = commandID
        self.completedAt = completedAt
        self.status = status
        self.message = message
        self.snapshotGeneratedAt = snapshotGeneratedAt
    }
}

/// Timeline scheduling is based on actual IPC state. One-second polling is
/// reserved for a command file that is still pending or claimed.
public enum WidgetTimelineRefreshPolicy {
    public static let pendingInterval: TimeInterval = 1
    public static let normalInterval: TimeInterval = 60

    public static func nextRefresh(
        now: Date,
        snapshot: WidgetSnapshot,
        hasPendingCommand: Bool
    ) -> Date {
        if hasPendingCommand {
            return now.addingTimeInterval(pendingInterval)
        }
        if snapshot.hostState == .running {
            let leaseRefresh = snapshot.hostUpdatedAt.addingTimeInterval(WidgetSnapshot.hostLeaseDuration)
            if leaseRefresh > now {
                return min(now.addingTimeInterval(normalInterval), leaseRefresh)
            }
        }
        return now.addingTimeInterval(normalInterval)
    }
}
