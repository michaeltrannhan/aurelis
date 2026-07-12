import Darwin.C
import Foundation

private final class CoreAudioBiquadCoefficientSet: @unchecked Sendable {
    let coefficients: [Double]

    init(coefficients: [Double]) {
        self.coefficients = coefficients
    }
}

final class CoreAudioBiquadProcessor: @unchecked Sendable {
    private let sectionCount: Int
    private var leftDelay: [Double]
    private var rightDelay: [Double]
    private nonisolated(unsafe) var coefficientSet: CoreAudioBiquadCoefficientSet
    private nonisolated(unsafe) var isEnabled = false

    init(sectionCount: Int) {
        self.sectionCount = max(sectionCount, 1)
        self.leftDelay = Array(repeating: 0, count: max(sectionCount, 1) * 2)
        self.rightDelay = Array(repeating: 0, count: max(sectionCount, 1) * 2)
        self.coefficientSet = CoreAudioBiquadCoefficientSet(
            coefficients: CoreAudioBiquadMath.unityCoefficientsForSections(max(sectionCount, 1))
        )
    }

    func update(coefficients: [Double], isEnabled: Bool) {
        let expectedCount = sectionCount * 5
        let sanitized = coefficients.count == expectedCount
            ? coefficients
            : CoreAudioBiquadMath.unityCoefficientsForSections(sectionCount)

        coefficientSet = CoreAudioBiquadCoefficientSet(coefficients: sanitized)
        self.isEnabled = isEnabled
    }

    func resetDelayBuffers() {
        leftDelay.withUnsafeMutableBufferPointer { buffer in
            buffer.initialize(repeating: 0)
        }
        rightDelay.withUnsafeMutableBufferPointer { buffer in
            buffer.initialize(repeating: 0)
        }
    }

    func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }

        guard isEnabled else {
            copyInputIfNeeded(input: input, output: output, sampleCount: frameCount * 2)
            return
        }

        let coefficients = coefficientSet.coefficients
        guard coefficients.count == sectionCount * 5 else {
            copyInputIfNeeded(input: input, output: output, sampleCount: frameCount * 2)
            return
        }

        for frame in 0..<frameCount {
            let baseIndex = frame * 2
            var left = Double(input[baseIndex])
            var right = Double(input[baseIndex + 1])

            for section in 0..<sectionCount {
                let coefficientIndex = section * 5
                left = processSample(
                    left,
                    coefficientIndex: coefficientIndex,
                    delayIndex: section * 2,
                    coefficients: coefficients,
                    delays: &leftDelay
                )
                right = processSample(
                    right,
                    coefficientIndex: coefficientIndex,
                    delayIndex: section * 2,
                    coefficients: coefficients,
                    delays: &rightDelay
                )
            }

            guard left.isFinite, right.isFinite else {
                resetDelayBuffers()
                memset(output, 0, frameCount * 2 * MemoryLayout<Float>.size)
                return
            }

            output[baseIndex] = Float(left)
            output[baseIndex + 1] = Float(right)
        }
    }

    private func processSample(
        _ input: Double,
        coefficientIndex: Int,
        delayIndex: Int,
        coefficients: [Double],
        delays: inout [Double]
    ) -> Double {
        let b0 = coefficients[coefficientIndex]
        let b1 = coefficients[coefficientIndex + 1]
        let b2 = coefficients[coefficientIndex + 2]
        let a1 = coefficients[coefficientIndex + 3]
        let a2 = coefficients[coefficientIndex + 4]

        let output = b0 * input + delays[delayIndex]
        delays[delayIndex] = b1 * input - a1 * output + delays[delayIndex + 1]
        delays[delayIndex + 1] = b2 * input - a2 * output
        return output
    }

    private func copyInputIfNeeded(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, sampleCount: Int) {
        if input != UnsafePointer(output) {
            memcpy(output, input, sampleCount * MemoryLayout<Float>.size)
        }
    }
}
