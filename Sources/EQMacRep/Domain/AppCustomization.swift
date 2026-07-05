import Foundation

enum AppAppearance: String, CaseIterable, Codable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

struct PopupDimensions: Codable, Equatable {
    var width: Double
    var rowHeight: Double
    var contentPadding: Double
}

enum PopupDensity: String, CaseIterable, Codable, Identifiable {
    case compact
    case comfortable
    case spacious

    var id: String { rawValue }

    var label: String {
        switch self {
        case .compact: return "Compact"
        case .comfortable: return "Comfortable"
        case .spacious: return "Spacious"
        }
    }

    var dimensions: PopupDimensions {
        switch self {
        case .compact:
            return PopupDimensions(width: 420, rowHeight: 48, contentPadding: 10)
        case .comfortable:
            return PopupDimensions(width: 500, rowHeight: 60, contentPadding: 14)
        case .spacious:
            return PopupDimensions(width: 580, rowHeight: 74, contentPadding: 18)
        }
    }
}

enum VolumeStep: Double, CaseIterable, Codable, Identifiable {
    case onePercent = 0.01
    case twoPercent = 0.02
    case fivePercent = 0.05
    case tenPercent = 0.10

    var id: Double { rawValue }
    var fraction: Double { rawValue }

    var label: String {
        "\(Int(rawValue * 100))%"
    }
}

enum BackendMode: String, CaseIterable, Codable, Identifiable {
    case mock
    case coreAudioDiscovery

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mock: return "Mock"
        case .coreAudioDiscovery: return "CoreAudio Discovery"
        }
    }
}

struct AppCustomization: Codable, Equatable {
    var appearance: AppAppearance
    var popupDensity: PopupDensity
    var defaultNewAppVolume: Double
    var eqGainRange: EQGainRange
    var volumeStep: VolumeStep
    var showInactiveApps: Bool
    var backendMode: BackendMode

    init(
        appearance: AppAppearance = .system,
        popupDensity: PopupDensity = .comfortable,
        defaultNewAppVolume: Double = 1,
        eqGainRange: EQGainRange = .db12,
        volumeStep: VolumeStep = .fivePercent,
        showInactiveApps: Bool = true,
        backendMode: BackendMode = .coreAudioDiscovery
    ) {
        self.appearance = appearance
        self.popupDensity = popupDensity
        self.defaultNewAppVolume = Self.clampedVolume(defaultNewAppVolume, fallback: 1)
        self.eqGainRange = eqGainRange
        self.volumeStep = volumeStep
        self.showInactiveApps = showInactiveApps
        self.backendMode = backendMode
    }

    enum CodingKeys: String, CodingKey {
        case appearance
        case popupDensity
        case defaultNewAppVolume
        case eqGainRange
        case volumeStep
        case showInactiveApps
        case backendMode
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            appearance: try values.decodeIfPresent(AppAppearance.self, forKey: .appearance) ?? .system,
            popupDensity: try values.decodeIfPresent(PopupDensity.self, forKey: .popupDensity) ?? .comfortable,
            defaultNewAppVolume: try values.decodeIfPresent(Double.self, forKey: .defaultNewAppVolume) ?? 1,
            eqGainRange: try values.decodeIfPresent(EQGainRange.self, forKey: .eqGainRange) ?? .db12,
            volumeStep: try values.decodeIfPresent(VolumeStep.self, forKey: .volumeStep) ?? .fivePercent,
            showInactiveApps: try values.decodeIfPresent(Bool.self, forKey: .showInactiveApps) ?? true,
            backendMode: try values.decodeIfPresent(BackendMode.self, forKey: .backendMode) ?? .coreAudioDiscovery
        )
    }

    mutating func setDefaultNewAppVolume(_ volume: Double) {
        defaultNewAppVolume = Self.clampedVolume(volume, fallback: defaultNewAppVolume)
    }

    static func clampedVolume(_ volume: Double, fallback: Double) -> Double {
        guard volume.isFinite else { return fallback }
        return min(max(volume, 0), 1)
    }
}
