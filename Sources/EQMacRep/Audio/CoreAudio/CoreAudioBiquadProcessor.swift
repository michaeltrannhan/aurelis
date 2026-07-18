import Darwin.C
import Foundation

struct CoreAudioBiquadRenderSnapshot {
    fileprivate let coefficients: UnsafePointer<Double>
    fileprivate let isEnabled: Bool
}

/// Queue-confined multi-channel biquad cascade. Coefficients and delay storage
/// are allocated once during setup. Updates write the inactive coefficient bank
/// completely before publishing it, so render observes one immutable snapshot
/// for the entire callback without locks, allocation, or reference swapping.
final class CoreAudioBiquadProcessor {
    private static let denormalThreshold = 1.0e-24
    private static let coefficientMagnitudeLimit = 64.0

    let sectionCount: Int
    let channelCount: Int
    private let coefficientBankA: UnsafeMutableBufferPointer<Double>
    private let coefficientBankB: UnsafeMutableBufferPointer<Double>
    private let delays: UnsafeMutableBufferPointer<Double>
    private var activeBankIndex = 0
    private var bankAEnabled = false
    private var bankBEnabled = false

    init(sectionCount: Int, channelCount: Int = 2) {
        self.sectionCount = max(sectionCount, 1)
        self.channelCount = max(channelCount, 1)
        let coefficientCount = self.sectionCount * 5
        coefficientBankA = .allocate(capacity: coefficientCount)
        coefficientBankB = .allocate(capacity: coefficientCount)
        delays = .allocate(capacity: self.channelCount * self.sectionCount * 2)
        Self.initializeUnity(coefficientBankA, sectionCount: self.sectionCount)
        Self.initializeUnity(coefficientBankB, sectionCount: self.sectionCount)
        delays.initialize(repeating: 0)
    }

    deinit {
        coefficientBankA.deallocate()
        coefficientBankB.deallocate()
        delays.deallocate()
    }

    func update(coefficients: [Double], isEnabled: Bool) {
        let destination = activeBankIndex == 0 ? coefficientBankB : coefficientBankA
        let destinationIndex = activeBankIndex == 0 ? 1 : 0
        let hasExpectedCount = coefficients.count == sectionCount * 5
        var hasNonUnitySection = false

        for section in 0..<sectionCount {
            let destinationOffset = section * 5
            guard hasExpectedCount,
                  Self.isStableSection(coefficients, offset: destinationOffset) else {
                Self.writeUnity(to: destination, offset: destinationOffset)
                continue
            }
            for coefficient in 0..<5 {
                let value = coefficients[destinationOffset + coefficient]
                destination[destinationOffset + coefficient] = value
                if abs(value - CoreAudioBiquadMath.unityCoefficients[coefficient]) > 1.0e-12 {
                    hasNonUnitySection = true
                }
            }
        }

        let enabled = isEnabled && hasNonUnitySection
        if destinationIndex == 0 {
            bankAEnabled = enabled
        } else {
            bankBEnabled = enabled
        }
        activeBankIndex = destinationIndex
    }

    func resetDelayBuffers() {
        memset(
            delays.baseAddress,
            0,
            delays.count * MemoryLayout<Double>.stride
        )
    }

    @inline(__always)
    func renderSnapshot() -> CoreAudioBiquadRenderSnapshot {
        if activeBankIndex == 0 {
            return CoreAudioBiquadRenderSnapshot(
                coefficients: UnsafePointer(coefficientBankA.baseAddress!),
                isEnabled: bankAEnabled
            )
        }
        return CoreAudioBiquadRenderSnapshot(
            coefficients: UnsafePointer(coefficientBankB.baseAddress!),
            isEnabled: bankBEnabled
        )
    }

    @inline(__always)
    func processSample(
        _ input: Float,
        channel: Int,
        snapshot: CoreAudioBiquadRenderSnapshot
    ) -> Float {
        guard channel >= 0, channel < channelCount, input.isFinite else {
            if channel >= 0, channel < channelCount { resetDelayBuffers(for: channel) }
            return 0
        }
        guard snapshot.isEnabled else { return input }

        var sample = Double(input)
        let channelDelayOffset = channel * sectionCount * 2
        for section in 0..<sectionCount {
            let coefficientOffset = section * 5
            let delayOffset = channelDelayOffset + section * 2
            let coefficients = snapshot.coefficients

            let output = coefficients[coefficientOffset] * sample + delays[delayOffset]
            let delay1 = coefficients[coefficientOffset + 1] * sample
                - coefficients[coefficientOffset + 3] * output
                + delays[delayOffset + 1]
            let delay2 = coefficients[coefficientOffset + 2] * sample
                - coefficients[coefficientOffset + 4] * output

            guard output.isFinite, delay1.isFinite, delay2.isFinite else {
                resetDelayBuffers(for: channel)
                return 0
            }
            delays[delayOffset] = Self.flushDenormal(delay1)
            delays[delayOffset + 1] = Self.flushDenormal(delay2)
            sample = Self.flushDenormal(output)
        }
        guard sample.isFinite,
              abs(sample) <= Double(Float.greatestFiniteMagnitude) else {
            resetDelayBuffers(for: channel)
            return 0
        }
        let result = Float(sample)
        return result.isFinite ? result : 0
    }

    /// Convenience interleaved entry point used by focused DSP tests. The
    /// production callback uses `processSample` while walking arbitrary ABLs.
    func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        let snapshot = renderSnapshot()
        let sampleCount = frameCount * channelCount
        guard snapshot.isEnabled else {
            if input != UnsafePointer(output) {
                memmove(output, input, sampleCount * MemoryLayout<Float>.stride)
            }
            return
        }

        for frame in 0..<frameCount {
            let frameOffset = frame * channelCount
            for channel in 0..<channelCount {
                output[frameOffset + channel] = processSample(
                    input[frameOffset + channel],
                    channel: channel,
                    snapshot: snapshot
                )
            }
        }
    }

    var storageFingerprint: (coefficientsA: UInt, coefficientsB: UInt, delays: UInt) {
        (
            UInt(bitPattern: coefficientBankA.baseAddress!),
            UInt(bitPattern: coefficientBankB.baseAddress!),
            UInt(bitPattern: delays.baseAddress!)
        )
    }

    @inline(__always)
    private func resetDelayBuffers(for channel: Int) {
        let offset = channel * sectionCount * 2
        memset(
            delays.baseAddress! + offset,
            0,
            sectionCount * 2 * MemoryLayout<Double>.stride
        )
    }

    @inline(__always)
    private static func flushDenormal(_ value: Double) -> Double {
        abs(value) < denormalThreshold ? 0 : value
    }

    private static func initializeUnity(
        _ destination: UnsafeMutableBufferPointer<Double>,
        sectionCount: Int
    ) {
        for section in 0..<sectionCount {
            writeUnity(to: destination, offset: section * 5)
        }
    }

    private static func writeUnity(
        to destination: UnsafeMutableBufferPointer<Double>,
        offset: Int
    ) {
        for index in 0..<5 {
            destination[offset + index] = CoreAudioBiquadMath.unityCoefficients[index]
        }
    }

    private static func isStableSection(_ coefficients: [Double], offset: Int) -> Bool {
        let section = (0..<5).map { coefficients[offset + $0] }
        guard section.allSatisfy({
            $0.isFinite && abs($0) <= coefficientMagnitudeLimit
        }) else { return false }

        let a1 = section[3]
        let a2 = section[4]
        let margin = 1.0e-9
        return abs(a2) < 1 - margin
            && a1 < 1 + a2 - margin
            && a1 > -1 - a2 + margin
    }
}
