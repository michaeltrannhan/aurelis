import AppKit
import CoreGraphics
import Foundation

/// Reads and requests Screen & System Audio Recording permission and checks the
/// bundle's audio-capture usage description. Injectable so the store can be
/// tested with a fake that never touches system permission state.
protocol AudioCapturePermissionClient {
    func currentState() -> AudioCapturePermissionState
    func requestScreenCaptureAccess() -> AudioCapturePermissionState
    func openPrivacySettings()
}

struct SystemAudioCapturePermissionClient: AudioCapturePermissionClient {
    static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    var infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    var workspace: NSWorkspace = .shared

    func currentState() -> AudioCapturePermissionState {
        AudioCapturePermissionState(
            screenCapture: CGPreflightScreenCaptureAccess() ? .granted : .notDetermined,
            audioUsageDescription: hasAudioUsageDescription ? .present : .missing
        )
    }

    func requestScreenCaptureAccess() -> AudioCapturePermissionState {
        let granted = CGRequestScreenCaptureAccess()
        return AudioCapturePermissionState(
            screenCapture: granted ? .granted : .denied,
            audioUsageDescription: hasAudioUsageDescription ? .present : .missing
        )
    }

    func openPrivacySettings() {
        workspace.open(Self.privacySettingsURL)
    }

    private var hasAudioUsageDescription: Bool {
        guard let value = infoDictionary["NSAudioCaptureUsageDescription"] as? String else {
            return false
        }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
