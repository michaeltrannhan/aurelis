import CoreAudio
import XCTest
@testable import EQMacRep

final class CoreAudioTapFailurePolicyTests: XCTestCase {
    func testDeviceMissingIsRecoverable() {
        XCTAssertEqual(
            CoreAudioTapFailurePolicy.classify(.deviceUnavailable),
            .recoverable("Output device unavailable")
        )
    }

    func testPermissionDeniedDisablesTapAttempts() {
        XCTAssertEqual(
            CoreAudioTapFailurePolicy.classify(.permissionDenied),
            .disabled("Screen & System Audio Recording permission denied")
        )
    }

    func testIncompatibleSampleRatesExplainTheSelectedRates() {
        let failure = CoreAudioTapStartFailure.incompatibleSampleRates([44_100, 48_000])
        XCTAssertEqual(
            CoreAudioTapFailurePolicy.classify(failure),
            .recoverable("Selected outputs use incompatible sample rates: 44100 Hz, 48000 Hz")
        )
        XCTAssertEqual(
            failure.localizedDescription,
            "Selected outputs use incompatible sample rates: 44100 Hz, 48000 Hz"
        )
    }

    func testInactiveOutputsNameTheDeviceUIDs() {
        XCTAssertEqual(
            CoreAudioTapFailurePolicy.classify(.inactiveOutputDevices(["usb", "hdmi"])),
            .recoverable("Core Audio could not activate output devices: usb, hdmi")
        )
    }

    func testUnsupportedAppCanBeIgnored() {
        XCTAssertEqual(
            CoreAudioTapFailurePolicy.classify(.unsupportedProcess),
            .unsupported("App cannot be tapped")
        )
    }

    func testOSStatusIsRecoverableWithOperation() {
        XCTAssertEqual(
            CoreAudioTapFailurePolicy.classify(.osStatus(-10863, operation: "Tap create")),
            .recoverable("Tap create failed with OSStatus -10863")
        )
    }
}
