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

    @discardableResult
    func start() async -> Bool {
        if isStarted { return true }
        guard let store else { return false }
        let resolvedLayout: WidgetSharedLayout
        do {
            resolvedLayout = try await fileActor.prepareAndResolveLayout()
        } catch {
            store.reportWidgetIPCConfigurationError(error.localizedDescription)
            return false
        }

        store.reportWidgetIPCConfigurationError(nil)
        subscribe(to: store)
        processor = WidgetCommandProcessor(
            layout: resolvedLayout,
            execute: { [weak store] command in
                guard let store else { throw WidgetBridgeError.storeUnavailable }
                try await WidgetCommandStoreExecutor.apply(command, to: store)
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
            isStarted = true
            _ = try await writeSnapshotNow(hostState: .running)
            startHeartbeat()
            drainCommands()
            return true
        } catch {
            watcher.stop()
            processor = nil
            subscriptions.removeAll()
            store.reportWidgetIPCConfigurationError(error.localizedDescription)
            return false
        }
    }

    func stop() async {
        guard isStarted else { return }
        snapshotTask?.cancel()
        snapshotTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        drainTask?.cancel()
        drainTask = nil
        drainRequested = false
        subscriptions.removeAll()

        if (try? await writeSnapshotNow(hostState: .stopped)) != nil {
            reloadTimelines()
        }
        watcher.stop()
        processor = nil
        isStarted = false
    }

    /// Forces an immediate snapshot write, bypassing the debounce.
    func flush() async {
        snapshotTask?.cancel()
        snapshotTask = nil
        do {
            _ = try await writeSnapshotNow(hostState: .running)
        } catch {
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
        snapshotTask?.cancel()
        snapshotTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: snapshotDebounce) }
            catch { return }
            guard !Task.isCancelled else { return }
            do {
                _ = try await writeSnapshotNow(hostState: .running)
            } catch {
                store?.reportWidgetIPCConfigurationError(error.localizedDescription)
            }
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: heartbeatInterval) }
                catch { return }
                guard !Task.isCancelled else { return }
                do {
                    _ = try await writeSnapshotNow(hostState: .running)
                } catch {
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
                level: row.level,
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
        return WidgetSnapshot(
            generatedAt: now,
            hostState: hostState,
            hostUpdatedAt: now,
            statusMessage: statusMessage,
            activeAppCount: store.displayRows.filter(\.isActive).count,
            volumeStep: store.settings.customization.volumeStep.fraction,
            devices: devices,
            apps: apps
        )
    }

    private func drainCommands() {
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
                if let message = report.transportErrors.last {
                    store?.reportWidgetIPCConfigurationError(message)
                } else {
                    store?.reportWidgetIPCConfigurationError(nil)
                }
            } while drainRequested
            drainTask = nil
        }
    }
}
