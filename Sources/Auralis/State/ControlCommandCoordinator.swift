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
    private var latestPreviewCommand: [ControlTarget: ControlCommand] = [:]
    private var results: [UUID: ControlResult] = [:]
    private var resultWaiters: [UUID: [CheckedContinuation<ControlResult, Never>]] = [:]
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

        let committed = committedProjection(for: command.target, store: store)
        let baseline = pendingProjection[command.target] ?? committed
        let projected: ControlProjectedState
        do {
            projected = try Self.apply(command.mutation, to: baseline, target: command.target)
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
        return await withCheckedContinuation { continuation in
            resultWaiters[receiptID, default: []].append(continuation)
        }
    }

    func flushContinuous(for target: ControlTarget) {
        previewTasks[target]?.cancel()
        previewTasks[target] = nil
        guard let command = latestPreviewCommand[target] else { return }
        latestPreviewCommand[target] = nil
        let receiptID = UUID()
        commandQueue.append((receiptID, command))
        kickWorker()
    }

    func projected(for target: ControlTarget) -> ControlProjectedState? {
        pendingProjection[target]
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
        latestPreviewCommand[command.target] = command
        previewTasks[command.target]?.cancel()
        previewTasks[command.target] = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.previewMinIntervalNanoseconds)
            guard !Task.isCancelled else { return }
            await self.runPreviewIfNeeded(for: command.target)
            try? await Task.sleep(nanoseconds: self.gestureIdleNanoseconds)
            guard !Task.isCancelled else { return }
            self.commandQueue.append((receiptID, command))
            self.latestPreviewCommand[command.target] = nil
            self.kickWorker()
        }
    }

    private func runPreviewIfNeeded(for target: ControlTarget) async {
        guard let store,
              let command = latestPreviewCommand[target],
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
                guard let store = self.store else { continue }
                let result = await store.executeProjectedControl(item.command)
                switch result {
                case let .applied(actual):
                    self.pendingProjection[item.command.target] = actual
                    self.actionStates[item.command.target] = .applied(actual: actual)
                case let .rejected(failure):
                    self.pendingProjection[item.command.target] = nil
                    self.actionStates[item.command.target] = .failed(
                        previous: self.committedProjection(for: item.command.target, store: store),
                        failure: failure
                    )
                case .timedOut, .cancelled:
                    self.pendingProjection[item.command.target] = nil
                    self.actionStates[item.command.target] = .idle
                }
                self.complete(receiptID: item.receiptID, result: result)
            }
            self.workerQueued = false
        }
    }

    private func complete(receiptID: UUID, result: ControlResult) {
        results[receiptID] = result
        let waiters = resultWaiters.removeValue(forKey: receiptID) ?? []
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }

    private func committedProjection(for target: ControlTarget, store: AudioControlStore) -> ControlProjectedState {
        switch target {
        case let .app(identity):
            if let row = store.displayRows.first(where: { $0.identity == identity }) {
                return ControlProjectedState(
                    volume: row.settings.volume,
                    isMuted: row.settings.isMuted,
                    boost: row.settings.boost,
                    eq: row.settings.eq,
                    route: row.settings.route,
                    displayName: row.displayName
                )
            }
            return ControlProjectedState(displayName: identity.rawValue)
        case let .outputDevice(deviceID):
            let device = store.devices.first(where: { $0.id == deviceID })
            let state = store.deviceVolumeStates[deviceID]
            return ControlProjectedState(
                volume: state?.volume,
                isMuted: state?.isMuted,
                displayName: device?.name ?? deviceID
            )
        case .activeApps:
            return ControlProjectedState(displayName: "Active apps")
        }
    }

    static func apply(
        _ mutation: ControlMutation,
        to baseline: ControlProjectedState,
        target: ControlTarget
    ) throws -> ControlProjectedState {
        var next = baseline
        switch mutation {
        case let .adjustVolume(delta):
            next.volume = min(max((next.volume ?? 1) + delta, 0), 1)
            if (next.volume ?? 0) > 0.001, next.isMuted == true, delta > 0 {
                next.isMuted = false
            }
            if (next.volume ?? 0) <= 0.001 {
                next.isMuted = true
            }
        case let .setVolume(volume):
            next.volume = min(max(volume, 0), 1)
        case .toggleMute:
            next.isMuted = !(next.isMuted ?? false)
        case let .setMuted(muted):
            next.isMuted = muted
        case let .setBoost(boost):
            next.boost = boost
        case let .setEQ(eq):
            next.eq = eq
        case let .setEQBand(band, gain):
            var eq = next.eq ?? EQCurve()
            eq.setGain(gain, at: band)
            next.eq = eq
        case let .setRoute(route):
            guard case .app = target else {
                throw UserFacingFailure(title: "Unsupported", message: "Routing applies to apps only.")
            }
            next.route = route
        }
        return next
    }
}
