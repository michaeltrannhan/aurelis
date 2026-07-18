import XCTest
@testable import EQMacRep

final class EQCurveTests: XCTestCase {
    func testDecodingNormalizesShortMalformedAndNonfiniteBands() throws {
        let data = Data(
            """
            {
              "gains": ["NaN", 99, -99, 3.5, {"bad": true}],
              "range": 12
            }
            """.utf8
        )

        let curve = try JSONDecoder().decode(EQCurve.self, from: data)

        XCTAssertEqual(curve.gains, [0, 12, -12, 3.5, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(curve.range, .db12)
    }

    func testDecodingTruncatesLongBandsAndDefaultsInvalidRange() throws {
        let data = Data(
            """
            {
              "gains": [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12],
              "range": 999
            }
            """.utf8
        )

        let curve = try JSONDecoder().decode(EQCurve.self, from: data)

        XCTAssertEqual(curve.gains, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        XCTAssertEqual(curve.range, .db12)
    }

    func testNormalizesBandCountByPaddingMissingBands() {
        let curve = EQCurve(gains: [1, 2, 3], range: .db12)

        XCTAssertEqual(curve.gains.count, EQCurve.bandCount)
        XCTAssertEqual(Array(curve.gains.prefix(3)), [1, 2, 3])
        XCTAssertEqual(Array(curve.gains.dropFirst(3)), Array(repeating: 0, count: 7))
    }

    func testNormalizesBandCountByTruncatingExtraBands() {
        let curve = EQCurve(gains: Array(repeating: 2, count: 14), range: .db12)

        XCTAssertEqual(curve.gains.count, EQCurve.bandCount)
        XCTAssertEqual(curve.gains, Array(repeating: 2, count: 10))
    }

    func testClampsNonFiniteAndOutOfRangeGains() {
        let curve = EQCurve(
            gains: [-20, -12, -1, 0, 1, 12, 20, .infinity, -.infinity, .nan],
            range: .db12
        )

        XCTAssertEqual(curve.gains, [-12, -12, -1, 0, 1, 12, 12, 0, 0, 0])
    }

    func testChangingRangeReclampsExistingGains() {
        var curve = EQCurve(gains: [-18, -8, 0, 8, 18], range: .db18)

        curve.applyRange(.db6)

        XCTAssertEqual(curve.range, .db6)
        XCTAssertEqual(curve.gains, [-6, -6, 0, 6, 6, 0, 0, 0, 0, 0])
    }

    func testSetGainAndReset() {
        var curve = EQCurve()

        curve.setGain(30, at: 0)
        curve.setGain(-3, at: 9)
        curve.setGain(9, at: 99)

        XCTAssertEqual(curve.gains[0], 12)
        XCTAssertEqual(curve.gains[9], -3)

        curve.reset()

        XCTAssertEqual(curve.gains, Array(repeating: 0, count: EQCurve.bandCount))
    }
}
