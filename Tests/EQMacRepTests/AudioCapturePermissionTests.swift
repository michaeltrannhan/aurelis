import XCTest
@testable import EQMacRep

final class AudioCapturePermissionTests: XCTestCase {
    func testMissingUsageDescriptionBlocksTapAttempt() {
        let state = AudioCapturePermissionState(
            screenCapture: .granted,
            audioUsageDescription: .missing
        )

        XCTAssertFalse(state.allowsProcessTaps)
        XCTAssertEqual(state.summary, "Audio capture usage description missing")
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
}
