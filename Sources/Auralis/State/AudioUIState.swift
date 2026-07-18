import Foundation

enum AudioOperationState: Equatable {
    case idle
    case refreshing
    case ready(String)
    case degraded(String)
    case failed(String)

    var message: String {
        switch self {
        case .idle: "Ready"
        case .refreshing: "Refreshing audio apps…"
        case let .ready(message), let .degraded(message), let .failed(message): message
        }
    }

    var isRefreshing: Bool {
        if case .refreshing = self { true } else { false }
    }
}

enum AudioIssueSeverity: String, Equatable {
    case warning
    case error
}

enum AudioIssueDomain: String, Equatable, Sendable {
    case backend
    case tap
    case permission
    case persistence
    case widget
    case externalControl
}

enum AudioRecoveryAction: Equatable {
    case retry
    case retryExternalControls
    case requestAudioPermission
    case openAudioPrivacySettings
    case requestAccessibilityPermission
    case openAccessibilitySettings
    case followDefaultOutput(AudioAppIdentity)
    case ignoreApp(AudioAppIdentity)
}

struct AudioIssue: Identifiable, Equatable {
    let id: String
    let domain: AudioIssueDomain
    let severity: AudioIssueSeverity
    let affectedApp: AudioAppIdentity?
    let affectedDeviceID: String?
    let message: String
    let recovery: AudioRecoveryAction?
}

enum PermissionKind: String, Equatable {
    case audioCapture
    case accessibility
}

enum PermissionRequirementState: Equatable {
    case notRequested
    case denied
    case restricted
    case granted
    case restartRequired
    case unavailable
}

struct PermissionRequirement: Identifiable, Equatable {
    var id: PermissionKind { kind }
    let kind: PermissionKind
    let state: PermissionRequirementState
    let explanation: String
    let isOptional: Bool
}
