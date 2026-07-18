import XCTest
@testable import Auralis

final class VolumeHUDStateTests: XCTestCase {
    func testHUDStateClampsVolume() {
        let state = VolumeHUDState(appName: "Music", volume: 2, isMuted: false)

        XCTAssertEqual(state.volume, 1)
    }

    func testHUDStateClampsNegativeAndNonFinite() {
        XCTAssertEqual(VolumeHUDState(appName: "Music", volume: -1, isMuted: false).volume, 0)
        XCTAssertEqual(VolumeHUDState(appName: "Music", volume: .nan, isMuted: false).volume, 0)
    }

    func testPercentRounds() {
        XCTAssertEqual(VolumeHUDState(appName: "Music", volume: 0.555, isMuted: false).percent, 56)
    }
}
