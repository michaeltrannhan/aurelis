import XCTest
@testable import Auralis

final class VolumeHUDStateTests: XCTestCase {
    func testHUDStateClampsVolumeAndRoundsPercent() {
        XCTAssertEqual(VolumeHUDState(appName: "Music", volume: 2, isMuted: false).volume, 1)
        XCTAssertEqual(VolumeHUDState(appName: "Music", volume: -1, isMuted: false).volume, 0)
        XCTAssertEqual(VolumeHUDState(appName: "Music", volume: .nan, isMuted: false).volume, 0)
        XCTAssertEqual(VolumeHUDState(appName: "Music", volume: 0.555, isMuted: false).percent, 56)
    }

    func testPeakTrackerInitializesHoldsAndResetsAcrossSources() {
        var tracker = VolumeHUDPeakTracker()

        XCTAssertEqual(
            tracker.update(for: VolumeHUDState(appName: "Music", volume: 0.8, isMuted: false)),
            0.8,
            accuracy: 0.0001
        )
        XCTAssertGreaterThan(
            tracker.update(for: VolumeHUDState(appName: "Music", volume: 0.4, isMuted: false)),
            0.4
        )
        XCTAssertEqual(
            tracker.update(for: VolumeHUDState(appName: "Browser", volume: 0.3, isMuted: false)),
            0.3,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            tracker.update(for: VolumeHUDState(appName: "Browser", volume: 0.3, isMuted: true)),
            0,
            accuracy: 0.0001
        )
    }
}
