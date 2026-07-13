import Foundation

/// Screen & System Audio Recording permission state as EQMacRep understands it.
enum ScreenCapturePermissionStatus: Equatable {
    case notDetermined
    case granted
    /// The system prompt has been answered (or Settings toggled), but macOS only
    /// reports the grant to `CGPreflightScreenCaptureAccess()` after the app is
    /// relaunched. Taps cannot run until then.
    case pendingRestart
    case denied
}

/// Whether the running bundle carries the `NSAudioCaptureUsageDescription`
/// string required for Core Audio process taps.
enum AudioUsageDescriptionStatus: Equatable {
    case present
    case missing
}

/// Combined permission gate for process-tap capture. Taps are only attempted
/// when Screen Recording is granted AND the usage description is present.
struct AudioCapturePermissionState: Equatable {
    var screenCapture: ScreenCapturePermissionStatus
    var audioUsageDescription: AudioUsageDescriptionStatus

    var allowsProcessTaps: Bool {
        screenCapture == .granted && audioUsageDescription == .present
    }

    var summary: String {
        if audioUsageDescription == .missing {
            return "Audio capture usage description missing"
        }

        switch screenCapture {
        case .notDetermined:
            return "Screen & System Audio Recording not requested"
        case .granted:
            return "Audio capture ready"
        case .pendingRestart:
            return "Relaunch EQMacRep to finish enabling audio capture"
        case .denied:
            return "Screen & System Audio Recording denied"
        }
    }

    static let unknown = AudioCapturePermissionState(
        screenCapture: .notDetermined,
        audioUsageDescription: .missing
    )
}
