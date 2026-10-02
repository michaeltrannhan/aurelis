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
    private var isAcceptingCommands = true
    private var workerTask: Task<Void, Never>?
    private enum Work {
        case command(receiptID: UUID, command: ControlCommand, preview: Bool)
        case operation(@MainActor @Sendable () async throws -> Void, CheckedContinuation<Void, Error>)
    }
    private var commandQueue: [Work] = []
    private var previewOrder: [ControlTarget] = []
    private var previewTasks: [ControlTarget: Task<Void, Never>] = [:]
    private var previewWorkers: [UUID: Task<Void, Never>] = [:]
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
        guard isAcceptingCommands, let store else {
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

        if command.target == .activeApps {
            for row in store.displayRows where row.isActive {
                let target = ControlTarget.app(row.identity)
                let baseline = pendingProjection[target] ?? (try? ControlProjection.committed(
                    for: target, displayRows: store.displayRows, settings: store.settings,
                    devices: store.devices, deviceVolumeStates: store.deviceVolumeStates))
                if let baseline, let next = try? ControlProjection.applying(command.mutation, to: baseline, target: target) {
                    pendingProjection[target] = next
                    actionStates[target] = .pending(projected: next)
                }
            }
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
            // Earlier gestures must enter the ordered worker before a key,
            // widget, or other discrete mutation can execute.
            for target in previewOrder { flushContinuous(for: target) }
            commandQueue.append(.command(receiptID: receipt.id, command: command, preview: false))
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
        previewOrder.removeAll { $0 == target }
        commandQueue.append(.command(receiptID: pending.receiptID, command: pending.command, preview: false))
        kickWorker()
    }

    /// Closes admission before waiting, cancels uncommitted gesture work, and
    /// waits for the active ordered transaction to finish before engine teardown.
    func stop() async {
        isAcceptingCommands = false
        let previews = Array(previewWorkers.values)
        for task in previews { task.cancel() }
        previewTasks.removeAll()
        let cancelled = Array(latestPreview.values)
        let queued = commandQueue
        latestPreview.removeAll()
        previewOrder.removeAll()
        commandQueue.removeAll()
        for item in cancelled { complete(receiptID: item.receiptID, result: .cancelled) }
        for work in queued {
            switch work {
            case let .command(id, _, preview): if !preview { complete(receiptID: id, result: .cancelled) }
            case let .operation(_, continuation): continuation.resume(throwing: CancellationError())
            }
        }
        for task in previews { await task.value }
        await workerTask?.value
        pendingProjection.removeAll()
        actionStates = actionStates.mapValues { _ in .idle }
    }

    private func coalesces(_ first: ControlMutation, with second: ControlMutation) -> Bool {
        switch (first, second) {
        case (.setVolume, .setVolume), (.setEQ, .setEQ), (.setBoost, .setBoost): true
        case let (.setEQBand(firstBand, _), .setEQBand(secondBand, _)): firstBand == secondBand
        default: false
        }
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
        if let previous = latestPreview[command.target] {
            if coalesces(previous.command.mutation, with: command.mutation) {
                complete(receiptID: previous.receiptID, result: .cancelled)
            } else {
                flushContinuous(for: command.target)
            }
        }
        if latestPreview[command.target] == nil { previewOrder.append(command.target) }
        latestPreview[command.target] = (receiptID, command)
        previewTasks[command.target]?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.previewWorkers[receiptID] = nil }
            try? await Task.sleep(nanoseconds: self.previewMinIntervalNanoseconds)
            guard !Task.isCancelled else { return }
            await self.runPreviewIfNeeded(for: command.target)
            try? await Task.sleep(nanoseconds: self.gestureIdleNanoseconds)
            guard !Task.isCancelled else { return }
            guard let pending = self.latestPreview[command.target],
                  pending.receiptID == receiptID else { return }
            self.latestPreview[command.target] = nil
            self.previewTasks[command.target] = nil
            self.previewOrder.removeAll { $0 == command.target }
            self.commandQueue.append(.command(receiptID: pending.receiptID, command: pending.command, preview: false))
            self.kickWorker()
        }
        previewTasks[command.target] = task
        previewWorkers[receiptID] = task
    }

    private func runPreviewIfNeeded(for target: ControlTarget) async {
        guard let pending = latestPreview[target], !previewInFlight.contains(target) else { return }
        previewInFlight.insert(target)
        commandQueue.append(.command(receiptID: pending.receiptID, command: pending.command, preview: true))
        kickWorker()
    }

    func performOrdered(_ operation: @escaping @MainActor @Sendable () async throws -> Void) async throws {
        guard isAcceptingCommands else { throw CancellationError() }
        for target in previewOrder { flushContinuous(for: target) }
        try await withCheckedThrowingContinuation { continuation in
            commandQueue.append(.operation(operation, continuation))
            kickWorker()
        }
    }

    private func kickWorker() {
        guard workerTask == nil else { return }
        workerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while let work = self.commandQueue.first {
                self.commandQueue.removeFirst()
                switch work {
                case let .operation(operation, continuation):
                    do { try await operation(); continuation.resume() }
                    catch { continuation.resume(throwing: error) }
                case let .command(id, command, preview):
                    guard let store = self.store else {
                        self.complete(receiptID: id, result: .cancelled)
                        continue
                    }
                    let result = await store.executeProjectedControl(command)
                    if preview { self.previewInFlight.remove(command.target) }
                    else {
                        self.settle(item: (id, command), result: result, store: store)
                        self.complete(receiptID: id, result: result)
                    }
                }
            }
            self.workerTask = nil
        }
    }

    private func settle(
        item: (receiptID: UUID, command: ControlCommand),
        result: ControlResult,
        store: AudioControlStore
    ) {
        let target = item.command.target
        if target == .activeApps {
            for row in store.displayRows where row.isActive {
                let appTarget = ControlTarget.app(row.identity)
                if !hasNewerWork(for: appTarget) {
                    pendingProjection[appTarget] = nil
                    actionStates[appTarget] = .idle
                }
            }
        }
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
            || commandQueue.contains { work in
                if case let .command(_, command, _) = work { return command.target == target || command.target == .activeApps }
                return false
            }
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
