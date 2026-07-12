import Foundation

final class CoreAudioGraphicEQProcessor: @unchecked Sendable {
    private let processor: CoreAudioBiquadProcessor
    private var sampleRate: Double
    private var curve: EQCurve

    init(sampleRate: Double, curve: EQCurve = EQCurve()) {
        self.sampleRate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48000
        self.curve = curve
        self.processor = CoreAudioBiquadProcessor(sectionCount: EQCurve.bandCount)
        applyCurrentCurve(resetDelayBuffers: true)
    }

    func updateCurve(_ curve: EQCurve) {
        self.curve = curve
        applyCurrentCurve(resetDelayBuffers: false)
    }

    func updateSampleRate(_ sampleRate: Double) {
        guard sampleRate.isFinite, sampleRate > 0 else { return }
        self.sampleRate = sampleRate
        applyCurrentCurve(resetDelayBuffers: true)
    }

    func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frameCount: Int) {
        processor.process(input: input, output: output, frameCount: frameCount)
    }

    private func applyCurrentCurve(resetDelayBuffers: Bool) {
        let enabled = !CoreAudioBiquadMath.isFlat(curve)
        let coefficients = CoreAudioBiquadMath.coefficientsForEQCurve(curve, sampleRate: sampleRate)
        processor.update(coefficients: coefficients, isEnabled: enabled)
        if resetDelayBuffers {
            processor.resetDelayBuffers()
        }
    }
}
