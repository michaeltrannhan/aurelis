import Foundation

enum MixerPhase: Equatable, Sendable {
    case starting
    case refreshing
    case ready
    case empty
    case permissionLimited
    case degraded
    case failed
}

enum PersistenceHealthState: Equatable, Sendable {
    case clean
    case dirty
    case retrying
    case failed
    case writeBlocked
}

struct AudioHealthInputs: Equatable, Sendable {
    var isBootstrapping: Bool = false
    var isRefreshing: Bool = false
    var permissionAllowsTaps: Bool = true
    var permissionDenied: Bool = false
    var discoveryFailed: Bool = false
    var discoveryFailureMessage: String? = nil
    var persistenceState: PersistenceHealthState = .clean
    var persistenceMessage: String? = nil
    var widgetFault: Bool = false
    var widgetFaultMessage: String? = nil
    var tapFaults: [String] = []
    var backendFaults: [String] = []
    var visibleAppCount: Int = 0
    var statusMessage: String = "Ready"
}

struct AudioHealthSnapshot: Equatable, Sendable {
    var phase: MixerPhase
    var message: String
    var issues: [AudioIssue]
    /// Compatibility projection — never assigned directly by refresh paths.
    var operationState: AudioOperationState

    static let starting = AudioHealthSnapshot(
        phase: .starting,
        message: "Starting…",
        issues: [],
        operationState: .idle
    )
}

enum AudioHealthReducer {
    /// Pure reduction: permission denial, discovery failure, persistence faults,
    /// widget faults, and tap faults are never overwritten by an ordinary refresh.
    static func reduce(_ inputs: AudioHealthInputs) -> AudioHealthSnapshot {
        var issues: [AudioIssue] = []

        if inputs.permissionDenied || !inputs.permissionAllowsTaps {
            let message = inputs.discoveryFailureMessage
                ?? "Screen & System Audio Recording is required to control per-app audio."
            issues.append(
                AudioIssue(
                    id: "audio-permission",
                    domain: .permission,
                    severity: .error,
                    affectedApp: nil,
                    affectedDeviceID: nil,
                    message: UserFacingFailure.sanitizePublicMessage(message),
                    recovery: .requestAudioPermission
                )
            )
        }

        if inputs.discoveryFailed {
            let message = inputs.discoveryFailureMessage
                ?? "Audio discovery failed."
            issues.append(
                AudioIssue(
                    id: "refresh",
                    domain: .backend,
                    severity: .error,
                    affectedApp: nil,
                    affectedDeviceID: nil,
                    message: UserFacingFailure.sanitizePublicMessage(message),
                    recovery: .refreshAudio
                )
            )
        }

        switch inputs.persistenceState {
        case .clean:
            break
        case .dirty, .retrying:
            if let message = inputs.persistenceMessage {
                issues.append(
                    AudioIssue(
                        id: "settings-persistence",
                        domain: .persistence,
                        severity: .warning,
                        affectedApp: nil,
                        affectedDeviceID: nil,
                        message: UserFacingFailure.sanitizePublicMessage(message),
                        recovery: .refreshAudio
                    )
                )
            }
        case .failed, .writeBlocked:
            let message = inputs.persistenceMessage ?? "Settings could not be saved."
            issues.append(
                AudioIssue(
                    id: "settings-persistence",
                    domain: .persistence,
                    severity: .error,
                    affectedApp: nil,
                    affectedDeviceID: nil,
                    message: UserFacingFailure.sanitizePublicMessage(message),
                    recovery: inputs.persistenceState == .writeBlocked ? nil : .refreshAudio
                )
            )
        }

        if inputs.widgetFault {
            let message = inputs.widgetFaultMessage ?? "Widget controls are unavailable."
            issues.append(
                AudioIssue(
                    id: "widget-fault",
                    domain: .widget,
                    severity: .warning,
                    affectedApp: nil,
                    affectedDeviceID: nil,
                    message: UserFacingFailure.sanitizePublicMessage(message),
                    recovery: .refreshAudio
                )
            )
        }

        for (index, fault) in inputs.tapFaults.enumerated() {
            issues.append(
                AudioIssue(
                    id: "tap-fault-\(index)",
                    domain: .tap,
                    severity: .error,
                    affectedApp: nil,
                    affectedDeviceID: nil,
                    message: UserFacingFailure.sanitizePublicMessage(fault),
                    recovery: .refreshAudio
                )
            )
        }

        for (index, fault) in inputs.backendFaults.enumerated() {
            issues.append(
                AudioIssue(
                    id: "backend-fault-\(index)",
                    domain: .backend,
                    severity: .warning,
                    affectedApp: nil,
                    affectedDeviceID: nil,
                    message: UserFacingFailure.sanitizePublicMessage(fault),
                    recovery: .refreshAudio
                )
            )
        }

        let hasHardFault = inputs.permissionDenied
            || !inputs.permissionAllowsTaps
            || inputs.discoveryFailed
            || inputs.persistenceState == .failed
            || inputs.persistenceState == .writeBlocked
            || !inputs.tapFaults.isEmpty

        let phase: MixerPhase
        let message: String
        if inputs.isBootstrapping {
            phase = .starting
            message = "Starting…"
        } else if hasHardFault && (inputs.permissionDenied || !inputs.permissionAllowsTaps) {
            phase = .permissionLimited
            message = issues.first?.message ?? "Permission required"
        } else if inputs.discoveryFailed {
            phase = .failed
            message = issues.first(where: { $0.id == "refresh" })?.message ?? "Audio discovery failed"
        } else if hasHardFault {
            phase = .degraded
            message = issues.first?.message ?? "Audio is degraded"
        } else if inputs.isRefreshing {
            // Refreshing is activity, not health — preserve ready/empty under the activity flag.
            phase = inputs.visibleAppCount == 0 ? .empty : .ready
            message = "Refreshing audio apps…"
        } else if inputs.visibleAppCount == 0 {
            phase = .empty
            message = inputs.statusMessage
        } else if inputs.widgetFault
            || inputs.persistenceState == .dirty
            || inputs.persistenceState == .retrying
            || !inputs.backendFaults.isEmpty {
            phase = .degraded
            message = issues.first?.message ?? inputs.statusMessage
        } else {
            phase = .ready
            message = inputs.statusMessage
        }

        let operationState: AudioOperationState
        if inputs.isRefreshing {
            operationState = .refreshing
        } else {
            switch phase {
            case .starting:
                operationState = .idle
            case .refreshing:
                operationState = .refreshing
            case .ready, .empty:
                operationState = .ready(message)
            case .permissionLimited, .degraded:
                operationState = .degraded(message)
            case .failed:
                operationState = .failed(message)
            }
        }

        return AudioHealthSnapshot(
            phase: phase,
            message: message,
            issues: issues,
            operationState: operationState
        )
    }
}
