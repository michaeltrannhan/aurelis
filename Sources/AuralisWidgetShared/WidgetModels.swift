import Foundation

public enum WidgetHostState: String, Codable, Equatable, Sendable {
    case running
    case stopped
    case configurationError
}

/// Compact mixer state shared across the host app, widget extension, and tests.
/// Only fields rendered by the widget or needed to construct a validated command
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
    public private(set) var profiles: [ProfileSummary]
    public private(set) var activeGlobalProfileID: String?
    public private(set) var activeLocalProfileID: String?
    /// Compatibility mirror containing the most-specific active profile.
    public private(set) var activeProfileID: String?
    public private(set) var profileHasOverrides: Bool

    public init(
        generatedAt: Date,
        hostState: WidgetHostState,
        hostUpdatedAt: Date,
        statusMessage: String,
        activeAppCount: Int,
        volumeStep: Double,
        devices: [DeviceSummary],
        apps: [AppSummary],
        profiles: [ProfileSummary] = [],
        activeGlobalProfileID: String? = nil,
        activeLocalProfileID: String? = nil,
        activeProfileID: String? = nil,
        profileHasOverrides: Bool = false
    ) {
        self.generatedAt = Self.finiteDate(generatedAt)
        self.hostState = hostState
        self.hostUpdatedAt = Self.finiteDate(hostUpdatedAt)
        self.statusMessage = statusMessage
        self.activeAppCount = max(activeAppCount, 0)
        self.volumeStep = volumeStep.isFinite && volumeStep > 0 ? min(volumeStep, 1) : 0.05
        self.devices = devices
        self.apps = apps
        self.profiles = profiles
        let legacyID = activeProfileID.flatMap(WidgetWireNormalization.optionalIdentity)
        let globalID = activeGlobalProfileID.flatMap(WidgetWireNormalization.optionalIdentity)
        let localID = activeLocalProfileID.flatMap(WidgetWireNormalization.optionalIdentity)
        self.activeGlobalProfileID = globalID ?? (localID == nil ? legacyID : nil)
        self.activeLocalProfileID = localID
        self.activeProfileID = localID ?? globalID ?? legacyID
        self.profileHasOverrides = profileHasOverrides && self.activeProfileID != nil
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
        case profiles
        case activeGlobalProfileID
        case activeLocalProfileID
        case activeProfileID
        case profileHasOverrides
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            generatedAt: container.tolerant(Date.self, forKey: .generatedAt) ?? .distantPast,
            hostState: container.tolerant(WidgetHostState.self, forKey: .hostState) ?? .stopped,
            hostUpdatedAt: container.tolerant(Date.self, forKey: .hostUpdatedAt) ?? .distantPast,
            statusMessage: container.tolerant(String.self, forKey: .statusMessage) ?? "Open Auralis to use widget controls.",
            activeAppCount: container.tolerant(Int.self, forKey: .activeAppCount) ?? 0,
            volumeStep: container.tolerantDouble(forKey: .volumeStep) ?? 0.05,
            devices: container.tolerant(TolerantArray<DeviceSummary>.self, forKey: .devices)?.values ?? [],
            apps: container.tolerant(TolerantArray<AppSummary>.self, forKey: .apps)?.values ?? [],
            profiles: container.tolerant(TolerantArray<ProfileSummary>.self, forKey: .profiles)?.values ?? [],
            activeGlobalProfileID: container.tolerant(String.self, forKey: .activeGlobalProfileID),
            activeLocalProfileID: container.tolerant(String.self, forKey: .activeLocalProfileID),
            activeProfileID: container.tolerant(String.self, forKey: .activeProfileID),
            profileHasOverrides: container.tolerant(Bool.self, forKey: .profileHasOverrides) ?? false
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
            let id = container.tolerant(String.self, forKey: .id) ?? ""
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Device identity cannot be empty")
                )
            }
            self.init(
                id: id,
                name: container.tolerant(String.self, forKey: .name) ?? id,
                volume: container.tolerantDouble(forKey: .volume) ?? 1,
                isMuted: container.tolerant(Bool.self, forKey: .isMuted) ?? false,
                isDefault: container.tolerant(Bool.self, forKey: .isDefault) ?? false
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
            let id = container.tolerant(String.self, forKey: .id) ?? ""
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "App identity cannot be empty")
                )
            }
            self.init(
                id: id,
                displayName: container.tolerant(String.self, forKey: .displayName) ?? id,
                isActive: container.tolerant(Bool.self, forKey: .isActive) ?? false,
                isPinned: container.tolerant(Bool.self, forKey: .isPinned) ?? false,
                level: container.tolerantDouble(forKey: .level) ?? 0,
                volume: container.tolerantDouble(forKey: .volume) ?? 1,
                isMuted: container.tolerant(Bool.self, forKey: .isMuted) ?? false,
                boost: container.tolerantDouble(forKey: .boost) ?? 1,
                routeLabel: container.tolerant(String.self, forKey: .routeLabel) ?? "Follow Default",
                eqGains: container.tolerant(TolerantDoubleArray.self, forKey: .eqGains)?.values ?? [],
                eqRange: container.tolerantDouble(forKey: .eqRange) ?? 12
            )
        }
    }

    public struct ProfileSummary: Codable, Equatable, Identifiable, Sendable {
        public enum Scope: String, Codable, Equatable, Sendable {
            case global
            case outputDevice
        }

        public private(set) var id: String
        public private(set) var name: String
        public private(set) var scope: Scope
        public private(set) var outputDeviceID: String?
        public private(set) var matchingGlobalPresetID: String?

        public init(
            id: String,
            name: String,
            scope: Scope = .global,
            outputDeviceID: String? = nil,
            matchingGlobalPresetID: String? = nil
        ) {
            self.id = WidgetWireNormalization.identity(id, fallback: "unknown-profile")
            self.name = name.isEmpty ? "Profile" : String(name.prefix(80))
            self.scope = scope
            self.outputDeviceID = scope == .outputDevice
                ? outputDeviceID.flatMap(WidgetWireNormalization.optionalIdentity)
                : nil
            self.matchingGlobalPresetID = scope == .outputDevice
                ? matchingGlobalPresetID.flatMap(WidgetWireNormalization.optionalIdentity)
                : nil
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case name
            case scope
            case outputDeviceID
            case matchingGlobalPresetID
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let id = container.tolerant(String.self, forKey: .id) ?? ""
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Profile identity cannot be empty")
                )
            }
            self.init(
                id: id,
                name: container.tolerant(String.self, forKey: .name) ?? "Profile",
                scope: container.tolerant(Scope.self, forKey: .scope) ?? .global,
                outputDeviceID: container.tolerant(String.self, forKey: .outputDeviceID),
                matchingGlobalPresetID: container.tolerant(
                    String.self,
                    forKey: .matchingGlobalPresetID
                )
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
    case profile
    case host
}

/// Commands support idempotent absolute values and bounded relative gestures.
/// Schema validation rejects relative actions from older clients that did not
/// provide the ordering guarantees required for safe replay.
public enum WidgetCommandAction: Codable, Equatable, Sendable {
    case setMuted(Bool)
    case setVolume(Double)
    case adjustVolume(Double)
    case toggleMuted
    case setBoost(Double)
    case setEQBandGain(band: Int, gain: Double)
    case selectOutput
    case applyProfile
    case assignProfileToCurrentOutput
    case revertProfileChanges
    case refresh

    private enum CodingKeys: String, CodingKey {
        case type, value, band, gain
    }

    private enum Kind: String, Codable {
        case setMuted, setVolume, adjustVolume, toggleMuted, setBoost, setEQBandGain, selectOutput, applyProfile
        case assignProfileToCurrentOutput, revertProfileChanges, refresh
    }

    public var isRelative: Bool {
        switch self {
        case .adjustVolume, .toggleMuted: true
        default: false
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)
        switch kind {
        case .setMuted:
            self = .setMuted(try container.decode(Bool.self, forKey: .value))
        case .setVolume:
            self = .setVolume(try container.decode(Double.self, forKey: .value))
        case .adjustVolume:
            self = .adjustVolume(try container.decode(Double.self, forKey: .value))
        case .toggleMuted:
            self = .toggleMuted
        case .setBoost:
            self = .setBoost(try container.decode(Double.self, forKey: .value))
        case .setEQBandGain:
            self = .setEQBandGain(
                band: try container.decode(Int.self, forKey: .band),
                gain: try container.decode(Double.self, forKey: .gain)
            )
        case .selectOutput:
            self = .selectOutput
        case .applyProfile:
            self = .applyProfile
        case .assignProfileToCurrentOutput:
            self = .assignProfileToCurrentOutput
        case .revertProfileChanges:
            self = .revertProfileChanges
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
        case let .adjustVolume(value):
            try container.encode(Kind.adjustVolume, forKey: .type)
            try container.encode(value, forKey: .value)
        case .toggleMuted:
            try container.encode(Kind.toggleMuted, forKey: .type)
        case let .setBoost(value):
            try container.encode(Kind.setBoost, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .setEQBandGain(band, gain):
            try container.encode(Kind.setEQBandGain, forKey: .type)
            try container.encode(band, forKey: .band)
            try container.encode(gain, forKey: .gain)
        case .selectOutput:
            try container.encode(Kind.selectOutput, forKey: .type)
        case .applyProfile:
            try container.encode(Kind.applyProfile, forKey: .type)
        case .assignProfileToCurrentOutput:
            try container.encode(Kind.assignProfileToCurrentOutput, forKey: .type)
        case .revertProfileChanges:
            try container.encode(Kind.revertProfileChanges, forKey: .type)
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
    public static let currentSchemaVersion = 6
    public static let legacyCompatibleSchemaVersion = 5
    public static let defaultLifetime: TimeInterval = 30
    public static let maximumLifetime: TimeInterval = 120

    public let schemaVersion: Int
    public let id: UUID
    public let sequence: UInt64
    public let createdAt: Date
    public let expiresAt: Date
    public let targetType: WidgetCommandTargetType
    public let targetIdentity: String?
    public let action: WidgetCommandAction

    public init(
        schemaVersion: Int = WidgetCommand.currentSchemaVersion,
        id: UUID = UUID(),
        sequence: UInt64 = 0,
        createdAt: Date = Date(),
        expiresAt: Date? = nil,
        targetType: WidgetCommandTargetType,
        targetIdentity: String?,
        action: WidgetCommandAction
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.sequence = sequence
        self.createdAt = createdAt
        self.expiresAt = expiresAt ?? createdAt.addingTimeInterval(Self.defaultLifetime)
        self.targetType = targetType
        self.targetIdentity = targetIdentity
        self.action = action
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, sequence, createdAt, expiresAt, targetType, targetIdentity, action
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: container.tolerant(Int.self, forKey: .schemaVersion) ?? Self.legacyCompatibleSchemaVersion,
            id: try container.decode(UUID.self, forKey: .id),
            sequence: container.tolerant(UInt64.self, forKey: .sequence) ?? 0,
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            expiresAt: try container.decode(Date.self, forKey: .expiresAt),
            targetType: try container.decode(WidgetCommandTargetType.self, forKey: .targetType),
            targetIdentity: container.tolerant(String.self, forKey: .targetIdentity),
            action: try container.decode(WidgetCommandAction.self, forKey: .action)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(expiresAt, forKey: .expiresAt)
        try container.encode(targetType, forKey: .targetType)
        try container.encodeIfPresent(targetIdentity, forKey: .targetIdentity)
        try container.encode(action, forKey: .action)
    }

    public static func app(
        id: UUID = UUID(),
        identity: String,
        action: WidgetCommandAction,
        createdAt: Date = Date(),
        lifetime: TimeInterval = WidgetCommand.defaultLifetime
    ) -> WidgetCommand {
        make(
            id: id,
            createdAt: createdAt,
            lifetime: lifetime,
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
        make(
            id: id,
            createdAt: createdAt,
            lifetime: lifetime,
            targetType: .outputDevice,
            targetIdentity: identity,
            action: .setMuted(muted)
        )
    }

    public static func outputDeviceVolume(
        id: UUID = UUID(),
        identity: String,
        volume: Double,
        createdAt: Date = Date(),
        lifetime: TimeInterval = WidgetCommand.defaultLifetime
    ) -> WidgetCommand {
        make(
            id: id,
            createdAt: createdAt,
            lifetime: lifetime,
            targetType: .outputDevice,
            targetIdentity: identity,
            action: .setVolume(volume)
        )
    }

    public static func selectOutputDevice(
        id: UUID = UUID(),
        identity: String,
        createdAt: Date = Date(),
        lifetime: TimeInterval = WidgetCommand.defaultLifetime
    ) -> WidgetCommand {
        make(
            id: id,
            createdAt: createdAt,
            lifetime: lifetime,
            targetType: .outputDevice,
            targetIdentity: identity,
            action: .selectOutput
        )
    }

    public static func applyProfile(
        id: UUID = UUID(),
        identity: String,
        createdAt: Date = Date(),
        lifetime: TimeInterval = WidgetCommand.defaultLifetime
    ) -> WidgetCommand {
        make(
            id: id,
            createdAt: createdAt,
            lifetime: lifetime,
            targetType: .profile,
            targetIdentity: identity,
            action: .applyProfile
        )
    }

    public static func assignProfileToCurrentOutput(
        id: UUID = UUID(),
        identity: String,
        createdAt: Date = Date(),
        lifetime: TimeInterval = WidgetCommand.defaultLifetime
    ) -> WidgetCommand {
        make(
            id: id,
            createdAt: createdAt,
            lifetime: lifetime,
            targetType: .profile,
            targetIdentity: identity,
            action: .assignProfileToCurrentOutput
        )
    }

    public static func refresh(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        lifetime: TimeInterval = WidgetCommand.defaultLifetime
    ) -> WidgetCommand {
        make(
            id: id,
            createdAt: createdAt,
            lifetime: lifetime,
            targetType: .host,
            targetIdentity: nil,
            action: .refresh
        )
    }

    public static func setAllAppsMuted(
        id: UUID = UUID(),
        muted: Bool,
        createdAt: Date = Date(),
        lifetime: TimeInterval = WidgetCommand.defaultLifetime
    ) -> WidgetCommand {
        make(
            id: id,
            createdAt: createdAt,
            lifetime: lifetime,
            targetType: .host,
            targetIdentity: nil,
            action: .setMuted(muted)
        )
    }

    public static func setAllAppsVolume(
        id: UUID = UUID(),
        volume: Double,
        createdAt: Date = Date(),
        lifetime: TimeInterval = WidgetCommand.defaultLifetime
    ) -> WidgetCommand {
        make(
            id: id,
            createdAt: createdAt,
            lifetime: lifetime,
            targetType: .host,
            targetIdentity: nil,
            action: .setVolume(volume)
        )
    }

    public static func revertProfileChanges(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        lifetime: TimeInterval = WidgetCommand.defaultLifetime
    ) -> WidgetCommand {
        make(
            id: id,
            createdAt: createdAt,
            lifetime: lifetime,
            targetType: .host,
            targetIdentity: nil,
            action: .revertProfileChanges
        )
    }

    private static func make(
        id: UUID,
        createdAt: Date,
        lifetime: TimeInterval,
        targetType: WidgetCommandTargetType,
        targetIdentity: String?,
        action: WidgetCommandAction
    ) -> WidgetCommand {
        WidgetCommand(
            id: id,
            sequence: WidgetCommandSequence.next(),
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(lifetime),
            targetType: targetType,
            targetIdentity: targetIdentity,
            action: action
        )
    }

    public func validate(now: Date = Date()) throws {
        guard schemaVersion == Self.currentSchemaVersion
            || schemaVersion == Self.legacyCompatibleSchemaVersion else {
            throw WidgetCommandValidationError.unsupportedSchema
        }
        if schemaVersion == Self.legacyCompatibleSchemaVersion, action.isRelative {
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
        case (.host, .refresh), (.host, .setMuted), (.host, .revertProfileChanges):
            try Self.requireNoIdentity(identity)
        case let (.host, .setVolume(value)):
            try Self.requireNoIdentity(identity)
            guard value.isFinite, (0...1).contains(value) else {
                throw WidgetCommandValidationError.invalidValue
            }
        case (.app, .setMuted), (.app, .toggleMuted):
            try Self.requireIdentity(identity)
        case let (.app, .setVolume(value)):
            try Self.requireIdentity(identity)
            guard value.isFinite, (0...1).contains(value) else {
                throw WidgetCommandValidationError.invalidValue
            }
        case let (.app, .adjustVolume(delta)):
            try Self.requireIdentity(identity)
            guard delta.isFinite, (-1...1).contains(delta) else {
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
        case (.outputDevice, .setMuted), (.outputDevice, .toggleMuted):
            try Self.requireIdentity(identity)
        case let (.outputDevice, .setVolume(value)):
            try Self.requireIdentity(identity)
            guard value.isFinite, (0...1).contains(value) else {
                throw WidgetCommandValidationError.invalidValue
            }
        case let (.outputDevice, .adjustVolume(delta)):
            try Self.requireIdentity(identity)
            guard delta.isFinite, (-1...1).contains(delta) else {
                throw WidgetCommandValidationError.invalidValue
            }
        case (.outputDevice, .selectOutput):
            try Self.requireIdentity(identity)
        case (.profile, .applyProfile):
            try Self.requireIdentity(identity)
        case (.profile, .assignProfileToCurrentOutput):
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

    private static func requireNoIdentity(_ identity: String?) throws {
        guard identity == nil || identity?.isEmpty == true else {
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
