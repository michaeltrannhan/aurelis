import Foundation

struct AudioAppIdentity: Hashable, Codable, Identifiable, RawRepresentable, Sendable {
    var rawValue: String
    var id: String { rawValue }

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(bundleID: String?, fallbackName: String) {
        if let bundleID, !bundleID.isEmpty {
            self.rawValue = bundleID
        } else {
            self.rawValue = "name:\(fallbackName)"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case rawValue
    }

    init(from decoder: Decoder) throws {
        let decoded: String?
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            decoded = value
        } else if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            decoded = container.tolerant(String.self, forKey: .rawValue)
        } else {
            decoded = nil
        }

        let value = decoded?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Audio app identity cannot be empty")
            )
        }
        rawValue = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var isPersistable: Bool {
        !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct AudioAppSnapshot: Identifiable, Codable, Equatable, Sendable {
    var identity: AudioAppIdentity
    var displayName: String
    var bundleIdentifier: String?
    var isActive: Bool
    var level: Double

    var id: AudioAppIdentity { identity }

    init(
        identity: AudioAppIdentity,
        displayName: String,
        bundleIdentifier: String? = nil,
        isActive: Bool = true,
        level: Double = 0
    ) {
        self.identity = identity
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.isActive = isActive
        self.level = min(max(level.isFinite ? level : 0, 0), 1)
    }

    private enum CodingKeys: String, CodingKey {
        case identity
        case displayName
        case bundleIdentifier
        case isActive
        case level
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let identity = try container.decode(AudioAppIdentity.self, forKey: .identity)
        self.init(
            identity: identity,
            displayName: container.tolerant(String.self, forKey: .displayName) ?? identity.rawValue,
            bundleIdentifier: container.tolerant(String.self, forKey: .bundleIdentifier),
            isActive: container.tolerant(Bool.self, forKey: .isActive) ?? true,
            level: container.tolerantDouble(forKey: .level) ?? 0
        )
    }
}

struct AudioDeviceSnapshot: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String
    var isDefault: Bool

    init(id: String, name: String, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case isDefault
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = (container.tolerant(String.self, forKey: .id) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Audio device identity cannot be empty")
            )
        }
        self.init(
            id: id,
            name: container.tolerant(String.self, forKey: .name) ?? id,
            isDefault: container.tolerant(Bool.self, forKey: .isDefault) ?? false
        )
    }
}

enum BoostLevel: Double, CaseIterable, Codable, Identifiable, Sendable {
    case x1 = 1
    case x2 = 2
    case x3 = 3
    case x4 = 4

    var id: Double { rawValue }

    var label: String {
        "\(Int(rawValue))x"
    }
}

enum DeviceRoute: Codable, Equatable, Hashable, Sendable {
    case followDefault
    case selectedDevice(String)
    case multiOutput([String])

    /// Canonicalizes stored route intent without changing the user's output
    /// priority. Multi-output order is significant because the first device is
    /// used as the aggregate's main/clock device.
    var normalized: DeviceRoute {
        switch self {
        case let .multiOutput(deviceIDs):
            var seen = Set<String>()
            let orderedUniqueIDs = deviceIDs.compactMap { rawID -> String? in
                let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
                return !id.isEmpty && seen.insert(id).inserted ? id : nil
            }
            return orderedUniqueIDs.isEmpty ? .followDefault : .multiOutput(orderedUniqueIDs)
        case let .selectedDevice(deviceID):
            let id = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
            return id.isEmpty ? .followDefault : .selectedDevice(id)
        case .followDefault:
            return self
        }
    }

    private enum CodingKeys: String, CodingKey {
        case followDefault
        case selectedDevice
        case multiOutput
        case type
        case deviceID
        case deviceIDs
    }

    private enum PayloadKeys: String, CodingKey {
        case value = "_0"
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer().decode(String.self), single == "followDefault" {
            self = .followDefault
            return
        }

        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            self = .followDefault
            return
        }

        if container.contains(.followDefault) {
            self = .followDefault
            return
        }

        if container.contains(.selectedDevice) {
            let direct = container.tolerant(String.self, forKey: .selectedDevice)
            let nested = (try? container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .selectedDevice))?
                .tolerant(String.self, forKey: .value)
            self = DeviceRoute.selectedDevice(direct ?? nested ?? "").normalized
            return
        }

        if container.contains(.multiOutput) {
            let direct = container.tolerant([String].self, forKey: .multiOutput)
            let nested = (try? container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .multiOutput))?
                .tolerant([String].self, forKey: .value)
            self = DeviceRoute.multiOutput(direct ?? nested ?? []).normalized
            return
        }

        switch container.tolerant(String.self, forKey: .type) {
        case "selectedDevice":
            self = DeviceRoute.selectedDevice(container.tolerant(String.self, forKey: .deviceID) ?? "").normalized
        case "multiOutput":
            self = DeviceRoute.multiOutput(container.tolerant([String].self, forKey: .deviceIDs) ?? []).normalized
        default:
            self = .followDefault
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch normalized {
        case .followDefault:
            _ = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .followDefault)
        case let .selectedDevice(deviceID):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .selectedDevice)
            try payload.encode(deviceID, forKey: .value)
        case let .multiOutput(deviceIDs):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .multiOutput)
            try payload.encode(deviceIDs, forKey: .value)
        }
    }

    /// User-facing label resolved against the currently available devices.
    /// A selected device that is no longer present reads as "Missing Device".
    func label(devices: [AudioDeviceSnapshot]) -> String {
        switch self {
        case .followDefault:
            let defaultName = devices.first(where: \.isDefault)?.name ?? "System Output"
            return "Follow Default (\(defaultName))"
        case let .selectedDevice(deviceID):
            return devices.first(where: { $0.id == deviceID })?.name ?? "Missing Device"
        case .multiOutput:
            guard case let .multiOutput(deviceIDs) = normalized else {
                return DeviceRoute.followDefault.label(devices: devices)
            }
            return "Multi-Output (\(deviceIDs.count) \(deviceIDs.count == 1 ? "device" : "devices"))"
        }
    }
}

struct AppAudioSettings: Codable, Equatable, Sendable {
    var displayName: String
    var volume: Double
    var isMuted: Bool
    var boost: BoostLevel
    var eq: EQCurve
    var route: DeviceRoute

    init(
        displayName: String,
        volume: Double,
        isMuted: Bool = false,
        boost: BoostLevel = .x1,
        eq: EQCurve = EQCurve(),
        route: DeviceRoute = .followDefault
    ) {
        self.displayName = displayName
        self.volume = AppCustomization.clampedVolume(volume, fallback: 1)
        self.isMuted = isMuted
        self.boost = boost
        self.eq = eq
        self.route = route.normalized
    }

    private enum CodingKeys: String, CodingKey {
        case displayName
        case volume
        case isMuted
        case boost
        case eq
        case route
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            displayName: container.tolerant(String.self, forKey: .displayName) ?? "Unknown App",
            volume: container.tolerantDouble(forKey: .volume) ?? 1,
            isMuted: container.tolerant(Bool.self, forKey: .isMuted) ?? false,
            boost: container.tolerant(BoostLevel.self, forKey: .boost) ?? .x1,
            eq: container.tolerant(EQCurve.self, forKey: .eq) ?? EQCurve(),
            route: container.tolerant(DeviceRoute.self, forKey: .route) ?? .followDefault
        )
    }

    mutating func setVolume(_ newVolume: Double) {
        volume = AppCustomization.clampedVolume(newVolume, fallback: volume)
    }

    var normalized: AppAudioSettings {
        AppAudioSettings(
            displayName: displayName.isEmpty ? "Unknown App" : displayName,
            volume: volume,
            isMuted: isMuted,
            boost: boost,
            eq: EQCurve(gains: eq.gains, range: eq.range),
            route: route.normalized
        )
    }
}

struct DisplayableAppRow: Identifiable, Equatable, Sendable {
    var identity: AudioAppIdentity
    var displayName: String
    var isActive: Bool
    var isPinned: Bool
    var settings: AppAudioSettings

    var id: AudioAppIdentity { identity }
}
