import XCTest
@testable import EQMacRep

final class CoreAudioRealtimeGainTests: XCTestCase {
    func testEffectiveGainCombinesVolumeMuteAndBoost() {
        var state = CoreAudioRealtimeGainState(volume: 0.5, boost: .x3, isMuted: false)

        XCTAssertEqual(state.targetGain, 1.5, accuracy: 0.0001)

        state.isMuted = true

        XCTAssertEqual(state.targetGain, 0, accuracy: 0.0001)
    }

    func testRampMovesCurrentGainTowardTarget() {
        var ramp = CoreAudioGainRamp(currentGain: 1, coefficient: 0.5)

        let first = ramp.next(targetGain: 0)
        let second = ramp.next(targetGain: 0)

        XCTAssertEqual(first, 0.5, accuracy: 0.0001)
        XCTAssertEqual(second, 0.25, accuracy: 0.0001)
    }

    func testLimiterNeverExceedsOneForFiniteSamples() {
        XCTAssertEqual(CoreAudioSoftLimiter.apply(0.5), 0.5, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(abs(CoreAudioSoftLimiter.apply(4.0)), 1.0)
        XCTAssertLessThanOrEqual(abs(CoreAudioSoftLimiter.apply(-4.0)), 1.0)
    }

    func testProcessorAppliesGainAndLimiterToInterleavedSamples() {
        let input: [Float] = [0.25, -0.25, 0.75, -0.75]
        var output = Array(repeating: Float(0), count: input.count)
        var ramp = CoreAudioGainRamp(currentGain: 2, coefficient: 1)

        input.withUnsafeBufferPointer { inputBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                CoreAudioRealtimeGainProcessor.process(
                    input: inputBuffer.baseAddress!,
                    output: outputBuffer.baseAddress!,
                    sampleCount: input.count,
                    targetGain: 2,
                    ramp: &ramp
                )
            }
        }

        XCTAssertEqual(output[0], 0.5, accuracy: 0.0001)
        XCTAssertEqual(output[1], -0.5, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(abs(output[2]), 1.0)
        XCTAssertLessThanOrEqual(abs(output[3]), 1.0)
    }
}
