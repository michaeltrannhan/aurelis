import Foundation

struct AudioAppIdentity: Hashable, Codable, Identifiable, RawRepresentable {
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
}

struct AudioAppSnapshot: Identifiable, Codable, Equatable {
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
}

struct AudioDeviceSnapshot: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var isDefault: Bool

    init(id: String, name: String, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

enum BoostLevel: Double, CaseIterable, Codable, Identifiable {
    case x1 = 1
    case x2 = 2
    case x3 = 3
    case x4 = 4

    var id: Double { rawValue }

    var label: String {
        "\(Int(rawValue))x"
    }
}

enum DeviceRoute: Codable, Equatable {
    case followDefault
    case selectedDevice(String)
}

struct AppAudioSettings: Codable, Equatable {
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
        self.route = route
    }

    mutating func setVolume(_ newVolume: Double) {
        volume = AppCustomization.clampedVolume(newVolume, fallback: volume)
    }
}

struct DisplayableAppRow: Identifiable, Equatable {
    var identity: AudioAppIdentity
    var displayName: String
    var isActive: Bool
    var isPinned: Bool
    var level: Double
    var settings: AppAudioSettings

    var id: AudioAppIdentity { identity }
}
