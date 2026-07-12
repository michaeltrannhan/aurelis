import XCTest
@testable import EQMacRep

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
}
