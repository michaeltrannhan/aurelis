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
}
