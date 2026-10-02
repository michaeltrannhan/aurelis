import Darwin
import AuralisWidgetShared
import Foundation

enum WidgetCommandExecutionError: LocalizedError, Equatable {
    case appNotFound(String)
    case outputDeviceNotFound(String)
    case unsupportedAction

    var errorDescription: String? {
        switch self {
        case let .appNotFound(identity):
            "The audio app \(identity) is no longer available."
        case let .outputDeviceNotFound(identity):
            "The output device \(identity) is no longer available."
        case .unsupportedAction:
            "The widget command action is unsupported."
        }
    }
}

struct WidgetCommandDrainReport: Equatable, Sendable {
    var results: [WidgetCommandResult] = []
    var transportErrors: [String] = []
}

/// Recovery-aware host-side command processor. Relative commands are durably
/// resolved to absolute actions before apply so crash replay never double-adjusts.
actor WidgetCommandProcessor {
    typealias Execute = @MainActor @Sendable (WidgetCommand, WidgetCommandClaim) async throws -> Void
    typealias PublishSnapshot = @MainActor @Sendable () async throws -> Date
    typealias ResultPublished = @MainActor @Sendable (WidgetCommandResult) -> Void

    private let layout: WidgetSharedLayout
    private let now: @Sendable () -> Date
    private let execute: Execute
    private let publishSnapshot: PublishSnapshot
    private let resultPublished: ResultPublished

    init(
        layout: WidgetSharedLayout,
        now: @escaping @Sendable () -> Date = Date.init,
        execute: @escaping Execute,
        publishSnapshot: @escaping PublishSnapshot,
        resultPublished: @escaping ResultPublished = { _ in }
    ) {
        self.layout = layout
        self.now = now
        self.execute = execute
        self.publishSnapshot = publishSnapshot
        self.resultPublished = resultPublished
    }

    @discardableResult
    func drain() async -> WidgetCommandDrainReport {
        var report = WidgetCommandDrainReport()
        let claims: [WidgetCommandClaim]
        do {
            claims = try WidgetCommandQueue.claimAvailable(layout: layout)
        } catch {
            report.transportErrors.append(error.localizedDescription)
            return report
        }

        var ready: [(claim: WidgetCommandClaim, command: WidgetCommand)] = []
        for claim in claims {
            if WidgetCommandQueue.result(for: claim.commandID, layout: layout) != nil {
                try? WidgetCommandQueue.complete(claim)
                continue
            }
            do {
                let command = try WidgetCommandQueue.readCommand(claim)
                try command.validate(now: now())
                ready.append((claim, command))
            } catch {
                do {
                    report.results.append(try await publishTerminalResult(
                        for: claim,
                        status: .rejected,
                        message: error.localizedDescription,
                        snapshotGeneratedAt: nil
                    ))
                } catch {
                    report.transportErrors.append(error.localizedDescription)
                }
            }
        }

        ready.sort { lhs, rhs in
            if lhs.command.sequence != rhs.command.sequence {
                return lhs.command.sequence < rhs.command.sequence
            }
            if lhs.command.createdAt != rhs.command.createdAt {
                return lhs.command.createdAt < rhs.command.createdAt
            }
            return lhs.command.id.uuidString < rhs.command.id.uuidString
        }

        for item in ready {
            do {
                try await execute(item.command, item.claim)
            } catch {
                let snapshotDate = try? await publishSnapshot()
                do {
                    report.results.append(try await publishTerminalResult(
                        for: item.claim,
                        status: .failed,
                        message: error.localizedDescription,
                        snapshotGeneratedAt: snapshotDate
                    ))
                } catch {
                    report.transportErrors.append(error.localizedDescription)
                    break
                }
                continue
            }

            let snapshotDate: Date
            do {
                snapshotDate = try await publishSnapshot()
            } catch {
                // Deliberately retain the claim. Replaying the absolute action
                // is safer than acknowledging before the visible snapshot.
                report.transportErrors.append(error.localizedDescription)
                break
            }

            do {
                report.results.append(try await publishTerminalResult(
                    for: item.claim,
                    status: .applied,
                    message: "Applied widget command.",
                    snapshotGeneratedAt: snapshotDate
                ))
            } catch {
                // Later actions must not overtake a retained earlier claim:
                // replaying it afterward would overwrite their newer state.
                report.transportErrors.append(error.localizedDescription)
                break
            }
        }

        WidgetCommandQueue.removeResults(
            olderThan: now().addingTimeInterval(-86_400),
            layout: layout
        )
        return report
    }

    private func publishTerminalResult(
        for claim: WidgetCommandClaim,
        status: WidgetCommandResultStatus,
        message: String,
        snapshotGeneratedAt: Date?
    ) async throws -> WidgetCommandResult {
        let result = WidgetCommandResult(
            commandID: claim.commandID,
            completedAt: now(),
            status: status,
            message: message,
            snapshotGeneratedAt: snapshotGeneratedAt
        )
        try WidgetCommandQueue.publish(result, for: claim, layout: layout)
        // The durable result exists before claimed work is deleted.
        try WidgetCommandQueue.complete(claim)
        await resultPublished(result)
        return result
    }
}

@MainActor
enum WidgetCommandStoreExecutor {
    /// Live resolution, durable replay state, and mutation share the UI/key worker.
    static func apply(_ command: WidgetCommand, claim: WidgetCommandClaim,
                      to store: AudioControlStore, now: Date = Date()) async throws {
        try await store.commandCoordinator.performOrdered {
            let resolved: WidgetCommand
            if command.action.isRelative {
                let action = try resolveRelative(command, store: store)
                resolved = try WidgetCommandQueue.resolve(command, to: action, for: claim, now: now)
            } else {
                resolved = command
            }
            try await apply(resolved, to: store)
        }
    }

    static func resolveRelative(_ command: WidgetCommand, store: AudioControlStore) throws -> WidgetCommandAction {
        switch (command.targetType, command.action) {
        case let (.app, .adjustVolume(delta)):
            let identity = try appIdentity(for: command, store: store)
            let current = store.displayRows.first(where: { $0.identity == identity })?.settings.volume ?? 1
            return .setVolume(min(max(current + delta, 0), 1))
        case (.app, .toggleMuted):
            let identity = try appIdentity(for: command, store: store)
            let current = store.displayRows.first(where: { $0.identity == identity })?.settings.isMuted ?? false
            return .setMuted(!current)
        case let (.app, .adjustEQBandGain(band, delta)):
            let identity = try appIdentity(for: command, store: store)
            guard let curve = store.displayRows.first(where: { $0.identity == identity })?.settings.eq,
                  curve.gains.indices.contains(band) else {
                throw WidgetCommandExecutionError.unsupportedAction
            }
            let range = curve.range.rawValue
            return .setEQBandGain(band: band, gain: min(max(curve.gains[band] + delta, -range), range))
        case (.app, .cycleBoost):
            let identity = try appIdentity(for: command, store: store)
            let current = store.displayRows.first(where: { $0.identity == identity })?.settings.boost ?? .x1
            return .setBoost(current == .x4 ? 1 : current.rawValue + 1)
        case let (.outputDevice, .adjustVolume(delta)):
            guard let identity = command.targetIdentity else {
                throw WidgetCommandExecutionError.outputDeviceNotFound("")
            }
            let current = store.deviceVolumeStates[identity]?.volume ?? 1
            return .setVolume(min(max(current + delta, 0), 1))
        case (.outputDevice, .toggleMuted):
            guard let identity = command.targetIdentity else {
                throw WidgetCommandExecutionError.outputDeviceNotFound("")
            }
            let current = store.deviceVolumeStates[identity]?.isMuted ?? false
            return .setMuted(!current)
        default:
            throw WidgetCommandExecutionError.unsupportedAction
        }
    }

    static func apply(_ command: WidgetCommand, to store: AudioControlStore) async throws {
        switch (command.targetType, command.action) {
        case let (.app, .setMuted(muted)):
            let identity = try appIdentity(for: command, store: store)
            try await store.setMuted(muted, for: identity)
        case let (.app, .setVolume(volume)):
            let identity = try appIdentity(for: command, store: store)
            try await store.setVolume(volume, for: identity)
        case let (.app, .setBoost(value)):
            let identity = try appIdentity(for: command, store: store)
            guard let boost = BoostLevel(rawValue: value) else {
                throw WidgetCommandExecutionError.unsupportedAction
            }
            try await store.setBoost(boost, for: identity)
        case let (.app, .setEQBandGain(band, gain)):
            let identity = try appIdentity(for: command, store: store)
            try await store.setEQGain(gain, band: band, for: identity)
        case let (.outputDevice, .setMuted(muted)):
            guard let identity = command.targetIdentity,
                  store.devices.contains(where: { $0.id == identity }) else {
                throw WidgetCommandExecutionError.outputDeviceNotFound(command.targetIdentity ?? "")
            }
            try await store.setDeviceMuted(muted, for: identity)
        case let (.outputDevice, .setVolume(volume)):
            guard let identity = command.targetIdentity,
                  store.devices.contains(where: { $0.id == identity }) else {
                throw WidgetCommandExecutionError.outputDeviceNotFound(command.targetIdentity ?? "")
            }
            try await store.setDeviceVolume(volume, for: identity)
        case (.outputDevice, .selectOutput):
            guard let identity = command.targetIdentity,
                  store.devices.contains(where: { $0.id == identity }) else {
                throw WidgetCommandExecutionError.outputDeviceNotFound(command.targetIdentity ?? "")
            }
            try await store.setDefaultOutputDevice(identity)
        case (.profile, .applyProfile):
            guard let rawID = command.targetIdentity,
                  let profileID = UUID(uuidString: rawID),
                  store.settings.profiles.contains(where: { $0.id == profileID }) else {
                throw WidgetCommandExecutionError.unsupportedAction
            }
            try await store.applyProfile(profileID)
        case (.profile, .assignProfileToCurrentOutput):
            guard let rawID = command.targetIdentity,
                  let profileID = UUID(uuidString: rawID),
                  store.settings.profiles.contains(where: {
                      $0.id == profileID && $0.scope.isGlobal
                  }) else {
                throw WidgetCommandExecutionError.unsupportedAction
            }
            try await store.assignPresetToCurrentOutput(profileID)
        case let (.host, .setMuted(muted)):
            try await store.setAllActiveAppsMuted(muted)
        case let (.host, .setVolume(volume)):
            try await store.setAllActiveAppsVolume(volume)
        case (.host, .revertProfileChanges):
            try await store.revertProfileChanges()
        case (.host, .refresh):
            try await store.refresh()
        default:
            throw WidgetCommandExecutionError.unsupportedAction
        }
    }

    private static func appIdentity(
        for command: WidgetCommand,
        store: AudioControlStore
    ) throws -> AudioAppIdentity {
        let rawIdentity = command.targetIdentity ?? ""
        let identity = AudioAppIdentity(rawValue: rawIdentity)
        guard store.displayRows.contains(where: { $0.identity == identity }) else {
            throw WidgetCommandExecutionError.appNotFound(rawIdentity)
        }
        return identity
    }
}

/// Watches the stable pending directory inode. Atomic creation and deletion of
/// child files continue to produce events without rearming the source.
@MainActor
final class WidgetCommandDirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?

    var isActive: Bool { source != nil }

    deinit {
        source?.cancel()
    }

    func start(
        fileDescriptor descriptor: Int32,
        onEvent: @escaping @MainActor @Sendable () -> Void
    ) throws {
        stop()
        guard descriptor >= 0 else {
            throw POSIXError(.EBADF)
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: .main
        )
        source.setEventHandler {
            Task { @MainActor in onEvent() }
        }
        source.setCancelHandler {
            DispatchQueue.global(qos: .utility).async {
                Darwin.close(descriptor)
            }
        }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }
}
