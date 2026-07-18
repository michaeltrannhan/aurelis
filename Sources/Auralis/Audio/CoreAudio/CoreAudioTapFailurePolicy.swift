import CoreAudio
import Foundation

/// Why a tap failed to start, in terms the manager can act on.
enum CoreAudioTapStartFailure: LocalizedError, Equatable {
    case deviceUnavailable
    case inactiveOutputDevices([String])
    case permissionDenied
    case unsupportedProcess
    case fatal(String)
    case osStatus(OSStatus, operation: String)

    var errorDescription: String? {
        CoreAudioTapFailurePolicy.classify(self).message
    }
}

/// What to do about a failure: retry later, disable taps, mark app unsupported,
/// or treat as fatal.
enum CoreAudioTapFailureDecision: Equatable {
    case recoverable(String)
    case disabled(String)
    case unsupported(String)
    case fatal(String)

    var message: String {
        switch self {
        case let .recoverable(message), let .disabled(message),
             let .unsupported(message), let .fatal(message):
            return message
        }
    }

    var shouldRetry: Bool {
        if case .recoverable = self { true } else { false }
    }
}

enum CoreAudioTapFailurePolicy {
    static func classify(_ failure: CoreAudioTapStartFailure) -> CoreAudioTapFailureDecision {
        switch failure {
        case .deviceUnavailable:
            return .recoverable("Output device unavailable")
        case let .inactiveOutputDevices(uids):
            return .recoverable("Core Audio could not activate output devices: \(uids.joined(separator: ", "))")
        case .permissionDenied:
            return .disabled("Screen & System Audio Recording permission denied")
        case .unsupportedProcess:
            return .unsupported("App cannot be tapped")
        case let .fatal(message):
            return .fatal(message)
        case let .osStatus(status, operation):
            return .recoverable("\(operation) failed with OSStatus \(status)")
        }
    }
}
