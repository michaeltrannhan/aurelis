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

/// The durable health of the mixer, kept separate from a transient refresh
/// activity indicator. `AudioOperationState` remains available for existing
/// views while callers migrate to this richer representation.
enum MixerPhase: Equatable, Sendable {
    case starting
    case refreshing
    case ready
    case empty
    case permissionLimited
    case degraded
    case failed
}

struct AudioHealthInputs: Equatable, Sendable {
    var permissionState: AudioCapturePermissionState
    var issues: [AudioIssue]
    var isRefreshing: Bool
    var hasCompletedInitialRefresh: Bool
    var appCount: Int
    var readyMessage: String
}

struct AudioHealthSnapshot: Equatable, Sendable {
    let phase: MixerPhase
    let message: String
    /// Refreshing is activity, never a replacement for a permission or fault
    /// state. Consumers can show progress without claiming the mixer is ready.
    let isRefreshing: Bool

    var compatibilityOperationState: AudioOperationState {
        if isRefreshing { return .refreshing }
        switch phase {
        case .starting: return .idle
        case .refreshing: return .refreshing
        case .ready, .empty: return .ready(message)
        case .permissionLimited, .degraded: return .degraded(message)
        case .failed: return .failed(message)
        }
    }
}

enum AudioHealthReducer {
    static func reduce(_ inputs: AudioHealthInputs) -> AudioHealthSnapshot {
        let issues = inputs.issues
        let mostSevereIssue = issues.first(where: { $0.severity == .error }) ?? issues.first
        let phase: MixerPhase
        let message: String

        let hasPublishedPermissionBlocker = issues.contains { $0.domain == .permission }
        if !inputs.permissionState.allowsProcessTaps, hasPublishedPermissionBlocker {
            phase = .permissionLimited
            message = inputs.permissionState.summary
        } else if let issue = mostSevereIssue {
            // A discovery failure means the current snapshot is not known;
            // other faults retain a usable, but degraded, last known mix.
            phase = issue.id == "refresh" ? .failed : .degraded
            message = issue.message
        } else if !inputs.hasCompletedInitialRefresh {
            phase = .starting
            message = "Starting audio discovery…"
        } else if inputs.appCount == 0 {
            phase = .empty
            message = "No audible apps found"
        } else {
            phase = .ready
            message = inputs.readyMessage
        }
        return AudioHealthSnapshot(phase: phase, message: message, isRefreshing: inputs.isRefreshing)
    }
}

/// User-visible failures must never be a direct rendering of an OS error.
/// Raw details remain available only to the local diagnostics stream.
enum UserFacingFailure {
    static func message(from technicalMessage: String, fallback: String = "Couldn’t complete that change. Try again.") -> String {
        let forbiddenMarkers = ["osstatus", "selector", "app group", "file://", "kaudio"]
        let normalized = technicalMessage.lowercased()
        guard !technicalMessage.isEmpty,
              !forbiddenMarkers.contains(where: normalized.contains) else {
            return fallback
        }
        // Preserve useful recovery copy while removing absolute local paths.
        return technicalMessage.replacingOccurrences(
            of: #"/(?:[^\s]+)"#,
            with: "the settings location",
            options: .regularExpression
        )
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

enum AudioRecoveryAction: Equatable, Sendable {
    case retry
    case retryExternalControls
    case requestAudioPermission
    case openAudioPrivacySettings
    case requestAccessibilityPermission
    case openAccessibilitySettings
    case followDefaultOutput(AudioAppIdentity)
    case ignoreApp(AudioAppIdentity)
}

struct AudioIssue: Identifiable, Equatable, Sendable {
    let id: String
    let domain: AudioIssueDomain
    let severity: AudioIssueSeverity
    let affectedApp: AudioAppIdentity?
    let affectedDeviceID: String?
    let message: String
    let recovery: AudioRecoveryAction?
}
