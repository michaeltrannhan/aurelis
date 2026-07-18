import Foundation

/// Pure value model for the volume HUD. Volume is clamped to the unit range.
struct VolumeHUDState: Equatable {
    var appName: String
    var volume: Double
    var isMuted: Bool

    init(appName: String, volume: Double, isMuted: Bool) {
        self.appName = appName
        self.volume = min(max(volume.isFinite ? volume : 0, 0), 1)
        self.isMuted = isMuted
    }

    var percent: Int { Int((volume * 100).rounded()) }
}
