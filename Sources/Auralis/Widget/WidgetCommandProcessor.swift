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
    typealias Execute = @MainActor @Sendable (WidgetCommand) async throws -> Void
    typealias PublishSnapshot = @MainActor @Sendable () async throws -> Date
    typealias ResultPublished = @MainActor @Sendable (WidgetCommandResult) -> Void
    typealias ResolveRelative = @MainActor @Sendable (WidgetCommand) async throws -> WidgetCommandAction

    private let layout: WidgetSharedLayout
    private let now: @Sendable () -> Date
    private let execute: Execute
    private let publishSnapshot: PublishSnapshot
    private let resultPublished: ResultPublished
    private let resolveRelative: ResolveRelative
    private var resolutions: [UUID: WidgetCommandResolution] = [:]

    init(
        layout: WidgetSharedLayout,
        now: @escaping @Sendable () -> Date = Date.init,
        execute: @escaping Execute,
        publishSnapshot: @escaping PublishSnapshot,
        resultPublished: @escaping ResultPublished = { _ in },
        resolveRelative: @escaping ResolveRelative = { command in
            throw WidgetCommandExecutionError.unsupportedAction
        }
    ) {
        self.layout = layout
        self.now = now
        self.execute = execute
        self.publishSnapshot = publishSnapshot
        self.resultPublished = resultPublished
        self.resolveRelative = resolveRelative
    }

    private func resolveIfNeeded(_ command: WidgetCommand) async throws -> WidgetCommand {
        guard command.action.isRelative else { return command }
        if let existing = resolutions[command.id] {
            return WidgetCommand(
                schemaVersion: command.schemaVersion,
                id: command.id,
                sequence: command.sequence,
                createdAt: command.createdAt,
                expiresAt: command.expiresAt,
                targetType: command.targetType,
                targetIdentity: command.targetIdentity,
                action: existing.resolvedAction
            )
        }
        let absolute = try await resolveRelative(command)
        let resolution = WidgetCommandResolution(
            commandID: command.id,
            sequence: command.sequence,
            resolvedAction: absolute,
            resolvedAt: now()
        )
        resolutions[command.id] = resolution
        return WidgetCommand(
            schemaVersion: command.schemaVersion,
            id: command.id,
            sequence: command.sequence,
            createdAt: command.createdAt,
            expiresAt: command.expiresAt,
            targetType: command.targetType,
            targetIdentity: command.targetIdentity,
            action: absolute
        )
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
                let command = try await resolveIfNeeded(item.command)
                try await execute(command)
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
                continue
            }

            do {
                report.results.append(try await publishTerminalResult(
                    for: item.claim,
                    status: .applied,
                    message: "Applied widget command.",
                    snapshotGeneratedAt: snapshotDate
                ))
            } catch {
                report.transportErrors.append(error.localizedDescription)
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
