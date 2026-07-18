import Carbon.HIToolbox
import Foundation

struct HotkeyBinding: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32
}

/// Global hotkey actions with default Option+Command bindings. Key codes are
/// Carbon virtual key codes.
enum ShortcutAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case showMixer
    case targetAppVolumeUp
    case targetAppVolumeDown
    case targetAppMuteToggle

    var id: String { rawValue }

    var label: String {
        switch self {
        case .showMixer: return "Show Mixer"
        case .targetAppVolumeUp: return "Volume Up"
        case .targetAppVolumeDown: return "Volume Down"
        case .targetAppMuteToggle: return "Mute"
        }
    }

    var defaultBinding: HotkeyBinding {
        let optionCommand = UInt32(optionKey | cmdKey)
        switch self {
        case .showMixer:
            return HotkeyBinding(keyCode: UInt32(kVK_Space), modifiers: optionCommand)
        case .targetAppVolumeUp:
            return HotkeyBinding(keyCode: UInt32(kVK_UpArrow), modifiers: optionCommand)
        case .targetAppVolumeDown:
            return HotkeyBinding(keyCode: UInt32(kVK_DownArrow), modifiers: optionCommand)
        case .targetAppMuteToggle:
            return HotkeyBinding(keyCode: UInt32(kVK_ANSI_M), modifiers: optionCommand)
        }
    }
}
