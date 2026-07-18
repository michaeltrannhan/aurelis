import XCTest
@testable import EQMacRep

final class MultiOutputRoutePickerTests: XCTestCase {
    private let devices = [
        AudioDeviceSnapshot(id: "built-in", name: "MacBook Speakers", isDefault: true),
        AudioDeviceSnapshot(id: "usb", name: "USB DAC"),
        AudioDeviceSnapshot(id: "hdmi", name: "Display Audio")
    ]

    func testInitialDraftNormalizesDuplicatesWithoutChangingPriority() {
        let model = MultiOutputRoutePickerModel(
            route: .multiOutput(["usb", "usb", "built-in", "hdmi", "built-in"])
        )

        XCTAssertEqual(model.originalRoute, .multiOutput(["usb", "built-in", "hdmi"]))
        XCTAssertEqual(model.draftRoute, .multiOutput(["usb", "built-in", "hdmi"]))
        XCTAssertEqual(model.multiOutputDeviceIDs, ["usb", "built-in", "hdmi"])
        XCTAssertFalse(model.hasChanges)
    }

    func testTogglesAreStagedInDeterministicSelectionOrder() {
        var model = MultiOutputRoutePickerModel(route: .followDefault)

        model.toggleMultiOutputDevice("usb")
        model.toggleMultiOutputDevice("built-in")
        model.toggleMultiOutputDevice("hdmi")
        model.toggleMultiOutputDevice("built-in")
        model.toggleMultiOutputDevice("built-in")

        XCTAssertEqual(model.draftRoute, .multiOutput(["usb", "hdmi", "built-in"]))
        XCTAssertEqual(model.multiOutputSelectionIndex(for: "usb"), 0)
        XCTAssertEqual(model.multiOutputSelectionIndex(for: "hdmi"), 1)
        XCTAssertEqual(model.multiOutputSelectionIndex(for: "built-in"), 2)
        XCTAssertTrue(model.hasChanges)
    }

    func testRemovingLastMultiOutputNormalizesToFollowDefault() {
        var model = MultiOutputRoutePickerModel(route: .multiOutput(["usb"]))

        model.toggleMultiOutputDevice("usb")

        XCTAssertEqual(model.draftRoute, .followDefault)
        XCTAssertTrue(model.multiOutputDeviceIDs.isEmpty)
        XCTAssertTrue(model.hasChanges)
    }

    func testSelectedOutputsCanBeReorderedWithoutRemoveAndReadd() {
        var model = MultiOutputRoutePickerModel(route: .multiOutput(["usb", "built-in", "hdmi"]))

        XCTAssertTrue(model.moveMultiOutputDevice("built-in", .up))
        XCTAssertEqual(model.multiOutputDeviceIDs, ["built-in", "usb", "hdmi"])
        XCTAssertTrue(model.moveMultiOutputDevice("usb", .down))
        XCTAssertEqual(model.multiOutputDeviceIDs, ["built-in", "hdmi", "usb"])
        XCTAssertTrue(model.hasChanges)
    }

    func testPriorityMoveRejectsBoundsAndUnknownDevices() {
        var model = MultiOutputRoutePickerModel(route: .multiOutput(["usb", "hdmi"]))

        XCTAssertFalse(model.moveMultiOutputDevice("usb", .up))
        XCTAssertFalse(model.moveMultiOutputDevice("hdmi", .down))
        XCTAssertFalse(model.moveMultiOutputDevice("missing", .up))
        XCTAssertEqual(model.multiOutputDeviceIDs, ["usb", "hdmi"])
        XCTAssertFalse(model.hasChanges)
    }

    func testFollowDefaultAndSingleDeviceChoicesAreAlsoStaged() {
        var model = MultiOutputRoutePickerModel(route: .multiOutput(["usb", "hdmi"]))

        model.selectSingleDevice("built-in")
        XCTAssertEqual(model.draftRoute, .selectedDevice("built-in"))

        model.selectFollowDefault()
        XCTAssertEqual(model.draftRoute, .followDefault)
        XCTAssertTrue(model.hasChanges)
    }

    func testMissingSelectionsStayOrderedAndAppearInSummary() {
        let model = MultiOutputRoutePickerModel(
            route: .multiOutput(["usb", "missing-a", "built-in", "missing-b"])
        )

        XCTAssertEqual(
            model.missingMultiOutputDeviceIDs(devices: devices),
            ["missing-a", "missing-b"]
        )

        let summary = model.summary(devices: devices)
        XCTAssertEqual(summary.title, "4 Outputs")
        XCTAssertEqual(summary.detail, "Multi-Output (4 devices) · 2 missing")
        XCTAssertEqual(summary.selectedCount, 4)
        XCTAssertEqual(summary.missingCount, 2)
        XCTAssertTrue(summary.isMultiOutput)
        XCTAssertEqual(summary.accessibilityValue, "Multi-Output, 4 outputs, 2 missing")
    }

    func testCompactSummariesCoverDefaultSingleAndMissingRoutes() {
        let defaultSummary = MultiOutputRoutePickerModel.summary(
            for: .followDefault,
            devices: devices
        )
        XCTAssertEqual(defaultSummary.title, "MacBook Speakers")
        XCTAssertEqual(defaultSummary.detail, "Follow Default (MacBook Speakers)")
        XCTAssertEqual(defaultSummary.accessibilityValue, "Follow Default, MacBook Speakers")

        let singleSummary = MultiOutputRoutePickerModel.summary(
            for: .selectedDevice("usb"),
            devices: devices
        )
        XCTAssertEqual(singleSummary.title, "USB DAC")
        XCTAssertEqual(singleSummary.missingCount, 0)
        XCTAssertEqual(singleSummary.accessibilityValue, "Single output, USB DAC")

        let missingSummary = MultiOutputRoutePickerModel.summary(
            for: .selectedDevice("gone"),
            devices: devices
        )
        XCTAssertEqual(missingSummary.title, "Missing Device")
        XCTAssertEqual(missingSummary.missingCount, 1)
        XCTAssertEqual(missingSummary.accessibilityValue, "Selected output is missing")
    }

    func testAvailableDevicesAreDeduplicatedInDiscoveryOrder() {
        let duplicateDevices = [
            AudioDeviceSnapshot(id: "usb", name: "USB DAC"),
            AudioDeviceSnapshot(id: "", name: "Invalid"),
            AudioDeviceSnapshot(id: "built-in", name: "MacBook Speakers", isDefault: true),
            AudioDeviceSnapshot(id: "usb", name: "Duplicate USB")
        ]

        let uniqueDevices = MultiOutputRoutePickerModel.uniqueDevices(duplicateDevices)

        XCTAssertEqual(uniqueDevices.map(\.id), ["usb", "built-in"])
        XCTAssertEqual(uniqueDevices.map(\.name), ["USB DAC", "MacBook Speakers"])
    }
}
