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

struct VolumeHUDPeakTracker {
    private(set) var peak = 0.0
    private var appName: String?

    mutating func update(
        for state: VolumeHUDState,
        segmentCount: Int = 12
    ) -> Double {
        let sourceChanged = appName != state.appName
        appName = state.appName
        if state.isMuted {
            peak = 0
        } else if sourceChanged {
            peak = state.volume
        } else {
            let decay = 1 / Double(max(segmentCount, 1)) / 2
            peak = max(state.volume, peak - decay)
        }
        return peak
    }
}
