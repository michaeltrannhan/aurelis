import XCTest
@testable import EQMacRep

final class CustomizationTests: XCTestCase {
    func testDefaultVolumeIsClampedToUnitRange() {
        XCTAssertEqual(AppCustomization(defaultNewAppVolume: -0.5).defaultNewAppVolume, 0)
        XCTAssertEqual(AppCustomization(defaultNewAppVolume: 0.42).defaultNewAppVolume, 0.42)
        XCTAssertEqual(AppCustomization(defaultNewAppVolume: 2).defaultNewAppVolume, 1)
        XCTAssertEqual(AppCustomization(defaultNewAppVolume: .nan).defaultNewAppVolume, 1)
    }

    func testPopupDensityDimensionsScalePredictably() {
        XCTAssertLessThan(PopupDensity.compact.dimensions.width, PopupDensity.comfortable.dimensions.width)
        XCTAssertLessThan(PopupDensity.comfortable.dimensions.width, PopupDensity.spacious.dimensions.width)
        XCTAssertLessThan(PopupDensity.compact.dimensions.rowHeight, PopupDensity.spacious.dimensions.rowHeight)
    }

    func testVolumeStepFractions() {
        XCTAssertEqual(VolumeStep.onePercent.fraction, 0.01, accuracy: 0.0001)
        XCTAssertEqual(VolumeStep.twoPercent.fraction, 0.02, accuracy: 0.0001)
        XCTAssertEqual(VolumeStep.fivePercent.fraction, 0.05, accuracy: 0.0001)
        XCTAssertEqual(VolumeStep.tenPercent.fraction, 0.10, accuracy: 0.0001)
    }
}
