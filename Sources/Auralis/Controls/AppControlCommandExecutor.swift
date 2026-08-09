import Foundation

enum AppControlAction {
    case volumeUp
    case volumeDown
    case muteToggle
}

/// Origin is recorded at the command boundary so all external controls follow
/// the same ordering and optimistic-projection rules.
enum ControlSource: Sendable {
    case ui
    case mediaKey
    case hotkey
    case widget(sequence: UInt64)
}

struct ControlReceipt: Equatable, Sendable {
    let id: UUID
    let accepted: Bool
    let target: AudioAppIdentity?
    let projectedSettings: AppAudioSettings?

    static let rejected = ControlReceipt(id: UUID(), accepted: false, target: nil, projectedSettings: nil)
}

enum ControlResult: Equatable, Sendable {
    case applied(AppAudioSettings)
    case rejected
    case failed(previous: AppAudioSettings, message: String)
}

/// Main-actor, ordered command lane for discrete relative controls. It folds
/// every new action into the last visible projection before the backend has
/// acknowledged earlier work, so rapid media-key presses never collapse into a
/// single step.
@MainActor
final class AppControlCommandCoordinator {
    private struct Pending {
        let receipt: ControlReceipt
        let baseline: AppAudioSettings
        let action: AppControlAction
    }

    private let currentSettings: (AudioAppIdentity) -> AppAudioSettings?
    private let publishProjection: (AudioAppIdentity, AppAudioSettings) -> Void
    private let apply: (AudioAppIdentity, AppAudioSettings, AppAudioSettings) async throws -> AppAudioSettings
    private var projected: [AudioAppIdentity: AppAudioSettings] = [:]
    private var pending: [Pending] = []
    private var results: [UUID: ControlResult] = [:]
    private var continuations: [UUID: [CheckedContinuation<ControlResult, Never>]] = [:]
    private var isDraining = false

    init(
        currentSettings: @escaping (AudioAppIdentity) -> AppAudioSettings?,
        publishProjection: @escaping (AudioAppIdentity, AppAudioSettings) -> Void,
        apply: @escaping (AudioAppIdentity, AppAudioSettings, AppAudioSettings) async throws -> AppAudioSettings
    ) {
        self.currentSettings = currentSettings
        self.publishProjection = publishProjection
        self.apply = apply
    }

    func submit(action: AppControlAction, target: AudioAppIdentity, step: Double) -> ControlReceipt {
        guard let baseline = projected[target] ?? currentSettings(target) else { return .rejected }
        let next = AppControlCommandExecutor.nextSettings(settings: baseline, action: action, step: step)
        let receipt = ControlReceipt(id: UUID(), accepted: true, target: target, projectedSettings: next)
        projected[target] = next
        pending.append(Pending(receipt: receipt, baseline: baseline, action: action))
        publishProjection(target, next)
        startDrainingIfNeeded()
        return receipt
    }

    func result(for receipt: ControlReceipt) async -> ControlResult {
        if let result = results[receipt.id] { return result }
        return await withCheckedContinuation { continuation in
            continuations[receipt.id, default: []].append(continuation)
        }
    }

    private func startDrainingIfNeeded() {
        guard !isDraining else { return }
        isDraining = true
        Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        while !pending.isEmpty {
            let next = pending.removeFirst()
            guard let target = next.receipt.target,
                  let desired = next.receipt.projectedSettings else {
                finish(next.receipt.id, with: .rejected)
                continue
            }
            do {
                let applied = try await apply(target, desired, next.baseline)
                finish(next.receipt.id, with: .applied(applied))
            } catch {
                let message = UserFacingFailure.message(from: error.localizedDescription)
                // Do not erase a newer pending projection. If this was the
                // final request, restore the last known engine state instead.
                if !pending.contains(where: { $0.receipt.target == target }) {
                    projected[target] = nil
                    publishProjection(target, next.baseline)
                }
                finish(next.receipt.id, with: .failed(previous: next.baseline, message: message))
            }
        }
        isDraining = false
    }

    private func finish(_ id: UUID, with result: ControlResult) {
        results[id] = result
        let waiting = continuations.removeValue(forKey: id) ?? []
        waiting.forEach { $0.resume(returning: result) }
    }
}

/// Pure command math plus a store-applying executor. Volume-up auto-unmutes;
/// volume-down that reaches zero auto-mutes.
enum AppControlCommandExecutor {
    static func nextSettings(settings: AppAudioSettings, action: AppControlAction, step: Double) -> AppAudioSettings {
        var next = settings
        switch action {
        case .volumeUp:
            next.setVolume(next.volume + step)
            next.isMuted = false
        case .volumeDown:
            next.setVolume(next.volume - step)
            if next.volume <= 0.001 {
                next.isMuted = true
            }
        case .muteToggle:
            next.isMuted.toggle()
        }
        return next
    }
}

/// Applies a control action to the resolved target app through the store.
@MainActor
struct AppControlStoreExecutor {
    let store: AudioControlStore

    @discardableResult
    func perform(
        _ action: AppControlAction,
        frontmostBundleID: String?,
        selectedAppID: AudioAppIdentity?,
        source: ControlSource = .ui
    ) -> ControlReceipt {
        guard let identity = AppControlTargetResolver.resolve(
            rows: store.displayRows,
            levels: store.appLevels.levels,
            frontmostBundleID: frontmostBundleID,
            selectedAppID: selectedAppID
        ) else {
            return .rejected
        }
        return store.submitAppControl(action, target: identity, source: source)
    }
}
