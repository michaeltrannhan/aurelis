import XCTest
@testable import Auralis

final class AuroraConsolePresentationTests: XCTestCase {
    func testSignalPathBuilderMatchesMusicMuteEQBoostOutputStory() {
        let nodes = SignalPathBuilder.nodes(
            appName: "Music",
            volume: 0.8,
            isMuted: true,
            boost: .x2,
            outputName: "MacBook Speakers",
            failedAt: .gain
        )
        XCTAssertEqual(nodes.map(\.title), ["Music", "Mute", "EQ", "2x", "MacBook Speakers"])
        XCTAssertTrue(nodes[1].isFailed)
        XCTAssertFalse(nodes[0].isFailed)
    }

    func testMixerEmptyStateMapsPhases() {
        XCTAssertEqual(MixerEmptyState(phase: .permissionLimited).title, "Audio permission required")
        XCTAssertEqual(MixerEmptyState(phase: .failed).title, "Couldn’t load apps")
        XCTAssertEqual(MixerEmptyState(phase: .empty), .readyEmpty)
    }

    func testSettingsTabsUseAuroraLabels() {
        XCTAssertEqual(SettingsTab.shortcuts.label, "Controls")
        XCTAssertEqual(SettingsTab.about.label, "About & diagnostics")
    }
}
