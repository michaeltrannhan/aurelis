import Foundation

struct AudioBackendSnapshot: Equatable {
    var apps: [AudioAppSnapshot]
    var devices: [AudioDeviceSnapshot]

    init(apps: [AudioAppSnapshot] = [], devices: [AudioDeviceSnapshot] = []) {
        self.apps = apps
        self.devices = devices
    }
}

enum AudioBackendCommand: Equatable {
    case setVolume(AudioAppIdentity, Double)
    case setMuted(AudioAppIdentity, Bool)
    case setBoost(AudioAppIdentity, BoostLevel)
    case setEQ(AudioAppIdentity, EQCurve)
    case setRoute(AudioAppIdentity, DeviceRoute)
}

protocol AudioBackend: AnyObject {
    func fetchSnapshot() throws -> AudioBackendSnapshot
    func apply(_ command: AudioBackendCommand) throws
}

protocol AudioBackendStatusProviding {
    func statusMessage(appCount: Int, deviceCount: Int) -> String
}

protocol AudioBackendTapSynchronizing {
    func synchronizeTaps(activeAppIDs: Set<AudioAppIdentity>, ignoredAppIDs: Set<AudioAppIdentity>) throws
    func tearDownTap(for identity: AudioAppIdentity) throws
    func tearDownAllTaps() throws
}

/// Backends that can notify observers of external audio-topology changes
/// (process list, device list, default output) so the store can refresh live.
protocol AudioBackendUpdatePublishing {
    var updateEvents: AsyncStream<Void> { get }
}
