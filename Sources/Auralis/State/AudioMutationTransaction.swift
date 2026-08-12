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
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var isLocked = false
    private var waiters: [Waiter] = []

    var pendingWaiterCount: Int { waiters.count }
    var isIdle: Bool { !isLocked && waiters.isEmpty }

    func acquire() async throws {
        try Task.checkCancellation()
        if !isLocked {
            isLocked = true
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }

        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    func cancelAll() {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
