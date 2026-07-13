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

/// Backends that can read and control the system default output device's
/// hardware volume and mute state. The store surfaces this as a top-level
/// output volume section so the user can adjust the sound output without
/// touching per-app mixers.
struct OutputVolumeState: Equatable {
    var volume: Double
    var isMuted: Bool
    var deviceName: String?

    init(volume: Double = 1, isMuted: Bool = false, deviceName: String? = nil) {
        self.volume = min(max(volume.isFinite ? volume : 1, 0), 1)
        self.isMuted = isMuted
        self.deviceName = deviceName
    }
}

protocol AudioBackendOutputVolumeControlling: AnyObject {
    /// Reads volume/mute for the system default output device.
    func readOutputVolume() throws -> OutputVolumeState
    /// Reads volume/mute for an arbitrary output device by UID.
    func readOutputVolume(forUID uid: String) throws -> OutputVolumeState
    /// Sets the system default output device's volume.
    func setOutputVolume(_ volume: Double) throws
    /// Sets an arbitrary output device's volume by UID.
    func setOutputVolume(_ volume: Double, forUID uid: String) throws
    /// Sets the system default output device's mute flag.
    func setOutputMuted(_ muted: Bool) throws
    /// Sets an arbitrary output device's mute flag by UID.
    func setOutputMuted(_ muted: Bool, forUID uid: String) throws
    /// Installs a HAL listener that fires when the default output device,
    /// its volume, or its mute state changes. The closure is invoked on an
    /// arbitrary queue; the store hops to the main actor.
    func startObservingOutputVolume(_ onChange: @escaping @Sendable () -> Void)
    func stopObservingOutputVolume()
}
