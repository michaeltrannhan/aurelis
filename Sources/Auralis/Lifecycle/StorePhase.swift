import Foundation

enum StorePhase: Equatable, Sendable {
    case booting
    case running
    case shuttingDown
    case stopped
}

/// App Group host lease with instance identity, PID heartbeat, and handoff token.
struct AppGroupHostLease: Codable, Equatable, Sendable {
    var instanceID: UUID
    var pid: Int32
    var heartbeatAt: Date
    var handoffToken: UUID

    static let heartbeatInterval: TimeInterval = 2.5
    static let staleAfter: TimeInterval = 7.5

    init(
        instanceID: UUID = UUID(),
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        heartbeatAt: Date = Date(),
        handoffToken: UUID = UUID()
    ) {
        self.instanceID = instanceID
        self.pid = pid
        self.heartbeatAt = heartbeatAt
        self.handoffToken = handoffToken
    }

    func isOwner(at date: Date = Date()) -> Bool {
        pid == ProcessInfo.processInfo.processIdentifier
            && date.timeIntervalSince(heartbeatAt) <= Self.staleAfter
    }

    func isStale(at date: Date = Date()) -> Bool {
        date.timeIntervalSince(heartbeatAt) > Self.staleAfter
    }

    mutating func beat(at date: Date = Date()) {
        heartbeatAt = date
        pid = ProcessInfo.processInfo.processIdentifier
    }
}

enum HostLeaseDecision: Equatable, Sendable {
    case becomeOwner(AppGroupHostLease)
    case activateExistingOwner
    case takeOverStale(AppGroupHostLease)
}

enum HostLeaseCoordinator {
    static func decide(
        existing: AppGroupHostLease?,
        now: Date = Date(),
        currentPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> HostLeaseDecision {
        guard let existing else {
            return .becomeOwner(AppGroupHostLease(pid: currentPID, heartbeatAt: now))
        }
        if existing.pid == currentPID {
            var lease = existing
            lease.beat(at: now)
            return .becomeOwner(lease)
        }
        if existing.isStale(at: now) {
            return .takeOverStale(
                AppGroupHostLease(pid: currentPID, heartbeatAt: now, handoffToken: UUID())
            )
        }
        return .activateExistingOwner
    }
}
