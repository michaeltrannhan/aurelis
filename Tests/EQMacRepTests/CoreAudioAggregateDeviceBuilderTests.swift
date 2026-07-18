import CoreAudio
import XCTest
@testable import EQMacRep

final class CoreAudioAggregateDeviceBuilderTests: XCTestCase {
    func testSingleOutputAggregateDescriptionIncludesOutputAndTap() throws {
        let tapUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!

        let description = CoreAudioAggregateDeviceBuilder.singleOutputDescription(
            outputDeviceUID: "built-in-output",
            tapUUID: tapUUID,
            appName: "Music"
        )

        XCTAssertEqual(description[kAudioAggregateDeviceMainSubDeviceKey] as? String, "built-in-output")
        XCTAssertEqual(description[kAudioAggregateDeviceClockDeviceKey] as? String, "built-in-output")
        XCTAssertEqual(description[kAudioAggregateDeviceIsPrivateKey] as? Bool, true)
        XCTAssertEqual(description[kAudioAggregateDeviceTapAutoStartKey] as? Bool, true)
        XCTAssertEqual(description[kAudioAggregateDeviceIsStackedKey] as? Bool, false)

        let taps = try XCTUnwrap(
            description[kAudioAggregateDeviceTapListKey] as? [[String: Any]]
        )
        XCTAssertEqual(taps.count, 1)
        XCTAssertEqual(taps[0][kAudioSubTapUIDKey] as? String, tapUUID.uuidString)
        XCTAssertEqual(taps[0][kAudioSubTapDriftCompensationKey] as? Bool, true)
    }

    func testMultiOutputAggregateIncludesAllSubdevicesWithFirstAsClock() throws {
        let tapUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000321")!

        let description = CoreAudioAggregateDeviceBuilder.multiOutputDescription(
            outputDeviceUIDs: ["usb", "hdmi", "airplay"],
            tapUUID: tapUUID,
            appName: "Music"
        )

        XCTAssertEqual(description[kAudioAggregateDeviceMainSubDeviceKey] as? String, "usb")
        XCTAssertEqual(description[kAudioAggregateDeviceClockDeviceKey] as? String, "usb")
        XCTAssertEqual(description[kAudioAggregateDeviceIsPrivateKey] as? Bool, true)
        XCTAssertEqual(description[kAudioAggregateDeviceIsStackedKey] as? Bool, true)

        let subdevices = try XCTUnwrap(
            description[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]]
        )
        XCTAssertEqual(subdevices.count, 3)
        XCTAssertEqual(subdevices[0][kAudioSubDeviceUIDKey] as? String, "usb")
        XCTAssertEqual(subdevices[0][kAudioSubDeviceDriftCompensationKey] as? Bool, false)
        XCTAssertEqual(subdevices[1][kAudioSubDeviceUIDKey] as? String, "hdmi")
        XCTAssertEqual(subdevices[1][kAudioSubDeviceDriftCompensationKey] as? Bool, true)
        XCTAssertEqual(subdevices[2][kAudioSubDeviceUIDKey] as? String, "airplay")
        XCTAssertEqual(subdevices[2][kAudioSubDeviceDriftCompensationKey] as? Bool, true)

        let taps = try XCTUnwrap(
            description[kAudioAggregateDeviceTapListKey] as? [[String: Any]]
        )
        XCTAssertEqual(taps[0][kAudioSubTapDriftCompensationKey] as? Bool, true)
    }
}
