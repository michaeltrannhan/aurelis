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
        XCTAssertEqual(
            DeviceRoute.multiOutput([" usb ", "\n", "usb", " hdmi "]).normalized,
            .multiOutput(["usb", "hdmi"])
        )
        XCTAssertEqual(DeviceRoute.selectedDevice("  ").normalized, .followDefault)
    }

    func testSettingsTabsExposeExpectedSections() {
        XCTAssertEqual(SettingsTab.allCases.map(\.label), ["General", "Audio", "Shortcuts", "About"])
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
            issueCount: 0,
            includesExpandedEQ: false,
            availableScreenHeight: 700
        )
        let expanded = PopupContentLayoutModel.contentHeight(
            dimensions: dimensions,
            rowCount: 1,
            includesPermissionBanner: false,
            issueCount: 0,
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
            issueCount: 0,
            includesExpandedEQ: false,
            availableScreenHeight: 700
        )
        let shortScreenWithEQ = PopupContentLayoutModel.contentHeight(
            dimensions: dimensions,
            rowCount: 1,
            includesPermissionBanner: false,
            issueCount: 0,
            includesExpandedEQ: true,
            availableScreenHeight: 420
        )

        XCTAssertEqual(manyRows, dimensions.maxContentHeight)
        // The output-volume section above the scroll view reserves
        // 1 row(28) + 0 spacing = 28pt of chrome; the short-screen
        // limit drops with it.
        XCTAssertEqual(shortScreenWithEQ, 280)
    }

    func testPopupContentHeightNeverExceedsExtremelyShortScreen() {
        let height = PopupContentLayoutModel.contentHeight(
            dimensions: PopupDensity.compact.dimensions,
            rowCount: 3,
            includesPermissionBanner: true,
            issueCount: 2,
            includesExpandedEQ: true,
            availableScreenHeight: 100,
            deviceCount: 2
        )

        XCTAssertEqual(height, 0)
        XCTAssertEqual(PopupContentLayoutModel.popupMaxHeight(availableScreenHeight: 100), 60)
    }

    func testScrollWheelStepClampsVolume() {
        XCTAssertEqual(ScrollWheelStepModel.nextValue(current: 0.5, logicalSteps: 1, step: 0.05), 0.55, accuracy: 0.0001)
        XCTAssertEqual(ScrollWheelStepModel.nextValue(current: 1, logicalSteps: 2, step: 0.05), 1, accuracy: 0.0001)
        XCTAssertEqual(ScrollWheelStepModel.nextValue(current: 0, logicalSteps: -1, step: 0.05), 0, accuracy: 0.0001)
        XCTAssertEqual(ScrollWheelStepModel.nextValue(current: 0.5, logicalSteps: 0, step: 0.05), 0.5, accuracy: 0.0001)
    }

    func testPreciseScrollDeltasAccumulateAndIgnoreIrrelevantEvents() {
        var accumulator = ScrollWheelAccumulator(preciseThreshold: 8)

        XCTAssertEqual(accumulator.consume(deltaX: 0, deltaY: -2, hasPreciseDeltas: true), 0)
        XCTAssertEqual(accumulator.consume(deltaX: 0, deltaY: -3, hasPreciseDeltas: true), 0)
        XCTAssertEqual(accumulator.consume(deltaX: 0, deltaY: -3, hasPreciseDeltas: true), 1)
        XCTAssertEqual(accumulator.accumulatedDeltaY, 0)
        XCTAssertEqual(accumulator.consume(deltaX: 5, deltaY: 1, hasPreciseDeltas: true), 0)
        XCTAssertEqual(accumulator.consume(deltaX: 0, deltaY: 0, hasPreciseDeltas: true), 0)
        XCTAssertEqual(accumulator.consume(deltaX: 0, deltaY: .nan, hasPreciseDeltas: true), 0)
    }

    func testDiscreteScrollEventsProduceOneLogicalStepAndResetClearsRemainder() {
        var accumulator = ScrollWheelAccumulator(preciseThreshold: 8)

        XCTAssertEqual(accumulator.consume(deltaX: 0, deltaY: -0.1, hasPreciseDeltas: false), 1)
        XCTAssertEqual(accumulator.consume(deltaX: 0, deltaY: 2, hasPreciseDeltas: false), -1)
        _ = accumulator.consume(deltaX: 0, deltaY: -4, hasPreciseDeltas: true)
        accumulator.reset()
        XCTAssertEqual(accumulator.accumulatedDeltaY, 0)
    }

    func testControlSettingsDefaultToEnabledSafeValues() {
        let customization = AppCustomization()

        XCTAssertTrue(customization.mediaKeysEnabled)
        XCTAssertTrue(customization.hotkeysEnabled)
        XCTAssertEqual(customization.menuBarIconStyle, .speaker)
    }

    func testOutputControlPresentationUsesExplicitCapabilities() {
        let unavailable = OutputControlPresentation(capabilities: .unavailable)
        XCTAssertFalse(unavailable.showsVolume)
        XCTAssertFalse(unavailable.enablesVolume)
        XCTAssertFalse(unavailable.showsMute)
        XCTAssertFalse(unavailable.enablesMute)

        let readOnly = OutputControlPresentation(capabilities: OutputControlCapabilities(
            canReadVolume: true,
            canSetVolume: false,
            canReadMute: true,
            canSetMute: false
        ))
        XCTAssertTrue(readOnly.showsVolume)
        XCTAssertFalse(readOnly.enablesVolume)
        XCTAssertTrue(readOnly.showsMute)
        XCTAssertFalse(readOnly.enablesMute)

        let controllable = OutputControlPresentation(capabilities: .controllable)
        XCTAssertTrue(controllable.enablesVolume)
        XCTAssertTrue(controllable.enablesMute)
    }

    func testShortcutActionsHaveDefaultBindings() {
        XCTAssertEqual(ShortcutAction.allCases.map(\.label), ["Show Mixer", "Volume Up", "Volume Down", "Mute"])
        XCTAssertEqual(ShortcutAction.targetAppVolumeUp.defaultBinding.keyCode, 126)
    }

    func testEveryIssueRecoveryActionHasVisibleCopy() {
        let app = AudioAppIdentity(rawValue: "com.example.Music")
        let actions: [AudioRecoveryAction] = [
            .retry,
            .retryExternalControls,
            .requestAudioPermission,
            .openAudioPrivacySettings,
            .requestAccessibilityPermission,
            .openAccessibilitySettings,
            .followDefaultOutput(app),
            .ignoreApp(app)
        ]

        XCTAssertEqual(actions.map(AudioIssuePresentationModel.recoveryTitle), [
            "Retry",
            "Retry Controls",
            "Request Access",
            "Open Settings",
            "Request Accessibility",
            "Open Settings",
            "Use Default Output",
            "Ignore App"
        ])
    }

    func testPermissionCardHidesOnlyItsDuplicateIssue() {
        let permission = AudioIssue(
            id: "audio-permission",
            domain: .permission,
            severity: .warning,
            affectedApp: nil,
            affectedDeviceID: nil,
            message: "Permission",
            recovery: .requestAudioPermission
        )
        let backend = AudioIssue(
            id: "backend",
            domain: .backend,
            severity: .error,
            affectedApp: nil,
            affectedDeviceID: nil,
            message: "Backend",
            recovery: .retry
        )
        let state = AudioCapturePermissionState(
            screenCapture: .denied,
            audioUsageDescription: .present
        )

        XCTAssertEqual(
            AudioIssuePresentationModel.visibleIssues(
                [permission, backend],
                permissionState: state,
                hidesAudioPermissionIssue: true
            ).map(\.id),
            ["backend"]
        )
    }
}
