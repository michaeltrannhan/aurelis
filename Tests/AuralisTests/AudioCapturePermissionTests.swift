import XCTest
@testable import Auralis

@MainActor
final class AudioCapturePermissionTests: XCTestCase {
    func testPermissionSummariesAndTapGating() {
        let missing = AudioCapturePermissionState(
            screenCapture: .granted,
            audioUsageDescription: .missing
        )
        XCTAssertFalse(missing.allowsProcessTaps)
        XCTAssertEqual(missing.summary, "Audio capture usage description missing")

        let granted = AudioCapturePermissionState(
            screenCapture: .granted,
            audioUsageDescription: .present
        )
        XCTAssertTrue(granted.allowsProcessTaps)
        XCTAssertEqual(granted.summary, "Audio capture ready")

        let denied = AudioCapturePermissionState(
            screenCapture: .denied,
            audioUsageDescription: .present
        )
        XCTAssertFalse(denied.allowsProcessTaps)
        XCTAssertEqual(denied.summary, "Screen & System Audio Recording denied")

        let notDetermined = AudioCapturePermissionState(
            screenCapture: .notDetermined,
            audioUsageDescription: .present
        )
        XCTAssertFalse(notDetermined.allowsProcessTaps)
        XCTAssertEqual(notDetermined.summary, "Screen & System Audio Recording not requested")

        let pending = AudioCapturePermissionState(
            screenCapture: .pendingRestart,
            audioUsageDescription: .present
        )
        XCTAssertFalse(pending.allowsProcessTaps)
        XCTAssertEqual(pending.summary, "Relaunch Auralis to finish enabling audio capture")
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
