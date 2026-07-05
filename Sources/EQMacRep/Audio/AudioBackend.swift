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
}

protocol AudioBackend: AnyObject {
    func fetchSnapshot() throws -> AudioBackendSnapshot
    func apply(_ command: AudioBackendCommand) throws
}
