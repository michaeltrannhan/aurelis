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
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func acquire() async throws {
        try Task.checkCancellation()
        if !isLocked {
            isLocked = true
            return
        }
        let id = UUID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            waiters[id] = continuation
        }
        try Task.checkCancellation()
    }

    func release() {
        if let id = waiters.keys.sorted(by: { $0.uuidString < $1.uuidString }).first {
            let continuation = waiters.removeValue(forKey: id)!
            continuation.resume()
        } else {
            isLocked = false
        }
    }

    func cancelAll() {
        let pending = waiters
        waiters.removeAll()
        isLocked = false
        for (_, continuation) in pending {
            continuation.resume(throwing: CancellationError())
        }
    }
}
