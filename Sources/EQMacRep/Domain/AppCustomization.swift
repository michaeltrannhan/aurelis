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

struct AppCustomization: Codable, Equatable {
    var appearance: AppAppearance
    var popupDensity: PopupDensity
    var defaultNewAppVolume: Double
    var eqGainRange: EQGainRange
    var volumeStep: VolumeStep
    var showInactiveApps: Bool

    init(
        appearance: AppAppearance = .system,
        popupDensity: PopupDensity = .comfortable,
        defaultNewAppVolume: Double = 1,
        eqGainRange: EQGainRange = .db12,
        volumeStep: VolumeStep = .fivePercent,
        showInactiveApps: Bool = true
    ) {
        self.appearance = appearance
        self.popupDensity = popupDensity
        self.defaultNewAppVolume = Self.clampedVolume(defaultNewAppVolume, fallback: 1)
        self.eqGainRange = eqGainRange
        self.volumeStep = volumeStep
        self.showInactiveApps = showInactiveApps
    }

    mutating func setDefaultNewAppVolume(_ volume: Double) {
        defaultNewAppVolume = Self.clampedVolume(volume, fallback: defaultNewAppVolume)
    }

    static func clampedVolume(_ volume: Double, fallback: Double) -> Double {
        guard volume.isFinite else { return fallback }
        return min(max(volume, 0), 1)
    }
}
