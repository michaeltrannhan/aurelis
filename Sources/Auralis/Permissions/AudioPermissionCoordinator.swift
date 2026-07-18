import Foundation

@MainActor
final class AudioPermissionCoordinator {
    private let client: any AudioCapturePermissionClient
    private(set) var state: AudioCapturePermissionState

    init(client: any AudioCapturePermissionClient) {
        self.client = client
        self.state = client.currentState()
    }

    func refresh() -> AudioCapturePermissionState {
        let latest = client.currentState()
        // Preflight reports the same false value for an unrequested and a denied
        // grant. Preserve the more precise result of our last request until a
        // successful preflight proves that access is active.
        if latest.screenCapture == .granted {
            state = latest
        } else if latest.screenCapture == .notDetermined,
                  state.screenCapture == .pendingRestart || state.screenCapture == .denied {
            state = AudioCapturePermissionState(
                screenCapture: state.screenCapture,
                audioUsageDescription: latest.audioUsageDescription
            )
        } else {
            state = latest
        }
        return state
    }

    func requestAudioCapture() -> AudioCapturePermissionState {
        state = client.requestScreenCaptureAccess()
        return state
    }

    func openAudioPrivacySettings() { client.openPrivacySettings() }

    func relaunchApp() async throws { try await client.relaunchApp() }

    var requirements: [PermissionRequirement] {
        let requirementState: PermissionRequirementState
        switch state.screenCapture {
        case .notDetermined: requirementState = .notRequested
        case .denied: requirementState = .denied
        case .pendingRestart: requirementState = .restartRequired
        case .granted:
            requirementState = state.audioUsageDescription == .present ? .granted : .unavailable
        }
        return [PermissionRequirement(
            kind: .audioCapture,
            state: requirementState,
            explanation: "Required to process and control audio from other applications.",
            isOptional: false
        )]
    }
}
