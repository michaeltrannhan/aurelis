import Foundation

/// Typed recovery — never a generic misleading Retry when replay is unsafe.
enum TypedRecoveryOperation: Equatable, Sendable {
    case refreshAudio
    case relaunchAfterPermissionChange
    case replayMutation(ControlCommand)
    case retryExternalControls
    case requestAudioPermission
    case openAudioPrivacySettings
    case requestAccessibilityPermission
    case openAccessibilitySettings
    case followDefaultOutput(AudioAppIdentity)
    case ignoreApp(AudioAppIdentity)
    /// Shown when a serializable mutation cannot be safely replayed.
    case tryControlAgain
}

extension AudioRecoveryAction {
    /// Maps UI-facing recovery actions to executable operations.
    var typed: TypedRecoveryOperation {
        switch self {
        case .retry: .refreshAudio
        case .retryExternalControls: .retryExternalControls
        case .requestAudioPermission: .requestAudioPermission
        case .openAudioPrivacySettings: .openAudioPrivacySettings
        case .requestAccessibilityPermission: .requestAccessibilityPermission
        case .openAccessibilitySettings: .openAccessibilitySettings
        case let .followDefaultOutput(identity): .followDefaultOutput(identity)
        case let .ignoreApp(identity): .ignoreApp(identity)
        case .refreshAudio: .refreshAudio
        case .relaunchAfterPermissionChange: .relaunchAfterPermissionChange
        case let .replayMutation(command): .replayMutation(command)
        case .tryControlAgain: .tryControlAgain
        }
    }
}
