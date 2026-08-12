import Foundation

struct CoreAudioRealtimeGainState: Equatable {
    var volume: Float
    var boost: BoostLevel
    var isMuted: Bool
    /// Per-app Process EQ, applied once before gain and fan-out.
    var processEQ: EQCurve
    /// Curves ordered in parallel with the tap controller's output UIDs.
    var outputEQs: [EQCurve]

    init(
        volume: Double,
        boost: BoostLevel,
        isMuted: Bool,
        processEQ: EQCurve = EQCurve(),
        outputEQs: [EQCurve] = []
    ) {
        self.volume = Float(AppCustomization.clampedVolume(volume, fallback: 1))
        self.boost = boost
        self.isMuted = isMuted
        self.processEQ = processEQ
        self.outputEQs = outputEQs
    }

    var targetGain: Float {
        guard !isMuted else { return 0 }
        let gain = volume * Float(boost.rawValue)
        return gain.isFinite ? max(gain, 0) : 1
    }

    mutating func syncOutputEQs(forUIDs uids: [String], source: [String: EQCurve]) {
        outputEQs = uids.map { source[$0] ?? EQCurve() }
    }

    func outputEQ(at index: Int) -> EQCurve {
        guard outputEQs.indices.contains(index) else { return EQCurve() }
        return outputEQs[index]
    }
}

struct CoreAudioGainRamp {
    var currentGain: Float
    var coefficient: Float

    @inline(__always)
    mutating func next(targetGain: Float) -> Float {
        let target = targetGain.isFinite ? (targetGain > 0 ? targetGain : 0) : 1
        if !currentGain.isFinite { currentGain = target }
        let clampedCoefficient: Float
        if !coefficient.isFinite {
            clampedCoefficient = 1
        } else if coefficient < 0 {
            clampedCoefficient = 0
        } else if coefficient > 1 {
            clampedCoefficient = 1
        } else {
            clampedCoefficient = coefficient
        }
        currentGain += (target - currentGain) * clampedCoefficient
        let remainder = target - currentGain
        if remainder > -1.0e-7, remainder < 1.0e-7 { currentGain = target }
        return currentGain
    }

    static func coefficient(sampleRate: Double, rampMilliseconds: Double = 30) -> Float {
        guard sampleRate.isFinite,
              (CoreAudioPCMFormat.minimumSampleRate...CoreAudioPCMFormat.maximumSampleRate)
                .contains(sampleRate),
              rampMilliseconds.isFinite,
              rampMilliseconds > 0 else { return 1 }
        let rampSeconds = min(max(rampMilliseconds, 1), 5_000) / 1_000
        let coefficient = 1 - exp(-1 / (sampleRate * rampSeconds))
        guard coefficient.isFinite else { return 1 }
        return Float(min(max(coefficient, 0), 1))
    }
}

enum CoreAudioSoftLimiter {
    static let threshold: Float = 0.95
    static let ceiling: Float = 1.0

    @inline(__always)
    static func apply(_ sample: Float) -> Float {
        guard sample.isFinite else { return 0 }
        let absolute = sample < 0 ? -sample : sample
        guard absolute >= 1.0e-20 else { return 0 }
        guard absolute > threshold else { return sample }
        let headroom = ceiling - threshold
        let overshoot = absolute - threshold
        let compressed = threshold + headroom * (overshoot / (overshoot + headroom))
        return sample >= 0 ? compressed : -compressed
    }
}
