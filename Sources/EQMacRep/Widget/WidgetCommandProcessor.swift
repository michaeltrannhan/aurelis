import Darwin
import EQMacRepWidgetShared
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

/// Recovery-aware host-side command processor. A command whose execution
/// succeeded but whose snapshot/result publication failed stays claimed and is
/// replayed on the next drain; all actions are absolute, so replay is safe.
actor WidgetCommandProcessor {
    typealias Execute = @MainActor @Sendable (WidgetCommand) async throws -> Void
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
            if lhs.command.createdAt != rhs.command.createdAt {
                return lhs.command.createdAt < rhs.command.createdAt
            }
            return lhs.command.id.uuidString < rhs.command.id.uuidString
        }

        for item in ready {
            do {
                try await execute(item.command)
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
