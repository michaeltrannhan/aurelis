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
