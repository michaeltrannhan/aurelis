import XCTest
@testable import Auralis

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

    func testInvalidRampInputsAreSanitizedAndTinyOutputsAreFlushed() {
        XCTAssertEqual(CoreAudioGainRamp.coefficient(sampleRate: .nan), 1)
        XCTAssertEqual(CoreAudioGainRamp.coefficient(sampleRate: 48_000, rampMilliseconds: .infinity), 1)

        var ramp = CoreAudioGainRamp(currentGain: .nan, coefficient: .nan)
        XCTAssertEqual(ramp.next(targetGain: .nan), 1)
        XCTAssertEqual(CoreAudioSoftLimiter.apply(.nan), 0)
        XCTAssertEqual(CoreAudioSoftLimiter.apply(1.0e-30), 0)
    }
}
