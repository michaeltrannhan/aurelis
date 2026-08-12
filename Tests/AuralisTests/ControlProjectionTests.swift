import XCTest
@testable import Auralis

final class ControlProjectionTests: XCTestCase {
    func testAppVolumeUpAutoUnmutes() throws {
        let baseline = ControlProjectedState(
            volume: 0.5,
            isMuted: true,
            displayName: "Music"
        )

        let result = try ControlProjection.applying(
            .adjustVolume(0.05),
            to: baseline,
            target: .app(AudioAppIdentity(rawValue: "music"))
        )

        XCTAssertEqual(result.volume ?? -1, 0.55, accuracy: 0.0001)
        XCTAssertEqual(result.isMuted, false)
    }

    func testAppVolumeDownToZeroAutoMutes() throws {
        let baseline = ControlProjectedState(
            volume: 0.02,
            isMuted: false,
            displayName: "Music"
        )

        let result = try ControlProjection.applying(
            .adjustVolume(-0.05),
            to: baseline,
            target: .app(AudioAppIdentity(rawValue: "music"))
        )

        XCTAssertEqual(result.volume ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(result.isMuted, true)
    }

    func testUnsupportedTargetMutationIsRejectedBeforeExecution() {
        XCTAssertThrowsError(try ControlProjection.applying(
            .setRoute(.followDefault),
            to: ControlProjectedState(displayName: "Speakers"),
            target: .outputDevice("speakers")
        ))
    }
}
