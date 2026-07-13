import CoreAudio
import XCTest
@testable import EQMacRep

final class CoreAudioAggregateDeviceBuilderTests: XCTestCase {
    func testSingleOutputAggregateDescriptionIncludesOutputAndTap() {
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
        XCTAssertEqual(description[kAudioAggregateDeviceIsStackedKey] as? Bool, false)

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
    }
}
