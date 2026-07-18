import XCTest
@testable import Auralis

@MainActor
final class AudioCapturePermissionTests: XCTestCase {
    func testMissingUsageDescriptionBlocksTapAttempt() {
        let state = AudioCapturePermissionState(
            screenCapture: .granted,
            audioUsageDescription: .missing
        )

        XCTAssertFalse(state.allowsProcessTaps)
        XCTAssertEqual(state.summary, "Audio capture usage description missing")
    }

    func testMissingUsageDescriptionAlwaysSupersedesSystemSettingsActions() {
        for screenCapture in [
            ScreenCapturePermissionStatus.notDetermined,
            .denied,
            .pendingRestart,
            .granted
        ] {
            let presentation = PermissionPresentation(state: AudioCapturePermissionState(
                screenCapture: screenCapture,
                audioUsageDescription: .missing
            ))

            XCTAssertEqual(presentation.title, "Audio capture unavailable")
            XCTAssertNil(presentation.primary)
            XCTAssertNil(presentation.secondary)
            XCTAssertTrue(presentation.detail.contains("System Settings cannot repair it"))
        }
    }

    func testGrantedScreenCaptureAndUsageDescriptionAllowTaps() {
        let state = AudioCapturePermissionState(
            screenCapture: .granted,
            audioUsageDescription: .present
        )

        XCTAssertTrue(state.allowsProcessTaps)
        XCTAssertEqual(state.summary, "Audio capture ready")
    }

    func testDeniedScreenCaptureBlocksTaps() {
        let state = AudioCapturePermissionState(
            screenCapture: .denied,
            audioUsageDescription: .present
        )

        XCTAssertFalse(state.allowsProcessTaps)
        XCTAssertEqual(state.summary, "Screen & System Audio Recording denied")
    }

    func testNotDeterminedSummary() {
        let state = AudioCapturePermissionState(
            screenCapture: .notDetermined,
            audioUsageDescription: .present
        )

        XCTAssertFalse(state.allowsProcessTaps)
        XCTAssertEqual(state.summary, "Screen & System Audio Recording not requested")
    }

    func testPendingRestartBlocksTapsWithRelaunchSummary() {
        let state = AudioCapturePermissionState(
            screenCapture: .pendingRestart,
            audioUsageDescription: .present
        )

        XCTAssertFalse(state.allowsProcessTaps)
        XCTAssertEqual(state.summary, "Relaunch Auralis to finish enabling audio capture")
    }

    func testPrivacySettingsURLIsStable() {
        XCTAssertEqual(
            SystemAudioCapturePermissionClient.privacySettingsURL.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )
    }

    func testSystemClientReadsUsageDescriptionFromInfoDictionary() {
        let present = SystemAudioCapturePermissionClient(
            infoDictionary: ["NSAudioCaptureUsageDescription": "Because taps."]
        )
        let missing = SystemAudioCapturePermissionClient(infoDictionary: [:])

        XCTAssertEqual(present.currentState().audioUsageDescription, .present)
        XCTAssertEqual(missing.currentState().audioUsageDescription, .missing)
    }

    func testSystemClientClassifiesRejectedRequestAsDenied() {
        let client = SystemAudioCapturePermissionClient(
            infoDictionary: ["NSAudioCaptureUsageDescription": "Because taps."],
            preflightScreenCaptureAccess: { false },
            requestSystemScreenCaptureAccess: { false }
        )

        XCTAssertEqual(client.requestScreenCaptureAccess().screenCapture, .denied)
    }

    func testSystemClientClassifiesAcceptedInactiveGrantAsPendingRestart() {
        let client = SystemAudioCapturePermissionClient(
            infoDictionary: ["NSAudioCaptureUsageDescription": "Because taps."],
            preflightScreenCaptureAccess: { false },
            requestSystemScreenCaptureAccess: { true }
        )

        XCTAssertEqual(client.requestScreenCaptureAccess().screenCapture, .pendingRestart)
    }

    func testSystemClientClassifiesActiveGrantAsGranted() {
        let client = SystemAudioCapturePermissionClient(
            infoDictionary: ["NSAudioCaptureUsageDescription": "Because taps."],
            preflightScreenCaptureAccess: { true },
            requestSystemScreenCaptureAccess: { true }
        )

        XCTAssertEqual(client.requestScreenCaptureAccess().screenCapture, .granted)
    }

    func testCoordinatorKeepsDeniedStateAcrossAmbiguousPreflightRefresh() {
        let client = RejectedPermissionClient()
        let coordinator = AudioPermissionCoordinator(client: client)

        XCTAssertEqual(coordinator.requestAudioCapture().screenCapture, .denied)
        XCTAssertEqual(coordinator.refresh().screenCapture, .denied)
        XCTAssertEqual(coordinator.requirements.first?.state, .denied)
    }
}

private final class RejectedPermissionClient: AudioCapturePermissionClient {
    func currentState() -> AudioCapturePermissionState {
        .init(screenCapture: .notDetermined, audioUsageDescription: .present)
    }

    func requestScreenCaptureAccess() -> AudioCapturePermissionState {
        .init(screenCapture: .denied, audioUsageDescription: .present)
    }

    func openPrivacySettings() {}
    func relaunchApp() async throws {}
}
