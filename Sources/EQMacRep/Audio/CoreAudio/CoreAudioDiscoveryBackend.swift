import Foundation

final class CoreAudioDiscoveryBackend: AudioBackend {
    private let processDiscovery: CoreAudioProcessDiscovery
    private let deviceDiscovery: CoreAudioDeviceDiscovery
    private let tapManager: CoreAudioTapManaging
    private var tapTargetsByIdentity: [AudioAppIdentity: CoreAudioTapTarget] = [:]
    private(set) var pendingCommands: [AudioBackendCommand] = []

    init(
        processDiscovery: CoreAudioProcessDiscovery = CoreAudioProcessDiscovery(),
        deviceDiscovery: CoreAudioDeviceDiscovery = CoreAudioDeviceDiscovery(),
        tapManager: CoreAudioTapManaging = CoreAudioProcessTapManager()
    ) {
        self.processDiscovery = processDiscovery
        self.deviceDiscovery = deviceDiscovery
        self.tapManager = tapManager
    }

    func fetchSnapshot() throws -> AudioBackendSnapshot {
        let targets = try processDiscovery.discoverTapTargets()
        let deviceState = try deviceDiscovery.discoverOutputDeviceState()
        tapTargetsByIdentity = Dictionary(uniqueKeysWithValues: targets.map { ($0.identity, $0) })
        if let processTapManager = tapManager as? CoreAudioProcessTapManager {
            processTapManager.defaultOutputDeviceUID = deviceState.defaultOutputDeviceUID
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
        case .setEQ:
            pendingCommands.append(command)
        }
    }

    func replaceTapTargetsForTesting(_ targets: [CoreAudioTapTarget]) {
        tapTargetsByIdentity = Dictionary(uniqueKeysWithValues: targets.map { ($0.identity, $0) })
    }
}

extension CoreAudioDiscoveryBackend: AudioBackendStatusProviding {
    func statusMessage(appCount: Int, deviceCount: Int) -> String {
        "CoreAudio active: \(appCount) app\(appCount == 1 ? "" : "s"), \(deviceCount) device\(deviceCount == 1 ? "" : "s"). Volume/mute/boost enabled; EQ pending."
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
