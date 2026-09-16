import Foundation
import ServiceManagement

/// macOS login-item state. `.unavailable` covers `SMAppService` `.notFound`,
/// which happens for unpackaged `swift run` binaries and similarly unstable
/// locations that cannot own a login item.
enum LoginItemStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case unavailable

    init(_ status: SMAppService.Status) {
        switch status {
        case .enabled:
            self = .enabled
        case .requiresApproval:
            self = .requiresApproval
        case .notRegistered:
            self = .notRegistered
        case .notFound:
            self = .unavailable
        @unknown default:
            self = .unavailable
        }
    }

    var isEnabled: Bool {
        self == .enabled || self == .requiresApproval
    }

    var canChange: Bool {
        self != .unavailable
    }

    /// First-run default: on whenever macOS can actually register the app.
    var defaultOnboardingEnabled: Bool {
        canChange
    }
}

enum LoginItemError: LocalizedError, Equatable {
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Launch at login is available after installing Auralis.app."
        }
    }
}

@MainActor
protocol LoginItemClient {
    func currentStatus() -> LoginItemStatus
    func register() throws
    func unregister() throws
    @discardableResult func openLoginItemsSettings() -> Bool
}

@MainActor
struct ServiceManagementLoginItemClient: LoginItemClient {
    func currentStatus() -> LoginItemStatus {
        LoginItemStatus(SMAppService.mainApp.status)
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    func openLoginItemsSettings() -> Bool {
        SMAppService.openSystemSettingsLoginItems()
        return true
    }
}

/// Owns the login-item toggle. macOS is the source of truth; this is not stored
/// in settings JSON so System Settings and Auralis cannot drift.
@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var status: LoginItemStatus
    @Published private(set) var lastErrorMessage: String?

    var isEnabled: Bool { status.isEnabled }
    var canChange: Bool { status.canChange }

    private let client: any LoginItemClient

    init(client: any LoginItemClient = ServiceManagementLoginItemClient()) {
        self.client = client
        self.status = client.currentStatus()
    }

    func refresh() {
        status = client.currentStatus()
    }

    func setEnabled(_ enabled: Bool, opensLoginItemsIfNeeded: Bool = false) {
        lastErrorMessage = nil
        do {
            try apply(enabled)
        } catch {
            lastErrorMessage = UserFacingFailure.from(
                error,
                title: "Couldn’t update login item"
            ).message
            InternalDiagnostics.warning(
                "lifecycle",
                "login-item.update failed=\(error.localizedDescription)"
            )
        }
        refresh()
        if enabled, opensLoginItemsIfNeeded, status == .requiresApproval {
            openLoginItemsSettings()
        }
    }

    /// Applies the first-run checkbox after onboarding is saved. Failures stay
    /// on this controller so setup can still complete.
    func applyOnboardingPreference(_ wantsEnabled: Bool) {
        guard canChange else { return }
        setEnabled(wantsEnabled)
    }

    func openLoginItemsSettings() {
        if !client.openLoginItemsSettings() {
            lastErrorMessage = "Couldn’t open Login Items settings."
        }
    }

    private func apply(_ enabled: Bool) throws {
        let current = client.currentStatus()
        if enabled {
            switch current {
            case .enabled, .requiresApproval:
                return
            case .unavailable:
                throw LoginItemError.unavailable
            case .notRegistered:
                try client.register()
            }
        } else {
            switch current {
            case .notRegistered, .unavailable:
                return
            case .enabled, .requiresApproval:
                try client.unregister()
            }
        }
    }
}
