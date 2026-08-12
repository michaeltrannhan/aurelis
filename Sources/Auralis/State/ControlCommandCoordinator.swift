import Combine
import Foundation

/// Main-actor coordinator: synchronously folds relative input against committed
/// plus pending state, publishes an optimistic projection, then executes through
/// one ordered worker.
@MainActor
final class ControlCommandCoordinator: ObservableObject {
    @Published private(set) var actionStates: [ControlTarget: ControlActionState] = [:]
    @Published private(set) var lastReceipt: ControlReceipt?

    private weak var store: AudioControlStore?
    private var pendingProjection: [ControlTarget: ControlProjectedState] = [:]
    private var workerQueued = false
    private var commandQueue: [(receiptID: UUID, command: ControlCommand)] = []
    private var previewTasks: [ControlTarget: Task<Void, Never>] = [:]
    private var previewInFlight: Set<ControlTarget> = []
    private var latestPreview: [ControlTarget: (receiptID: UUID, command: ControlCommand)] = [:]
    private var pendingReceiptIDs: Set<UUID> = []
    private var results: [UUID: ControlResult] = [:]
    private var retainedResultOrder: [UUID] = []
    private var resultWaiters: [UUID: [CheckedContinuation<ControlResult, Never>]] = [:]
    private let retainedResultLimit = 512
    private let previewMinIntervalNanoseconds: UInt64 = 33_333_333 // 30 Hz
    private let gestureIdleNanoseconds: UInt64 = 200_000_000

    func attach(store: AudioControlStore) {
        self.store = store
    }

    /// Synchronously accepts and projects; durable work runs on the ordered worker.
    func submit(_ command: ControlCommand) -> ControlReceipt {
        guard let store else {
            return .rejected(
                target: command.target,
                mutation: command.mutation,
                source: command.source,
                failure: UserFacingFailure(title: "Unavailable", message: "Audio controls are not ready.")
            )
        }

        var committed: ControlProjectedState?
        let projected: ControlProjectedState
        do {
            let current = try ControlProjection.committed(
                for: command.target,
                displayRows: store.displayRows,
                settings: store.settings,
                devices: store.devices,
                deviceVolumeStates: store.deviceVolumeStates
            )
            committed = current
            projected = try ControlProjection.applying(
                command.mutation,
                to: pendingProjection[command.target] ?? current,
                target: command.target
            )
        } catch {
            let failure = UserFacingFailure.from(error)
            let receipt = ControlReceipt.rejected(
                target: command.target,
                mutation: command.mutation,
                source: command.source,
                failure: failure
            )
            lastReceipt = receipt
            actionStates[command.target] = .failed(previous: committed, failure: failure)
            complete(receiptID: receipt.id, result: .rejected(failure))
            return receipt
        }

        pendingProjection[command.target] = projected
        actionStates[command.target] = .pending(projected: projected)
        let receipt = ControlReceipt.accepted(
            target: command.target,
            mutation: command.mutation,
            source: command.source,
            projected: projected
        )
        pendingReceiptIDs.insert(receipt.id)
        lastReceipt = receipt

        switch command.source {
        case .ui where isContinuous(command.mutation):
            enqueuePreview(command, receiptID: receipt.id)
        default:
            commandQueue.append((receipt.id, command))
            kickWorker()
        }
        return receipt
    }

    func result(for receiptID: UUID) async -> ControlResult {
        if let existing = results[receiptID] { return existing }
        guard pendingReceiptIDs.contains(receiptID) else { return .timedOut }
        return await withCheckedContinuation { continuation in
            resultWaiters[receiptID, default: []].append(continuation)
        }
    }

    func flushContinuous(for target: ControlTarget) {
        previewTasks[target]?.cancel()
        previewTasks[target] = nil
        guard let pending = latestPreview.removeValue(forKey: target) else { return }
        commandQueue.append(pending)
        kickWorker()
    }

    private func isContinuous(_ mutation: ControlMutation) -> Bool {
        switch mutation {
        case .setVolume, .setEQ, .setEQBand, .setBoost:
            return true
        default:
            return false
        }
    }

    private func enqueuePreview(_ command: ControlCommand, receiptID: UUID) {
        if let superseded = latestPreview[command.target] {
            complete(receiptID: superseded.receiptID, result: .cancelled)
        }
        latestPreview[command.target] = (receiptID, command)
        previewTasks[command.target]?.cancel()
        previewTasks[command.target] = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.previewMinIntervalNanoseconds)
            guard !Task.isCancelled else { return }
            await self.runPreviewIfNeeded(for: command.target)
            try? await Task.sleep(nanoseconds: self.gestureIdleNanoseconds)
            guard !Task.isCancelled else { return }
            guard let pending = self.latestPreview[command.target],
                  pending.receiptID == receiptID else { return }
            self.latestPreview[command.target] = nil
            self.previewTasks[command.target] = nil
            self.commandQueue.append(pending)
            self.kickWorker()
        }
    }

    private func runPreviewIfNeeded(for target: ControlTarget) async {
        guard let store,
              let command = latestPreview[target]?.command,
              !previewInFlight.contains(target) else { return }
        previewInFlight.insert(target)
        defer { previewInFlight.remove(target) }
        _ = await store.executeProjectedControl(command)
    }

    private func kickWorker() {
        guard !workerQueued else { return }
        workerQueued = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            while let item = self.commandQueue.first {
                self.commandQueue.removeFirst()
                guard let store = self.store else {
                    self.complete(receiptID: item.receiptID, result: .cancelled)
                    continue
                }
                let result = await store.executeProjectedControl(item.command)
                self.settle(item: item, result: result, store: store)
                self.complete(receiptID: item.receiptID, result: result)
            }
            self.workerQueued = false
        }
    }

    private func settle(
        item: (receiptID: UUID, command: ControlCommand),
        result: ControlResult,
        store: AudioControlStore
    ) {
        let target = item.command.target
        if hasNewerWork(for: target) {
            if let projected = pendingProjection[target] {
                actionStates[target] = .pending(projected: projected)
            }
            return
        }

        switch result {
        case let .applied(actual):
            pendingProjection[target] = nil
            actionStates[target] = .applied(actual: actual)
        case let .rejected(failure):
            pendingProjection[target] = nil
            actionStates[target] = .failed(
                previous: try? ControlProjection.committed(
                    for: target,
                    displayRows: store.displayRows,
                    settings: store.settings,
                    devices: store.devices,
                    deviceVolumeStates: store.deviceVolumeStates
                ),
                failure: failure
            )
        case .timedOut, .cancelled:
            pendingProjection[target] = nil
            actionStates[target] = .idle
        }
    }

    private func hasNewerWork(for target: ControlTarget) -> Bool {
        latestPreview[target] != nil
            || commandQueue.contains { $0.command.target == target }
    }

    private func complete(receiptID: UUID, result: ControlResult) {
        pendingReceiptIDs.remove(receiptID)
        if results[receiptID] == nil {
            retainedResultOrder.append(receiptID)
        }
        results[receiptID] = result
        while retainedResultOrder.count > retainedResultLimit {
            results[retainedResultOrder.removeFirst()] = nil
        }
        let waiters = resultWaiters.removeValue(forKey: receiptID) ?? []
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }
}
