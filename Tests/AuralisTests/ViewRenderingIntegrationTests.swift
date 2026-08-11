import AppKit
import SwiftUI
import XCTest
@testable import Auralis

@MainActor
final class ViewRenderingIntegrationTests: XCTestCase {
    func testLargePopupRendersToBoundedBitmapWithProductionViewHierarchy() async throws {
        let settingsURL = temporaryFileURL(prefix: "AuralisRendering", filename: "settings.json")
        var settings = PersistedSettings(hasCompletedOnboarding: true)
        settings.customization.popupDensity = .compact
        try SettingsStore(settingsURL: settingsURL).save(settings)
        let apps = (0..<50).map { index in
            AudioAppSnapshot(
                identity: AudioAppIdentity(rawValue: "app-\(index)"),
                displayName: "Application \(index)",
                isActive: true,
                level: Double(index % 10) / 10
            )
        }
        let backend = MockAudioBackend(
            apps: apps,
            devices: [AudioDeviceSnapshot(id: "main", name: "Main Output", isDefault: true)]
        )
        let store = AudioControlStore(
            settingsStore: SettingsStore(settingsURL: settingsURL),
            backend: backend,
            permissionClient: RenderingPermissionClient()
        )
        try await store.refresh()
        let controls = ExternalControlsCoordinator()
        let view = MenuBarRootView(store: store)
            .environmentObject(controls)
        let render = try await renderPNG(view, size: CGSize(width: 360, height: 660))

        XCTAssertEqual(render.size.width, 360)
        XCTAssertLessThanOrEqual(render.size.height, 660)
        XCTAssertGreaterThan(render.data.count, 20_000)
        if let outputPath = ProcessInfo.processInfo.environment["AURALIS_POPUP_RENDER_PATH"] {
            try render.data.write(
                to: URL(fileURLWithPath: outputPath),
                options: .atomic
            )
        }
        XCTAssertEqual(store.displayRows.count, 50)
        XCTAssertLessThan(
            PopupContentLayoutModel.contentHeight(
                dimensions: settings.customization.popupDensity.dimensions,
                rowCount: store.displayRows.count,
                includesPermissionBanner: false,
                issueCount: 0,
                includesExpandedEQ: false,
                availableScreenHeight: 700,
                deviceCount: store.devices.count
            ),
            Double(store.displayRows.count) * PopupContentLayoutModel.compactRowMinimumHeight
        )
    }

    func testCompactEQEditorRendersAtPopupWidth() async throws {
        var process = EQCurve()
        process.setGain(4, at: 2)
        process.setGain(-3, at: 6)
        let view = EQBandEditor(
            stage: .process,
            targetName: "Music",
            curve: process,
            style: .compact,
            onClose: {},
            onGain: { _, _ in }
        )
        .padding(8)
        .frame(width: 360, height: 360)
        .background(AuralisColor.canvas)
        let render = try await renderPNG(view, size: CGSize(width: 360, height: 360))

        XCTAssertEqual(render.size.width, 360)
        XCTAssertEqual(render.size.height, 360)
        XCTAssertGreaterThan(render.data.count, 20_000)
        if let outputPath = ProcessInfo.processInfo.environment["AURALIS_EQ_RENDER_PATH"] {
            try render.data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        }
    }

    func testMainWorkbenchRendersMultiOutputDeck() async throws {
        let settingsURL = temporaryFileURL(prefix: "AuralisMainRendering", filename: "settings.json")
        let music = AudioAppIdentity(rawValue: "music")
        let browser = AudioAppIdentity(rawValue: "browser")
        var musicEQ = EQCurve()
        musicEQ.setGain(4, at: 4)
        var usbEQ = EQCurve()
        usbEQ.setGain(-5, at: 1)
        let settings = PersistedSettings(
            appSettings: [
                music: AppAudioSettings(
                    displayName: "Music",
                    volume: 0.78,
                    eq: musicEQ,
                    route: .multiOutput(["built-in", "usb"])
                ),
                browser: AppAudioSettings(
                    displayName: "Safari",
                    volume: 0.52,
                    route: .selectedDevice("display")
                ),
            ],
            deviceSettings: [
                "built-in": DeviceAudioSettings(
                    displayName: "MacBook Speakers",
                    volume: 0.72,
                    isMuted: false
                ),
                "usb": DeviceAudioSettings(
                    displayName: "USB DAC",
                    volume: 0.64,
                    isMuted: false,
                    eq: usbEQ
                ),
                "display": DeviceAudioSettings(
                    displayName: "Studio Display",
                    volume: 0.45,
                    isMuted: true
                ),
            ],
            hasCompletedOnboarding: true
        )
        try SettingsStore(settingsURL: settingsURL).save(settings)
        let backend = MockAudioBackend(
            apps: [
                AudioAppSnapshot(identity: music, displayName: "Music", level: 0.72),
                AudioAppSnapshot(identity: browser, displayName: "Safari", level: 0.3),
                AudioAppSnapshot(
                    identity: AudioAppIdentity(rawValue: "calls"),
                    displayName: "FaceTime",
                    level: 0.12
                ),
            ],
            devices: [
                AudioDeviceSnapshot(id: "built-in", name: "MacBook Speakers", isDefault: true),
                AudioDeviceSnapshot(id: "usb", name: "USB DAC"),
                AudioDeviceSnapshot(id: "display", name: "Studio Display"),
            ]
        )
        backend.perDeviceVolume = ["built-in": 0.72, "usb": 0.64, "display": 0.45]
        backend.perDeviceMuted = ["display": true]
        let store = AudioControlStore(
            settingsStore: SettingsStore(settingsURL: settingsURL),
            backend: backend,
            permissionClient: RenderingPermissionClient()
        )
        try await store.refresh()
        let view = MainWindowView(store: store)
            .frame(width: 1_180, height: 760)
        let render = try await renderPNG(view, size: CGSize(width: 1_180, height: 760))

        XCTAssertEqual(render.size.width, 1_180)
        XCTAssertEqual(render.size.height, 760)
        XCTAssertGreaterThan(render.data.count, 40_000)
        if let outputPath = ProcessInfo.processInfo.environment["AURALIS_MAIN_RENDER_PATH"] {
            try render.data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        }
    }

    func testProfileManagementPopoverRendersRichProfileState() async throws {
        let settingsURL = temporaryFileURL(prefix: "AuralisProfileRendering", filename: "settings.json")
        let musicID = AudioAppIdentity(rawValue: "com.apple.Music")
        let safariID = AudioAppIdentity(rawValue: "com.apple.Safari")
        let appSettings = [
            musicID: AppAudioSettings(displayName: "Music", volume: 0.72),
            safariID: AppAudioSettings(displayName: "Safari", volume: 0.48)
        ]
        let focus = AudioProfile(
            name: "Focus",
            appSettings: appSettings,
            deviceSettings: [:],
            preferredOutputDeviceID: nil
        )
        let calls = AudioProfile(
            name: "Calls",
            appSettings: [
                musicID: AppAudioSettings(displayName: "Music", volume: 0.2, isMuted: true),
                safariID: AppAudioSettings(displayName: "Safari", volume: 0.82)
            ],
            deviceSettings: [:],
            preferredOutputDeviceID: nil
        )
        let laptopConfiguration = AudioProfile(
            name: "Focus",
            scope: .outputDevice("default-output"),
            activatesAutomatically: true,
            appSettings: focus.appSettings,
            deviceSettings: [
                "default-output": DeviceAudioSettings(
                    displayName: "MacBook Speakers",
                    volume: 0.65,
                    isMuted: false
                )
            ],
            preferredOutputDeviceID: "default-output"
        )
        let settings = PersistedSettings(
            appSettings: appSettings,
            profiles: [focus, calls, laptopConfiguration],
            activeGlobalProfileID: focus.id,
            activeLocalProfileID: laptopConfiguration.id,
            profileHasOverrides: true,
            hasCompletedOnboarding: true
        )
        try SettingsStore(settingsURL: settingsURL).save(settings)

        let store = AudioControlStore(
            settingsStore: SettingsStore(settingsURL: settingsURL),
            backend: MockAudioBackend(),
            permissionClient: RenderingPermissionClient()
        )
        try await store.refresh()
        let hostingView = NSHostingView(
            rootView: ProfileManagementPopover(store: store, onClose: {})
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 560, height: 560)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)

        XCTAssertEqual(hostingView.bounds.width, 560)
        XCTAssertEqual(hostingView.bounds.height, 560)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 20_000)
        if let outputPath = ProcessInfo.processInfo.environment["AURALIS_PROFILE_RENDER_PATH"] {
            try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        }
    }

    private func renderPNG<Content: View>(
        _ view: Content,
        size: CGSize
    ) async throws -> (data: Data, size: CGSize) {
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        withExtendedLifetime(window) {}
        return (png, hostingView.bounds.size)
    }
}

private struct RenderingPermissionClient: AudioCapturePermissionClient {
    func currentState() -> AudioCapturePermissionState {
        AudioCapturePermissionState(screenCapture: .granted, audioUsageDescription: .present)
    }

    func requestScreenCaptureAccess() -> AudioCapturePermissionState { currentState() }
    func openPrivacySettings() {}
    func relaunchApp() async throws {}
}
