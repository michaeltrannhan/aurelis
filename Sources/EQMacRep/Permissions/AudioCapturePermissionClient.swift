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
    @MainActor func relaunchApp()
}

struct SystemAudioCapturePermissionClient: AudioCapturePermissionClient {
    static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    var infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    var workspace: NSWorkspace = .shared
    var preflightScreenCaptureAccess: () -> Bool = CGPreflightScreenCaptureAccess
    var requestSystemScreenCaptureAccess: () -> Bool = CGRequestScreenCaptureAccess

    func currentState() -> AudioCapturePermissionState {
        AudioCapturePermissionState(
            screenCapture: preflightScreenCaptureAccess() ? .granted : .notDetermined,
            audioUsageDescription: hasAudioUsageDescription ? .present : .missing
        )
    }

    func requestScreenCaptureAccess() -> AudioCapturePermissionState {
        let requestAccepted = requestSystemScreenCaptureAccess()
        let grantIsActive = preflightScreenCaptureAccess()
        let status: ScreenCapturePermissionStatus
        if grantIsActive {
            status = .granted
        } else if requestAccepted {
            // macOS accepted the request, but the running process cannot use the
            // new grant until it is relaunched.
            status = .pendingRestart
        } else {
            // A false request result also represents a denied/disabled grant. A
            // relaunch alone cannot repair that state, so direct users to Settings.
            status = .denied
        }
        return AudioCapturePermissionState(
            screenCapture: status,
            audioUsageDescription: hasAudioUsageDescription ? .present : .missing
        )
    }

    func openPrivacySettings() {
        workspace.open(Self.privacySettingsURL)
    }

    @MainActor
    func relaunchApp() {
        guard let bundleURL = Bundle.main.bundleURL as URL?,
              bundleURL.pathExtension == "app" else {
            // Not running from a bundle (e.g. `swift run`); just terminate.
            NSApp.terminate(nil)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        workspace.openApplication(at: bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    private var hasAudioUsageDescription: Bool {
        guard let value = infoDictionary["NSAudioCaptureUsageDescription"] as? String else {
            return false
        }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
