import Foundation

@MainActor
final class AudioSessionCoordinator {
    private var backend: any AudioBackend
    private let backendFactory: (BackendMode) -> any AudioBackend
    private var observationTask: Task<Void, Never>?
    private var pendingRefreshTask: Task<Void, Never>?

    init(
        backend: any AudioBackend,
        backendFactory: @escaping (BackendMode) -> any AudioBackend
    ) {
        self.backend = backend
        self.backendFactory = backendFactory
    }

    var isObserving: Bool { observationTask != nil }

    func fetchSnapshot() throws -> AudioBackendSnapshot { try backend.fetchSnapshot() }
    func apply(_ command: AudioBackendCommand) throws { try backend.apply(command) }

    func statusMessage(appCount: Int, deviceCount: Int) -> String? {
        (backend as? AudioBackendStatusProviding)?.statusMessage(appCount: appCount, deviceCount: deviceCount)
    }

    func synchronizeTaps(
        activeAppIDs: Set<AudioAppIdentity>,
        ignoredAppIDs: Set<AudioAppIdentity>,
        permissionAllowsTaps: Bool
    ) throws {
        guard let tapBackend = backend as? AudioBackendTapSynchronizing else { return }
        guard permissionAllowsTaps else {
            try tapBackend.tearDownAllTaps()
            return
        }
        try tapBackend.synchronizeTaps(activeAppIDs: activeAppIDs, ignoredAppIDs: ignoredAppIDs)
    }

    func tearDownTap(for identity: AudioAppIdentity) throws {
        try (backend as? AudioBackendTapSynchronizing)?.tearDownTap(for: identity)
    }

    func readOutputVolume() throws -> OutputVolumeState {
        try (backend as? AudioBackendOutputVolumeControlling)?.readOutputVolume()
            ?? OutputVolumeState()
    }

    func readOutputVolume(forUID uid: String) throws -> OutputVolumeState {
        try (backend as? AudioBackendOutputVolumeControlling)?.readOutputVolume(forUID: uid)
            ?? OutputVolumeState()
    }

    func setOutputVolume(_ volume: Double) throws {
        try (backend as? AudioBackendOutputVolumeControlling)?.setOutputVolume(volume)
    }

    func setOutputVolume(_ volume: Double, forUID uid: String) throws {
        try (backend as? AudioBackendOutputVolumeControlling)?.setOutputVolume(volume, forUID: uid)
    }

    func setOutputMuted(_ muted: Bool) throws {
        try (backend as? AudioBackendOutputVolumeControlling)?.setOutputMuted(muted)
    }

    func setOutputMuted(_ muted: Bool, forUID uid: String) throws {
        try (backend as? AudioBackendOutputVolumeControlling)?.setOutputMuted(muted, forUID: uid)
    }

    func startOutputVolumeObservation(_ onChange: @escaping @Sendable () -> Void) {
        (backend as? AudioBackendOutputVolumeControlling)?.startObservingOutputVolume(onChange)
    }

    func stopOutputVolumeObservation() {
        (backend as? AudioBackendOutputVolumeControlling)?.stopObservingOutputVolume()
    }

    func switchBackend(to mode: BackendMode) throws {
        let wasObserving = isObserving
        stopObservation()
        stopOutputVolumeObservation()
        try (backend as? AudioBackendTapSynchronizing)?.tearDownAllTaps()
        backend = backendFactory(mode)
        if wasObserving { /* Store restarts with its existing handler after refresh. */ }
    }

    func startObservation(
        debounceNanoseconds: UInt64,
        onUpdate: @escaping @MainActor () -> Void
    ) {
        guard observationTask == nil,
              let publisher = backend as? AudioBackendUpdatePublishing else { return }
        let events = publisher.updateEvents
        observationTask = Task {
            for await _ in events {
                guard !Task.isCancelled else { return }
                pendingRefreshTask?.cancel()
                pendingRefreshTask = Task {
                    do { try await Task.sleep(nanoseconds: debounceNanoseconds) }
                    catch { return }
                    guard !Task.isCancelled else { return }
                    onUpdate()
                }
            }
        }
    }

    func stopObservation() {
        observationTask?.cancel()
        observationTask = nil
        pendingRefreshTask?.cancel()
        pendingRefreshTask = nil
    }

    func shutdown() throws {
        stopObservation()
        stopOutputVolumeObservation()
        try (backend as? AudioBackendTapSynchronizing)?.tearDownAllTaps()
    }
}
