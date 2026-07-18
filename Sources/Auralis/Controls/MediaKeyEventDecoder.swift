import Foundation

/// A decoded media-key press. Volume keys carry the auto-repeat flag; mute only
/// fires on the initial press.
enum MediaKeyEvent: Equatable {
    case volumeUp(isRepeat: Bool)
    case volumeDown(isRepeat: Bool)
    case muteToggle
}

protocol MediaKeyEventDecoding {
    func decode(data1: Int) -> MediaKeyEvent?
}

/// Decodes an `NSEvent.systemDefined` `data1` field into a media-key event.
/// Layout: high 16 bits are the key type, low 16 bits pack the down/up flag
/// (0x0A = down) and the auto-repeat bit.
struct IOKitMediaKeyDecoder: MediaKeyEventDecoding {
    func decode(data1: Int) -> MediaKeyEvent? {
        let keyType = (data1 & 0xFFFF0000) >> 16
        let keyFlags = data1 & 0xFFFF
        let isDown = ((keyFlags & 0xFF00) >> 8) == 0x0A
        let isRepeat = (keyFlags & 0xFF) != 0

        guard isDown else { return nil }

        switch keyType {
        case 0: return .volumeUp(isRepeat: isRepeat)
        case 1: return .volumeDown(isRepeat: isRepeat)
        case 7: return isRepeat ? nil : .muteToggle
        default: return nil
        }
    }
}
