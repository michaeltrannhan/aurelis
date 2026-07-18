import AppKit
import CoreGraphics
import Foundation

/// Reads and requests Screen & System Audio Recording permission and checks the
/// bundle's audio-capture usage description. Injectable so the store can be
/// tested with a fake that never touches system permission state.
@MainActor
protocol AudioCapturePermissionClient {
    func currentState() -> AudioCapturePermissionState
    func requestScreenCaptureAccess() -> AudioCapturePermissionState
    func openPrivacySettings()
    func relaunchApp() async throws
}

enum ApplicationRelaunchError: LocalizedError {
    case notRunningFromApplicationBundle
    case replacementDidNotLaunch

    var errorDescription: String? {
        switch self {
        case .notRunningFromApplicationBundle:
            "EQMacRep is not running from an application bundle, so it cannot safely relaunch itself."
        case .replacementDidNotLaunch:
            "macOS did not confirm that the replacement EQMacRep process launched."
        }
    }
}

@MainActor
protocol ApplicationRelaunching {
    func launchNewInstance(at bundleURL: URL) async throws
}

@MainActor
struct WorkspaceApplicationRelauncher: ApplicationRelaunching {
    var workspace: NSWorkspace = .shared

    func launchNewInstance(at bundleURL: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            workspace.openApplication(at: bundleURL, configuration: configuration) { application, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if application != nil {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ApplicationRelaunchError.replacementDidNotLaunch)
                }
            }
        }
    }
}

@MainActor
struct SystemAudioCapturePermissionClient: AudioCapturePermissionClient {
    static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    var infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    var workspace: NSWorkspace = .shared
    var preflightScreenCaptureAccess: () -> Bool = CGPreflightScreenCaptureAccess
    var requestSystemScreenCaptureAccess: () -> Bool = CGRequestScreenCaptureAccess
    var relauncher: any ApplicationRelaunching = WorkspaceApplicationRelauncher()
    var terminateCurrentApplication: @MainActor () -> Void = { NSApp.terminate(nil) }
    var bundleURL: URL = Bundle.main.bundleURL

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

    func relaunchApp() async throws {
        guard bundleURL.pathExtension == "app" else {
            throw ApplicationRelaunchError.notRunningFromApplicationBundle
        }
        try await relauncher.launchNewInstance(at: bundleURL)
        // Terminate only after launch success has been explicitly confirmed.
        terminateCurrentApplication()
    }

    private var hasAudioUsageDescription: Bool {
        guard let value = infoDictionary["NSAudioCaptureUsageDescription"] as? String else {
            return false
        }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
