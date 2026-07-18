import XCTest
@testable import Auralis

final class CoreAudioBiquadMathTests: XCTestCase {
    func testPeakingZeroGainCreatesPassthroughRelationship() {
        let coefficients = CoreAudioBiquadMath.peakingEQCoefficients(
            frequency: 1000,
            gainDB: 0,
            q: CoreAudioBiquadMath.graphicEQQ,
            sampleRate: 48000
        )

        XCTAssertEqual(coefficients.count, 5)
        XCTAssertEqual(coefficients[0], 1, accuracy: 0.000001)
        XCTAssertEqual(coefficients[1], coefficients[3], accuracy: 0.000001)
        XCTAssertEqual(coefficients[2], coefficients[4], accuracy: 0.000001)
    }

    func testAllBandsReturnsTenSections() {
        let coefficients = CoreAudioBiquadMath.coefficientsForEQCurve(EQCurve(), sampleRate: 48000)

        XCTAssertEqual(coefficients.count, EQCurve.bandCount * 5)
    }

    func testBandsAtOrAboveNyquistBypass() {
        var curve = EQCurve()
        curve.setGain(12, at: 9)

        let coefficients = CoreAudioBiquadMath.coefficientsForEQCurve(curve, sampleRate: 22050)
        let highBand = Array(coefficients.suffix(5))

        XCTAssertEqual(highBand, CoreAudioBiquadMath.unityCoefficients)
    }

    func testInvalidCoefficientInputsAndUnstableSnapshotsBypassSafely() {
        XCTAssertEqual(
            CoreAudioBiquadMath.peakingEQCoefficients(
                frequency: .nan,
                gainDB: .infinity,
                q: 0,
                sampleRate: .nan
            ),
            CoreAudioBiquadMath.unityCoefficients
        )
        XCTAssertEqual(
            CoreAudioBiquadMath.coefficientsForEQCurve(EQCurve(), sampleRate: .infinity),
            CoreAudioBiquadMath.unityCoefficientsForSections(EQCurve.bandCount)
        )

        let processor = CoreAudioBiquadProcessor(sectionCount: 1, channelCount: 1)
        processor.update(coefficients: [.nan, 0, 0, 8, 2], isEnabled: true)
        let input: [Float] = [0.25, -0.5]
        var output = Array(repeating: Float(9), count: input.count)
        input.withUnsafeBufferPointer { inputBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                processor.process(
                    input: inputBuffer.baseAddress!,
                    output: outputBuffer.baseAddress!,
                    frameCount: input.count
                )
            }
        }
        XCTAssertEqual(output, input)
    }
}
