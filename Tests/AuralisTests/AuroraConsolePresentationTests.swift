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

    func testDesktopInspectorClaimsMoreSpaceWithoutCrowdingTheProcessLane() {
        XCTAssertEqual(AuralisSpacing.inspectorWidth(for: 1_080), 500)
        XCTAssertEqual(AuralisSpacing.inspectorWidth(for: 1_180), 519.2, accuracy: 0.001)
        XCTAssertEqual(AuralisSpacing.inspectorWidth(for: 2_000), 620)
        XCTAssertEqual(AuralisSpacing.inspectorWidth(for: .nan), 500)
    }

    func testOutputDeckTransportAppearsOnlyForMeasuredOverflow() {
        let fourCardWidth = (4 * OutputDeckPagingModel.cardWidth)
            + (3 * OutputDeckPagingModel.cardSpacing)
        let fiveCardWidth = (5 * OutputDeckPagingModel.cardWidth)
            + (4 * OutputDeckPagingModel.cardSpacing)

        let fits = OutputDeckPagingModel(itemCount: 5, viewportWidth: fiveCardWidth)
        XCTAssertFalse(fits.isOverflowing)
        XCTAssertEqual(fits.maximumLeadingIndex, 0)

        let overflow = OutputDeckPagingModel(itemCount: 5, viewportWidth: fourCardWidth)
        XCTAssertTrue(overflow.isOverflowing)
        XCTAssertEqual(overflow.visibleItemCount, 4)
        XCTAssertEqual(overflow.maximumLeadingIndex, 1)
        XCTAssertEqual(overflow.visibleRangeLabel(from: 0), "1–4 / 5")
        XCTAssertEqual(overflow.visibleRangeLabel(from: overflow.nextIndex(from: 0)), "2–5 / 5")
    }

    func testDockedOutputPagerLeadsWithDefaultAndRetainsSpecificSelection() {
        let pager = OutputDevicePagerModel(
            deviceIDs: ["usb", "built-in", "usb", "display"],
            defaultDeviceID: "built-in",
            selectedDeviceID: "display"
        )

        XCTAssertEqual(pager.deviceIDs, ["built-in", "usb", "display"])
        XCTAssertEqual(pager.selectedDeviceID, "display")
        XCTAssertEqual(pager.position, 3)
        XCTAssertEqual(pager.previousDeviceID, "usb")
        XCTAssertNil(pager.nextDeviceID)

        let fallback = OutputDevicePagerModel(
            deviceIDs: pager.deviceIDs,
            defaultDeviceID: "built-in",
            selectedDeviceID: "missing"
        )
        XCTAssertEqual(fallback.selectedDeviceID, "built-in")
        XCTAssertEqual(fallback.nextDeviceID, "usb")
    }
}
