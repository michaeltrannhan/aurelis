import Foundation

/// Queue-confined graphic EQ facade. Coefficient calculation happens only on
/// control/setup work; render reads a preallocated immutable bank snapshot.
final class CoreAudioGraphicEQProcessor {
    private let processor: CoreAudioBiquadProcessor
    private var sampleRate: Double
    private var curve: EQCurve

    init(sampleRate: Double, channelCount: Int = 2, curve: EQCurve = EQCurve()) {
        self.sampleRate = Self.validatedSampleRate(sampleRate) ?? 48_000
        self.curve = curve
        processor = CoreAudioBiquadProcessor(
            sectionCount: EQCurve.bandCount,
            channelCount: channelCount
        )
        applyCurrentCurve(resetDelayBuffers: true)
    }

    var channelCount: Int { processor.channelCount }

    func updateCurve(_ curve: EQCurve) {
        self.curve = curve
        applyCurrentCurve(resetDelayBuffers: false)
    }

    func updateSampleRate(_ sampleRate: Double) {
        guard let sampleRate = Self.validatedSampleRate(sampleRate) else { return }
        self.sampleRate = sampleRate
        applyCurrentCurve(resetDelayBuffers: true)
    }

    @inline(__always)
    func renderSnapshot() -> CoreAudioBiquadRenderSnapshot {
        processor.renderSnapshot()
    }

    @inline(__always)
    func processSample(
        _ input: Float,
        channel: Int,
        snapshot: CoreAudioBiquadRenderSnapshot
    ) -> Float {
        processor.processSample(input, channel: channel, snapshot: snapshot)
    }

    func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frameCount: Int) {
        processor.process(input: input, output: output, frameCount: frameCount)
    }

    var storageFingerprint: (
        coefficientsA: UInt,
        coefficientsB: UInt,
        activeSectionsA: UInt,
        activeSectionsB: UInt,
        delays: UInt
    ) {
        processor.storageFingerprint
    }

    private func applyCurrentCurve(resetDelayBuffers: Bool) {
        let enabled = !CoreAudioBiquadMath.isFlat(curve)
        let coefficients = CoreAudioBiquadMath.coefficientsForEQCurve(
            curve,
            sampleRate: sampleRate
        )
        processor.update(coefficients: coefficients, isEnabled: enabled)
        if resetDelayBuffers {
            processor.resetDelayBuffers()
        }
    }

    private static func validatedSampleRate(_ sampleRate: Double) -> Double? {
        guard sampleRate.isFinite,
              (CoreAudioPCMFormat.minimumSampleRate...CoreAudioPCMFormat.maximumSampleRate)
                .contains(sampleRate) else { return nil }
        return sampleRate
    }
}
