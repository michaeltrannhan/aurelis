import XCTest
@testable import Auralis

final class MenuBarIconStateTests: XCTestCase {
    func testMenuBarIconVolumeBuckets() {
        XCTAssertEqual(VolumeBucket.bucket(for: 0), .zero)
        XCTAssertEqual(VolumeBucket.bucket(for: 0.2), .low)
        XCTAssertEqual(VolumeBucket.bucket(for: 0.5), .mid)
        XCTAssertEqual(VolumeBucket.bucket(for: 0.9), .high)
    }

    func testSpeakerStyleReflectsMuteAndBuckets() {
        XCTAssertEqual(MenuBarIconState.symbolName(style: .speaker, volume: 0.5, isMuted: true), "speaker.slash.fill")
        XCTAssertEqual(MenuBarIconState.symbolName(style: .speaker, volume: 0.2, isMuted: false), "speaker.wave.1.fill")
        XCTAssertEqual(MenuBarIconState.symbolName(style: .speaker, volume: 0.9, isMuted: false), "speaker.wave.3.fill")
    }

    func testWaveformStyleReflectsMute() {
        XCTAssertEqual(MenuBarIconState.symbolName(style: .waveform, volume: 0.5, isMuted: true), "waveform.slash")
        XCTAssertEqual(MenuBarIconState.symbolName(style: .waveform, volume: 0.5, isMuted: false), "waveform")
    }
}
