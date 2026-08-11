import XCTest
@testable import Auralis

final class AuroraConsolePresentationTests: XCTestCase {
    func testSignalPathBuilderNamesBothEQStagesAndFailureLocation() {
        let nodes = SignalPathBuilder.nodes(
            appName: "Music",
            volume: 0.8,
            isMuted: true,
            boost: .x2,
            outputName: "MacBook Speakers",
            failedAt: .gain
        )
        XCTAssertEqual(
            nodes.map(\.title),
            ["Music", "Process EQ", "Mute", "Output EQ", "MacBook Speakers"]
        )
        XCTAssertEqual(nodes[2].detail, "2x boost")
        XCTAssertTrue(nodes[2].isFailed)
        XCTAssertFalse(nodes[0].isFailed)
    }

    func testSignalPathBuilderExplainsMultiOutputFanoutAndActiveStage() {
        let nodes = SignalPathBuilder.nodes(
            appName: "Music",
            volume: 0.8,
            isMuted: false,
            boost: .x1,
            outputNames: ["USB DAC", "Studio Display"],
            activeStage: .output
        )

        XCTAssertEqual(nodes[3].title, "Output EQ ×2")
        XCTAssertTrue(nodes[3].isActive)
        XCTAssertEqual(nodes.last?.title, "2 outputs")
        XCTAssertEqual(nodes.last?.detail, "USB DAC + Studio Display")
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
