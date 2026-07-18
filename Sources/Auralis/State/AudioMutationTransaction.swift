import Foundation

/// Complete mutation contract used by the main-actor store. The engine receipt
/// keeps resources needed to finalize or compensate work (for example, an old
/// backend retained until its replacement settings are durable).
struct AudioMutationTransaction<EngineReceipt: Sendable> {
    let previousState: PersistedSettings
    let desiredState: PersistedSettings
    let issueID: String
    let engineIssueDomain: AudioIssueDomain
    let affectedApp: AudioAppIdentity?
    let engineWork: () async throws -> EngineReceipt
    let durableCommit: (PersistedSettings) async throws -> Void
    let finalizeEngineWork: (EngineReceipt) async throws -> Void
    let compensation: (EngineReceipt?) async throws -> Void
}

struct AudioShutdownReport: Equatable, Sendable {
    let editSessionErrorDescriptions: [String]
    let persistenceErrorDescription: String?
    let engineReport: AudioEngineShutdownReport

    var succeeded: Bool {
        editSessionErrorDescriptions.isEmpty
            && persistenceErrorDescription == nil
            && engineReport.succeeded
    }
}

enum AudioEditControl: Hashable, Sendable {
    case volume
    case eqBand(Int)
}

struct AudioEditSessionKey: Hashable, Sendable {
    let app: AudioAppIdentity
    let control: AudioEditControl
    let gestureToken: UUID
}

actor AudioMutationGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
