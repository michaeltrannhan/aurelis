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
            // Real app path only: the signal guard re-raises without attempting
            // cleanup; durable ownership is recovered safely in normal context.
            CoreAudioAggregateCrashGuard.install()
            CoreAudioOrphanedAggregateCleanup.destroyOrphans()
        }
    }

    func fetchSnapshot() throws -> AudioBackendSnapshot {
        let targets = Self.coalescedTargets(try processDiscovery.discoverTapTargets())
        let peakLevels = (tapManager as? CoreAudioTapLevelReporting)?.consumePeakLevels() ?? [:]
        let deviceState = try deviceDiscovery.discoverOutputDeviceState()
        eventSource.refreshDeviceListeners()
        tapTargetsByIdentity = Dictionary(targets.map { ($0.identity, $0) }, uniquingKeysWith: Self.mergedTarget)
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
                    level: peakLevels[$0.identity] ?? 0
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
        tapTargetsByIdentity = Dictionary(
            Self.coalescedTargets(targets).map { ($0.identity, $0) },
            uniquingKeysWith: Self.mergedTarget
        )
    }

    private static func coalescedTargets(_ targets: [CoreAudioTapTarget]) -> [CoreAudioTapTarget] {
        var indices: [AudioAppIdentity: Int] = [:]
        var result: [CoreAudioTapTarget] = []
        for target in targets where target.identity.isPersistable {
            if let index = indices[target.identity] {
                result[index] = mergedTarget(result[index], target)
            } else {
                indices[target.identity] = result.count
                result.append(target)
            }
        }
        return result
    }

    private static func mergedTarget(_ first: CoreAudioTapTarget, _ second: CoreAudioTapTarget) -> CoreAudioTapTarget {
        var seen = Set(first.processObjectIDs)
        let processObjectIDs = first.processObjectIDs + second.processObjectIDs.filter { seen.insert($0).inserted }
        return CoreAudioTapTarget(
            identity: first.identity,
            displayName: first.displayName.isEmpty ? second.displayName : first.displayName,
            processObjectIDs: processObjectIDs
        )
    }
}

extension CoreAudioDiscoveryBackend: AudioBackendAppLevelProviding {
    func consumeAppLevels() -> [AudioAppIdentity: Double] {
        (tapManager as? CoreAudioTapLevelReporting)?.consumePeakLevels() ?? [:]
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
