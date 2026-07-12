import XCTest
@testable import EQMacRep

final class AppControlCommandExecutorTests: XCTestCase {
    func testVolumeUpAutoUnmutes() {
        let result = AppControlCommandExecutor.nextSettings(
            settings: AppAudioSettings(displayName: "Music", volume: 0.5, isMuted: true),
            action: .volumeUp,
            step: 0.05
        )

        XCTAssertEqual(result.volume, 0.55, accuracy: 0.0001)
        XCTAssertFalse(result.isMuted)
    }

    func testVolumeDownClampsAtZeroAndMutes() {
        let result = AppControlCommandExecutor.nextSettings(
            settings: AppAudioSettings(displayName: "Music", volume: 0.02, isMuted: false),
            action: .volumeDown,
            step: 0.05
        )

        XCTAssertEqual(result.volume, 0, accuracy: 0.0001)
        XCTAssertTrue(result.isMuted)
    }

    func testMuteToggleFlips() {
        let result = AppControlCommandExecutor.nextSettings(
            settings: AppAudioSettings(displayName: "Music", volume: 0.5, isMuted: false),
            action: .muteToggle,
            step: 0.05
        )

        XCTAssertTrue(result.isMuted)
    }
}
