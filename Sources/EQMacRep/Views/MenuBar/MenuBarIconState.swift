import Foundation

/// Volume level buckets used to pick a menu-bar speaker glyph.
enum VolumeBucket: Equatable {
    case zero
    case low
    case mid
    case high

    static func bucket(for volume: Double) -> VolumeBucket {
        switch volume {
        case ..<0.001: return .zero
        case ..<0.34: return .low
        case ..<0.67: return .mid
        default: return .high
        }
    }
}

/// Derives the menu-bar icon SF Symbol from the loudest target's volume/mute and
/// the chosen icon style.
enum MenuBarIconState {
    static func symbolName(style: MenuBarIconStyle, volume: Double, isMuted: Bool) -> String {
        switch style {
        case .equalizer:
            return "slider.horizontal.3"
        case .waveform:
            return isMuted ? "waveform.slash" : "waveform"
        case .speaker:
            if isMuted { return "speaker.slash.fill" }
            switch VolumeBucket.bucket(for: volume) {
            case .zero: return "speaker.fill"
            case .low: return "speaker.wave.1.fill"
            case .mid: return "speaker.wave.2.fill"
            case .high: return "speaker.wave.3.fill"
            }
        }
    }
}
