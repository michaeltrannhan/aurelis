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
