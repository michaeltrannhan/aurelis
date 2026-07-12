import XCTest
@testable import EQMacRep

final class MediaKeyEventDecoderTests: XCTestCase {
    func testDecodesVolumeUpDownAndMute() {
        let decoder = IOKitMediaKeyDecoder()

        XCTAssertEqual(decoder.decode(data1: Self.data1(keyType: 0, keyFlags: 0x0A00)), .volumeUp(isRepeat: false))
        XCTAssertEqual(decoder.decode(data1: Self.data1(keyType: 1, keyFlags: 0x0A01)), .volumeDown(isRepeat: true))
        XCTAssertEqual(decoder.decode(data1: Self.data1(keyType: 7, keyFlags: 0x0A00)), .muteToggle)
    }

    func testIgnoresKeyUpAndUnknownKeys() {
        let decoder = IOKitMediaKeyDecoder()

        XCTAssertNil(decoder.decode(data1: Self.data1(keyType: 0, keyFlags: 0x0B00)))
        XCTAssertNil(decoder.decode(data1: Self.data1(keyType: 99, keyFlags: 0x0A00)))
        XCTAssertNil(decoder.decode(data1: Self.data1(keyType: 7, keyFlags: 0x0A01)))
    }

    private static func data1(keyType: Int, keyFlags: Int) -> Int {
        (keyType << 16) | keyFlags
    }
}
