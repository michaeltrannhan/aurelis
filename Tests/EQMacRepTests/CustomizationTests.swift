import XCTest
@testable import EQMacRep

final class CustomizationTests: XCTestCase {
    func testDefaultVolumeIsClampedToUnitRange() {
        XCTAssertEqual(AppCustomization(defaultNewAppVolume: -0.5).defaultNewAppVolume, 0)
        XCTAssertEqual(AppCustomization(defaultNewAppVolume: 0.42).defaultNewAppVolume, 0.42)
        XCTAssertEqual(AppCustomization(defaultNewAppVolume: 2).defaultNewAppVolume, 1)
        XCTAssertEqual(AppCustomization(defaultNewAppVolume: .nan).defaultNewAppVolume, 1)
    }

    func testPopupDensityDimensionsScalePredictably() {
        XCTAssertLessThan(PopupDensity.compact.dimensions.width, PopupDensity.comfortable.dimensions.width)
        XCTAssertLessThan(PopupDensity.comfortable.dimensions.width, PopupDensity.spacious.dimensions.width)
        XCTAssertLessThan(PopupDensity.compact.dimensions.rowHeight, PopupDensity.spacious.dimensions.rowHeight)
    }

    func testPopupDensityWidthsStayCompactAndEQUsable() {
        XCTAssertEqual(PopupDensity.compact.collapsedWidth, 300)
        XCTAssertEqual(PopupDensity.comfortable.collapsedWidth, 320)
        XCTAssertEqual(PopupDensity.spacious.collapsedWidth, 340)
        XCTAssertEqual(PopupDensity.compact.dimensions.width, 360)
        XCTAssertEqual(PopupDensity.comfortable.dimensions.width, 400)
        XCTAssertEqual(PopupDensity.spacious.dimensions.width, 440)
        XCTAssertLessThan(PopupDensity.spacious.collapsedWidth, PopupDensity.compact.dimensions.width)
        XCTAssertGreaterThanOrEqual(PopupDensity.compact.dimensions.width, 360)
        XCTAssertLessThanOrEqual(PopupDensity.spacious.dimensions.width, 440)
    }

    func testVolumeStepFractions() {
        XCTAssertEqual(VolumeStep.onePercent.fraction, 0.01, accuracy: 0.0001)
        XCTAssertEqual(VolumeStep.twoPercent.fraction, 0.02, accuracy: 0.0001)
        XCTAssertEqual(VolumeStep.fivePercent.fraction, 0.05, accuracy: 0.0001)
        XCTAssertEqual(VolumeStep.tenPercent.fraction, 0.10, accuracy: 0.0001)
    }

    func testDefaultBackendModeIsCoreAudioDiscovery() {
        XCTAssertEqual(AppCustomization().backendMode, .coreAudioDiscovery)
    }

    func testDeviceRouteLabelsUseAvailableDevices() {
        let devices = [
            AudioDeviceSnapshot(id: "built-in-output", name: "MacBook Speakers", isDefault: true),
            AudioDeviceSnapshot(id: "usb", name: "USB DAC")
        ]

        XCTAssertEqual(DeviceRoute.followDefault.label(devices: devices), "Follow Default (MacBook Speakers)")
        XCTAssertEqual(DeviceRoute.selectedDevice("usb").label(devices: devices), "USB DAC")
        XCTAssertEqual(DeviceRoute.selectedDevice("missing").label(devices: devices), "Missing Device")
        XCTAssertEqual(DeviceRoute.multiOutput(["usb", "built-in-output"]).label(devices: devices), "Multi-Output (2 devices)")
    }

    func testMultiOutputRouteNormalizesDuplicatesAndEmptySelection() {
        XCTAssertEqual(
            DeviceRoute.multiOutput(["usb", "usb", "built-in", "usb"]).normalized,
            .multiOutput(["usb", "built-in"])
        )
        XCTAssertEqual(DeviceRoute.multiOutput([]).normalized, .followDefault)
        XCTAssertEqual(DeviceRoute.multiOutput(["", "usb", ""]).normalized, .multiOutput(["usb"]))
    }

    func testSettingsTabsExposeExpectedSections() {
        XCTAssertEqual(SettingsTab.allCases.map(\.label), ["General", "Audio", "Shortcuts", "Updates", "About"])
        XCTAssertEqual(SettingsTab.general.systemImage, "gearshape")
        XCTAssertEqual(SettingsTab.audio.systemImage, "speaker.wave.2")
    }

    func testPopupDimensionsIncludeMaxContentHeight() {
        XCTAssertLessThan(PopupDensity.compact.dimensions.maxContentHeight, PopupDensity.spacious.dimensions.maxContentHeight)
        XCTAssertGreaterThan(PopupDensity.comfortable.dimensions.maxContentHeight, 300)
    }

    func testPopupContentHeightUsesIntrinsicRowAndExpandedEQSizes() {
        let dimensions = PopupDensity.comfortable.dimensions
        let collapsed = PopupContentLayoutModel.contentHeight(
            dimensions: dimensions,
            rowCount: 1,
            includesPermissionBanner: false,
            includesIssueBanner: false,
            includesExpandedEQ: false,
            availableScreenHeight: 700
        )
        let expanded = PopupContentLayoutModel.contentHeight(
            dimensions: dimensions,
            rowCount: 1,
            includesPermissionBanner: false,
            includesIssueBanner: false,
            includesExpandedEQ: true,
            availableScreenHeight: 700
        )

        XCTAssertEqual(collapsed, 122)
        XCTAssertEqual(expanded, 374)
        XCTAssertGreaterThan(expanded, collapsed)
    }

    func testPopupContentHeightHonorsDensityAndScreenLimits() {
        let dimensions = PopupDensity.comfortable.dimensions
        let manyRows = PopupContentLayoutModel.contentHeight(
            dimensions: dimensions,
            rowCount: 10,
            includesPermissionBanner: false,
            includesIssueBanner: false,
            includesExpandedEQ: false,
            availableScreenHeight: 700
        )
        let shortScreenWithEQ = PopupContentLayoutModel.contentHeight(
            dimensions: dimensions,
            rowCount: 1,
            includesPermissionBanner: false,
            includesIssueBanner: false,
            includesExpandedEQ: true,
            availableScreenHeight: 420
        )

        XCTAssertEqual(manyRows, dimensions.maxContentHeight)
        XCTAssertEqual(shortScreenWithEQ, 308)
    }

    func testScrollWheelStepClampsVolume() {
        XCTAssertEqual(ScrollWheelStepModel.nextValue(current: 0.5, deltaY: -1, step: 0.05), 0.55, accuracy: 0.0001)
        XCTAssertEqual(ScrollWheelStepModel.nextValue(current: 1, deltaY: -1, step: 0.05), 1, accuracy: 0.0001)
        XCTAssertEqual(ScrollWheelStepModel.nextValue(current: 0, deltaY: 1, step: 0.05), 0, accuracy: 0.0001)
    }

    func testControlSettingsDefaultToEnabledSafeValues() {
        let customization = AppCustomization()

        XCTAssertTrue(customization.mediaKeysEnabled)
        XCTAssertTrue(customization.hotkeysEnabled)
        XCTAssertEqual(customization.hudStyle, .compact)
        XCTAssertEqual(customization.menuBarIconStyle, .speaker)
    }

    func testShortcutActionsHaveDefaultBindings() {
        XCTAssertEqual(ShortcutAction.allCases.map(\.label), ["Toggle Popup", "Volume Up", "Volume Down", "Mute"])
        XCTAssertEqual(ShortcutAction.targetAppVolumeUp.defaultBinding.keyCode, 126)
    }
}
