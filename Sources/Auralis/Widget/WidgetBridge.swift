import Combine
import AuralisWidgetShared
import Foundation
import WidgetKit

private enum WidgetBridgeError: LocalizedError {
    case storeUnavailable

    var errorDescription: String? {
        "The audio control store is unavailable."
    }
}

/// App-side owner of widget snapshot publication and command processing.
/// Command watching is independent of scene rendering and attaches to the
/// stable pending directory rather than any replaceable command file.
@MainActor
final class WidgetBridge: ObservableObject {
    private weak var store: AudioControlStore?
    private let fileActor: WidgetIPCFileActor
    private let reloadTimelines: @MainActor @Sendable () -> Void
    private var subscriptions: Set<AnyCancellable> = []
    private var snapshotTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    private var drainRequested = false
    private let snapshotDebounce: UInt64 = 150_000_000
    private let heartbeatInterval: UInt64 = 5_000_000_000
    private let watcher = WidgetCommandDirectoryWatcher()
    private var processor: WidgetCommandProcessor?
    private var isStarted = false
    private var isStopping = false

    /// A lifecycle invariant used by shutdown diagnostics and regression tests:
    /// a stopped bridge must not retain transport work or command processors.
    var hasActiveTransportResources: Bool {
        !activeTransportResourceNames.isEmpty
    }

    var activeTransportResourceNames: [String] {
        var names: [String] = []
        if isStarted { names.append("started-state") }
        if isStopping { names.append("stopping-state") }
        if watcher.isActive { names.append("directory-watcher") }
        if processor != nil { names.append("command-processor") }
        if snapshotTask != nil { names.append("snapshot-task") }
        if heartbeatTask != nil { names.append("heartbeat-task") }
        if drainTask != nil { names.append("drain-task") }
        if !subscriptions.isEmpty { names.append("store-subscriptions") }
        return names
    }

    init(
        store: AudioControlStore,
        layoutResolver: @escaping @Sendable () throws -> WidgetSharedLayout = {
            try WidgetSharedContainer.resolveLayout()
        },
        reloadTimelines: @escaping @MainActor @Sendable () -> Void = {
            WidgetCenter.shared.reloadAllTimelines()
        }
    ) {
        self.store = store
        self.fileActor = WidgetIPCFileActor(layoutResolver: layoutResolver)
        self.reloadTimelines = reloadTimelines
    }

    deinit {
        snapshotTask?.cancel()
        heartbeatTask?.cancel()
        drainTask?.cancel()
    }

    @discardableResult
    func start() async -> Bool {
        if isStarted {
            InternalDiagnostics.record("widget", "bridge.start skipped=already-started")
            return true
        }
        guard let store else {
            InternalDiagnostics.error("widget", "bridge.start failed=store-unavailable")
            return false
        }
        let resolvedLayout: WidgetSharedLayout
        do {
            resolvedLayout = try await fileActor.prepareAndResolveLayout()
        } catch {
            InternalDiagnostics.error("widget", "bridge.layout failed=\(error.localizedDescription)")
            store.reportWidgetIPCConfigurationError(error.localizedDescription)
            return false
        }

        InternalDiagnostics.record("widget", "bridge.layout ready=\(resolvedLayout.rootURL.path)")

        store.reportWidgetIPCConfigurationError(nil)
        subscribe(to: store)
        processor = WidgetCommandProcessor(
            layout: resolvedLayout,
            execute: { [weak store] command, claim in
                guard let store else { throw WidgetBridgeError.storeUnavailable }
                try await WidgetCommandStoreExecutor.apply(command, claim: claim, to: store)
            },
            publishSnapshot: { [weak self] in
                guard let self else { throw WidgetBridgeError.storeUnavailable }
                return try await self.writeSnapshotNow(hostState: .running)
            },
            resultPublished: { [weak self] _ in
                self?.reloadTimelines()
            }
        )

        do {
            let descriptor = try await fileActor.openPendingDirectory()
            try watcher.start(fileDescriptor: descriptor) { [weak self] in
                self?.drainCommands()
            }
            _ = try await writeSnapshotNow(hostState: .running)
            isStarted = true
            startHeartbeat()
            drainCommands()
            InternalDiagnostics.record("widget", "bridge.start complete=true")
            return true
        } catch {
            isStarted = false
            watcher.stop()
            processor = nil
            subscriptions.removeAll()
            InternalDiagnostics.error("widget", "bridge.start failed=\(error.localizedDescription)")
            store.reportWidgetIPCConfigurationError(error.localizedDescription)
            return false
        }
    }

    func stop() async {
        guard isStarted else { return }
        guard !isStopping else { return }
        isStopping = true
        InternalDiagnostics.record("widget", "bridge.stop begin")
        // Quiescent shutdown: stop watcher, await drain of in-flight work,
        // preserve unexecuted claims, write stopped snapshot, then clear processor.
        watcher.stop()
        let pendingSnapshotTask = snapshotTask
        snapshotTask = nil
        pendingSnapshotTask?.cancel()
        let pendingHeartbeatTask = heartbeatTask
        heartbeatTask = nil
        pendingHeartbeatTask?.cancel()
        if let pendingSnapshotTask { await pendingSnapshotTask.value }
        if let pendingHeartbeatTask { await pendingHeartbeatTask.value }
        if let drainTask { await drainTask.value }
        drainTask = nil
        drainRequested = false
        subscriptions.removeAll()

        if (try? await writeSnapshotNow(hostState: .stopped)) != nil {
            reloadTimelines()
        }
        processor = nil
        isStarted = false
        isStopping = false
        InternalDiagnostics.record("widget", "bridge.stop complete")
    }

    /// Forces an immediate snapshot write, bypassing the debounce.
    func flush() async {
        guard isStarted, !isStopping else { return }
        snapshotTask?.cancel()
        snapshotTask = nil
        do {
            _ = try await writeSnapshotNow(hostState: .running)
        } catch {
            InternalDiagnostics.error("widget", "bridge.flush failed=\(error.localizedDescription)")
            store?.reportWidgetIPCConfigurationError(error.localizedDescription)
        }
    }

    private func subscribe(to store: AudioControlStore) {
        subscriptions.removeAll()
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleSnapshotWrite()
            }
            .store(in: &subscriptions)
    }

    private func scheduleSnapshotWrite() {
        guard isStarted, !isStopping else { return }
        snapshotTask?.cancel()
        let delay = snapshotDebounce
        snapshotTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) }
            catch { return }
            guard !Task.isCancelled, let self else { return }
            do {
                _ = try await writeSnapshotNow(hostState: .running)
            } catch {
                InternalDiagnostics.error("widget", "bridge.snapshot failed=\(error.localizedDescription)")
                store?.reportWidgetIPCConfigurationError(error.localizedDescription)
            }
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        let interval = heartbeatInterval
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: interval) }
                catch { return }
                guard !Task.isCancelled, let self else { return }
                do {
                    _ = try await writeSnapshotNow(hostState: .running)
                    // The directory DispatchSource is the low-latency path.
                    // Periodic draining is a bounded fallback for a missed
                    // filesystem event or a watcher interrupted by the OS.
                    drainCommands()
                } catch {
                    InternalDiagnostics.error("widget", "bridge.heartbeat failed=\(error.localizedDescription)")
                    store?.reportWidgetIPCConfigurationError(error.localizedDescription)
                }
            }
        }
    }

    @discardableResult
    private func writeSnapshotNow(hostState: WidgetHostState) async throws -> Date {
        guard let store else { throw WidgetBridgeError.storeUnavailable }
        let now = Date()
        let snapshot = Self.makeSnapshot(from: store, hostState: hostState, now: now)
        return try await fileActor.write(snapshot)
    }

    static func makeSnapshot(
        from store: AudioControlStore,
        hostState: WidgetHostState = .running,
        now: Date = Date()
    ) -> WidgetSnapshot {
        let devices = store.devices.map { device in
            let state = store.deviceVolumeStates[device.id] ?? OutputVolumeState(deviceName: device.name)
            return WidgetSnapshot.DeviceSummary(
                id: device.id,
                name: device.name,
                volume: state.volume,
                isMuted: state.isMuted,
                isDefault: device.isDefault
            )
        }
        let apps = store.displayRows.map { row in
            WidgetSnapshot.AppSummary(
                id: row.identity.rawValue,
                displayName: row.displayName,
                isActive: row.isActive,
                isPinned: row.isPinned,
                level: store.appLevels.level(for: row.identity),
                volume: row.settings.volume,
                isMuted: row.settings.isMuted,
                boost: row.settings.boost.rawValue,
                routeLabel: row.settings.route.label(devices: store.devices),
                eqGains: row.settings.eq.gains,
                eqRange: row.settings.eq.range.rawValue
            )
        }
        let statusMessage = hostState == .running
            ? store.statusMessage
            : "Auralis is closed. Open it to use widget controls."
        let profiles = store.settings.profiles.map { profile in
            WidgetSnapshot.ProfileSummary(
                id: profile.id.uuidString,
                name: profile.name,
                scope: profile.scope.isGlobal ? .global : .outputDevice,
                outputDeviceID: profile.scope.outputDeviceID,
                matchingGlobalPresetID: profile.scope.isGlobal
                    ? nil
                    : store.settings.globalProfilesForDisplay.first {
                        profile.matchesMixerPreset($0)
                    }?.id.uuidString
            )
        }
        return WidgetSnapshot(
            generatedAt: now,
            hostState: hostState,
            hostUpdatedAt: now,
            statusMessage: statusMessage,
            activeAppCount: store.displayRows.filter(\.isActive).count,
            volumeStep: store.settings.customization.volumeStep.fraction,
            devices: devices,
            apps: apps,
            profiles: profiles,
            activeGlobalProfileID: store.settings.activeGlobalProfileID?.uuidString,
            activeLocalProfileID: store.settings.activeLocalProfileID?.uuidString,
            activeProfileID: store.settings.activeProfileID?.uuidString,
            profileHasOverrides: store.settings.profileHasOverrides
        )
    }

    private func drainCommands() {
        guard isStarted, !isStopping else { return }
        guard let processor else { return }
        guard drainTask == nil else {
            drainRequested = true
            return
        }
        drainTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                drainRequested = false
                let report = await processor.drain()
                guard !Task.isCancelled else { return }
                for result in report.results {
                    InternalDiagnostics.record(
                        "widget",
                        "command.complete id=\(result.commandID.uuidString) status=\(result.status.rawValue) "
                            + "message=\(result.message)"
                    )
                    if result.status != .applied {
                        InternalDiagnostics.error(
                            "widget",
                            "command.\(result.status.rawValue) message=\(result.message)"
                        )
                    }
                }
                if let message = report.transportErrors.last {
                    InternalDiagnostics.error("widget", "bridge.command-drain failed=\(message)")
                    store?.reportWidgetIPCConfigurationError(message)
                } else {
                    store?.reportWidgetIPCConfigurationError(nil)
                }
            } while drainRequested
            drainTask = nil
        }
    }
}
