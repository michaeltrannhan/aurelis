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
    var maxContentHeight: Double
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

    /// The resting popup only needs enough room for one compact mixer row.
    /// Keep the wider dimensions below for the 10-band EQ, where horizontal
    /// space materially improves usability.
    var collapsedWidth: Double {
        switch self {
        case .compact: return 300
        case .comfortable: return 320
        case .spacious: return 340
        }
    }

    var dimensions: PopupDimensions {
        switch self {
        case .compact:
            return PopupDimensions(width: 360, rowHeight: 72, contentPadding: 8, maxContentHeight: 380)
        case .comfortable:
            return PopupDimensions(width: 400, rowHeight: 78, contentPadding: 10, maxContentHeight: 500)
        case .spacious:
            return PopupDimensions(width: 440, rowHeight: 86, contentPadding: 12, maxContentHeight: 620)
        }
    }
}

/// Pure sizing model for the menu-bar popup's scrollable content. These values
/// reflect the compact row's intrinsic layout and the vertical 10-band EQ; using
/// the nominal density row height alone underestimates both and clips expansions.
struct PopupContentLayoutModel {
    static let popupChromeHeight = 112.0
    static let minimumContentHeight = 220.0
    static let compactRowMinimumHeight = 72.0
    static let permissionBannerHeight = 132.0
    static let issueBannerHeight = 64.0
    static let emptyStateHeight = 144.0
    static let expandedEQHeight = 286.0
    static let eqHintHeight = 34.0
    static let rowSpacing = 8.0
    static let sectionSpacing = 10.0
    /// Height reserved by the output-volume section above the scroll view.
    /// Computed from the device count: per-row + spacing.
    static func outputVolumeSectionHeight(deviceCount: Int) -> Double {
        let safeCount = max(deviceCount, 0)
        let rowHeight = 28.0
        let rowSpacing = 3.0
        return Double(safeCount) * rowHeight + Double(max(safeCount - 1, 0)) * rowSpacing
    }

    static func contentHeight(
        dimensions: PopupDimensions,
        rowCount: Int,
        includesPermissionBanner: Bool,
        includesIssueBanner: Bool,
        includesExpandedEQ: Bool,
        availableScreenHeight: Double,
        deviceCount: Int = 1
    ) -> Double {
        let safeRowCount = max(rowCount, 0)
        let safeScreenHeight = availableScreenHeight.isFinite ? availableScreenHeight : 700
        let screenLimit = max(minimumContentHeight, safeScreenHeight - popupChromeHeight - outputVolumeSectionHeight(deviceCount: deviceCount))
        var sections: [Double] = []

        if includesPermissionBanner { sections.append(permissionBannerHeight) }
        if includesIssueBanner { sections.append(issueBannerHeight) }

        if safeRowCount == 0 {
            sections.append(emptyStateHeight)
        } else {
            let rowHeight = max(dimensions.rowHeight, compactRowMinimumHeight)
            sections.append(
                (Double(safeRowCount) * rowHeight)
                    + (Double(safeRowCount - 1) * rowSpacing)
            )
            sections.append(includesExpandedEQ ? expandedEQHeight : eqHintHeight)
        }

        let naturalHeight = sections.reduce(0, +)
            + (Double(max(sections.count - 1, 0)) * sectionSpacing)
        let densityLimit = dimensions.maxContentHeight
            + (includesExpandedEQ ? expandedEQHeight : 0)
        return min(screenLimit, min(naturalHeight, densityLimit))
    }
}

/// Settings window tabs. `label`/`systemImage` drive the `TabView` items.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case audio
    case shortcuts
    case updates
    case about

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: return "General"
        case .audio: return "Audio"
        case .shortcuts: return "Shortcuts"
        case .updates: return "Updates"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .audio: return "speaker.wave.2"
        case .shortcuts: return "command"
        case .updates: return "arrow.triangle.2.circlepath"
        case .about: return "info.circle"
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

enum HUDStyle: String, CaseIterable, Codable, Identifiable {
    case compact
    case classic
    var id: String { rawValue }

    var label: String {
        switch self {
        case .compact: return "Compact"
        case .classic: return "Classic"
        }
    }
}

enum MenuBarIconStyle: String, CaseIterable, Codable, Identifiable {
    case speaker
    case equalizer
    case waveform
    var id: String { rawValue }

    var label: String {
        switch self {
        case .speaker: return "Speaker"
        case .equalizer: return "Equalizer"
        case .waveform: return "Waveform"
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
    var mediaKeysEnabled: Bool
    var hotkeysEnabled: Bool
    var hudStyle: HUDStyle
    var menuBarIconStyle: MenuBarIconStyle

    init(
        appearance: AppAppearance = .system,
        popupDensity: PopupDensity = .comfortable,
        defaultNewAppVolume: Double = 1,
        eqGainRange: EQGainRange = .db12,
        volumeStep: VolumeStep = .fivePercent,
        showInactiveApps: Bool = true,
        backendMode: BackendMode = .coreAudioDiscovery,
        mediaKeysEnabled: Bool = true,
        hotkeysEnabled: Bool = true,
        hudStyle: HUDStyle = .compact,
        menuBarIconStyle: MenuBarIconStyle = .speaker
    ) {
        self.appearance = appearance
        self.popupDensity = popupDensity
        self.defaultNewAppVolume = Self.clampedVolume(defaultNewAppVolume, fallback: 1)
        self.eqGainRange = eqGainRange
        self.volumeStep = volumeStep
        self.showInactiveApps = showInactiveApps
        self.backendMode = backendMode
        self.mediaKeysEnabled = mediaKeysEnabled
        self.hotkeysEnabled = hotkeysEnabled
        self.hudStyle = hudStyle
        self.menuBarIconStyle = menuBarIconStyle
    }

    enum CodingKeys: String, CodingKey {
        case appearance
        case popupDensity
        case defaultNewAppVolume
        case eqGainRange
        case volumeStep
        case showInactiveApps
        case backendMode
        case mediaKeysEnabled
        case hotkeysEnabled
        case hudStyle
        case menuBarIconStyle
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
            backendMode: try values.decodeIfPresent(BackendMode.self, forKey: .backendMode) ?? .coreAudioDiscovery,
            mediaKeysEnabled: try values.decodeIfPresent(Bool.self, forKey: .mediaKeysEnabled) ?? true,
            hotkeysEnabled: try values.decodeIfPresent(Bool.self, forKey: .hotkeysEnabled) ?? true,
            hudStyle: try values.decodeIfPresent(HUDStyle.self, forKey: .hudStyle) ?? .compact,
            menuBarIconStyle: try values.decodeIfPresent(MenuBarIconStyle.self, forKey: .menuBarIconStyle) ?? .speaker
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
