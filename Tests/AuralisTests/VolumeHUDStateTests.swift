import XCTest
@testable import Auralis

final class VolumeHUDStateTests: XCTestCase {
    func testHUDStateClampsVolumeAndRoundsPercent() {
        XCTAssertEqual(VolumeHUDState(appName: "Music", volume: 2, isMuted: false).volume, 1)
        XCTAssertEqual(VolumeHUDState(appName: "Music", volume: -1, isMuted: false).volume, 0)
        XCTAssertEqual(VolumeHUDState(appName: "Music", volume: .nan, isMuted: false).volume, 0)
        XCTAssertEqual(VolumeHUDState(appName: "Music", volume: 0.555, isMuted: false).percent, 56)
    }
}
