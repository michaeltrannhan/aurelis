import Foundation

struct CoreAudioRealtimeGainState: Equatable {
    var volume: Float
    var boost: BoostLevel
    var isMuted: Bool
    var eq: EQCurve

    init(volume: Double, boost: BoostLevel, isMuted: Bool, eq: EQCurve = EQCurve()) {
        self.volume = Float(AppCustomization.clampedVolume(volume, fallback: 1))
        self.boost = boost
        self.isMuted = isMuted
        self.eq = eq
    }

    var targetGain: Float {
        isMuted ? 0 : volume * Float(boost.rawValue)
    }
}

struct CoreAudioGainRamp {
    var currentGain: Float
    var coefficient: Float

    mutating func next(targetGain: Float) -> Float {
        currentGain += (targetGain - currentGain) * coefficient
        return currentGain
    }

    static func coefficient(sampleRate: Double, rampMilliseconds: Double = 30) -> Float {
        let rampSeconds = max(rampMilliseconds, 1) / 1000
        return Float(1 - exp(-1 / (sampleRate * rampSeconds)))
    }
}

enum CoreAudioSoftLimiter {
    static let threshold: Float = 0.95
    static let ceiling: Float = 1.0

    static func apply(_ sample: Float) -> Float {
        guard sample.isFinite else { return 0 }
        let absolute = abs(sample)
        guard absolute > threshold else { return sample }
        let headroom = ceiling - threshold
        let overshoot = absolute - threshold
        let compressed = threshold + headroom * (overshoot / (overshoot + headroom))
        return sample >= 0 ? compressed : -compressed
    }
}

enum CoreAudioRealtimeGainProcessor {
    static func process(
        input: UnsafePointer<Float>,
        output: UnsafeMutablePointer<Float>,
        sampleCount: Int,
        targetGain: Float,
        ramp: inout CoreAudioGainRamp
    ) {
        guard sampleCount > 0 else { return }

        for index in 0..<sampleCount {
            let gain = ramp.next(targetGain: targetGain)
            output[index] = CoreAudioSoftLimiter.apply(input[index] * gain)
        }
    }
}
