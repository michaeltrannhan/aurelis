import XCTest
@testable import Auralis

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

    @MainActor
    func testCoordinatorPreservesEveryRapidRelativeStepInOrder() async {
        let app = AudioAppIdentity(rawValue: "com.example.Music")
        var visible = AppAudioSettings(displayName: "Music", volume: 0)
        var appliedVolumes: [Double] = []
        let coordinator = AppControlCommandCoordinator(
            currentSettings: { identity in identity == app ? visible : nil },
            publishProjection: { identity, settings in
                if identity == app { visible = settings }
            },
            apply: { identity, desired, _ in
                XCTAssertEqual(identity, app)
                appliedVolumes.append(desired.volume)
                return desired
            }
        )

        let receipts = (1...20).map { _ in
            coordinator.submit(action: .volumeUp, target: app, step: 0.01)
        }
        var results: [ControlResult] = []
        for receipt in receipts {
            results.append(await coordinator.result(for: receipt))
        }

        XCTAssertEqual(visible.volume, 0.2, accuracy: 0.0001)
        XCTAssertEqual(appliedVolumes.count, 20)
        XCTAssertEqual(try XCTUnwrap(appliedVolumes.first), 0.01, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(appliedVolumes.last), 0.2, accuracy: 0.0001)
        XCTAssertTrue(results.allSatisfy {
            if case .applied = $0 { return true }
            return false
        })
    }
}
