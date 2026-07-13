import Foundation

final class CoreAudioDiscoveryBackend: AudioBackend {
    private let processDiscovery: CoreAudioProcessDiscovery
    private let deviceDiscovery: CoreAudioDeviceDiscovery
    private let tapManager: CoreAudioTapManaging
    private let eventSource: CoreAudioDiscoveryEventSource
    private let outputVolumeController: CoreAudioOutputVolumeController
    private var tapTargetsByIdentity: [AudioAppIdentity: CoreAudioTapTarget] = [:]
    private(set) var pendingCommands: [AudioBackendCommand] = []

    init(
        processDiscovery: CoreAudioProcessDiscovery = CoreAudioProcessDiscovery(),
        deviceDiscovery: CoreAudioDeviceDiscovery = CoreAudioDeviceDiscovery(),
        tapManager: CoreAudioTapManaging = CoreAudioProcessTapManager(),
        eventSource: CoreAudioDiscoveryEventSource = CoreAudioDiscoveryEventSource(),
        outputVolumeController: CoreAudioOutputVolumeController = CoreAudioOutputVolumeController(),
        runStartupRecovery: Bool = false
    ) {
        self.processDiscovery = processDiscovery
        self.deviceDiscovery = deviceDiscovery
        self.tapManager = tapManager
        self.eventSource = eventSource
        self.outputVolumeController = outputVolumeController
        if runStartupRecovery {
            // Real app path only: install the crash guard and clear any aggregate
            // devices orphaned by a previous crash. Never runs under unit tests.
            CoreAudioAggregateCrashGuard.install()
            CoreAudioOrphanedAggregateCleanup.destroyOrphans()
        }
    }

    func fetchSnapshot() throws -> AudioBackendSnapshot {
        let targets = try processDiscovery.discoverTapTargets()
        let deviceState = try deviceDiscovery.discoverOutputDeviceState()
        eventSource.refreshDeviceListeners()
        tapTargetsByIdentity = Dictionary(uniqueKeysWithValues: targets.map { ($0.identity, $0) })
        if let routeManager = tapManager as? CoreAudioRouteControlling {
            routeManager.setAvailableOutputUIDs(
                deviceState.devices.map(\.id),
                defaultOutputUIDs: deviceState.defaultOutputDeviceUIDs,
                nominalSampleRatesByUID: deviceState.nominalSampleRatesByUID
            )
        }

        return AudioBackendSnapshot(
            apps: targets.map {
                AudioAppSnapshot(
                    identity: $0.identity,
                    displayName: $0.displayName,
                    bundleIdentifier: $0.identity.rawValue.hasPrefix("name:") ? nil : $0.identity.rawValue,
                    isActive: true,
                    level: 0
                )
            },
            devices: deviceState.devices
        )
    }

    func apply(_ command: AudioBackendCommand) throws {
        switch command {
        case let .setVolume(identity, volume):
            (tapManager as? CoreAudioRealtimeTapControlling)?.setVolume(volume, for: identity)
        case let .setMuted(identity, muted):
            (tapManager as? CoreAudioRealtimeTapControlling)?.setMuted(muted, for: identity)
        case let .setBoost(identity, boost):
            (tapManager as? CoreAudioRealtimeTapControlling)?.setBoost(boost, for: identity)
        case let .setEQ(identity, eq):
            (tapManager as? CoreAudioRealtimeTapControlling)?.setEQ(eq, for: identity)
        case let .setRoute(identity, route):
            try (tapManager as? CoreAudioRouteControlling)?.setRoute(identity, route)
        }
    }

    func replaceTapTargetsForTesting(_ targets: [CoreAudioTapTarget]) {
        tapTargetsByIdentity = Dictionary(uniqueKeysWithValues: targets.map { ($0.identity, $0) })
    }
}

extension CoreAudioDiscoveryBackend: AudioBackendUpdatePublishing {
    var updateEvents: AsyncStream<Void> {
        eventSource.events
    }
}

extension CoreAudioDiscoveryBackend: AudioBackendStatusProviding {
    func statusMessage(appCount: Int, deviceCount: Int) -> String {
        var message = "CoreAudio active: \(appCount) app\(appCount == 1 ? "" : "s"), \(deviceCount) device\(deviceCount == 1 ? "" : "s")."
        if let reporter = tapManager as? CoreAudioTapHealthReporting {
            let health = reporter.health
            message += " \(health.activeAppCount) active tap\(health.activeAppCount == 1 ? "" : "s")."
            if health.issueCount > 0 {
                message += " \(health.issueCount) issue\(health.issueCount == 1 ? "" : "s")."
            }
        } else {
            message += " Volume/mute/boost/EQ enabled."
        }
        return message
    }
}

extension CoreAudioDiscoveryBackend: AudioBackendTapSynchronizing {
    func synchronizeTaps(activeAppIDs: Set<AudioAppIdentity>, ignoredAppIDs: Set<AudioAppIdentity>) throws {
        let targets = activeAppIDs
            .subtracting(ignoredAppIDs)
            .compactMap { tapTargetsByIdentity[$0] }
        try tapManager.reconcile(targets: targets)
    }

    func tearDownTap(for identity: AudioAppIdentity) throws {
        try tapManager.tearDown(identity: identity)
    }

    func tearDownAllTaps() throws {
        try tapManager.tearDownAll()
    }
}

extension CoreAudioDiscoveryBackend: AudioBackendOutputVolumeControlling {
    func readOutputVolume() throws -> OutputVolumeState {
        try outputVolumeController.readOutputVolume()
    }

    func readOutputVolume(forUID uid: String) throws -> OutputVolumeState {
        try outputVolumeController.readOutputVolume(forUID: uid)
    }

    func setOutputVolume(_ volume: Double) throws {
        try outputVolumeController.setOutputVolume(volume)
    }

    func setOutputVolume(_ volume: Double, forUID uid: String) throws {
        try outputVolumeController.setOutputVolume(volume, forUID: uid)
    }

    func setOutputMuted(_ muted: Bool) throws {
        try outputVolumeController.setOutputMuted(muted)
    }

    func setOutputMuted(_ muted: Bool, forUID uid: String) throws {
        try outputVolumeController.setOutputMuted(muted, forUID: uid)
    }

    func startObservingOutputVolume(_ onChange: @escaping @Sendable () -> Void) {
        outputVolumeController.startObserving(onChange)
    }

    func stopObservingOutputVolume() {
        outputVolumeController.stopObserving()
    }
}
