import XCTest
@testable import Auralis

final class CoreAudioOutputChannelMapTests: XCTestCase {
    func testBuildMapsContiguousSlicesInRequestOrder() throws {
        let map = try CoreAudioOutputChannelMap.build(
            outputDeviceUIDs: ["a", "b", "c"],
            aggregateOutputChannelCount: 6,
            channelCountForUID: { _ in 2 }
        )

        XCTAssertEqual(map.slices, [
            .init(deviceUID: "a", channelOffset: 0, channelCount: 2),
            .init(deviceUID: "b", channelOffset: 2, channelCount: 2),
            .init(deviceUID: "c", channelOffset: 4, channelCount: 2),
        ])
        XCTAssertEqual(map.sliceIndex(containingChannel: 3), 1)
        XCTAssertEqual(map.totalChannelCount, 6)
    }

    func testBuildFailsWhenChannelSumMismatchesAggregate() {
        XCTAssertThrowsError(
            try CoreAudioOutputChannelMap.build(
                outputDeviceUIDs: ["a", "b"],
                aggregateOutputChannelCount: 5,
                channelCountForUID: { _ in 2 }
            )
        )
    }

    func testBuildFailsWhenDeviceHasNoChannels() {
        XCTAssertThrowsError(
            try CoreAudioOutputChannelMap.build(
                outputDeviceUIDs: ["silent"],
                aggregateOutputChannelCount: 0,
                channelCountForUID: { _ in 0 }
            )
        )
    }
}
