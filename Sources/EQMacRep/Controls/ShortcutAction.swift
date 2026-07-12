import Carbon.HIToolbox
import Foundation

struct HotkeyBinding: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
}

/// Global hotkey actions with default Option+Command bindings. Key codes are
/// Carbon virtual key codes.
enum ShortcutAction: String, CaseIterable, Codable, Identifiable {
    case togglePopup
    case targetAppVolumeUp
    case targetAppVolumeDown
    case targetAppMuteToggle

    var id: String { rawValue }

    var label: String {
        switch self {
        case .togglePopup: return "Toggle Popup"
        case .targetAppVolumeUp: return "Volume Up"
        case .targetAppVolumeDown: return "Volume Down"
        case .targetAppMuteToggle: return "Mute"
        }
    }

    var defaultBinding: HotkeyBinding {
        let optionCommand = UInt32(optionKey | cmdKey)
        switch self {
        case .togglePopup:
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
