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
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: 360, height: 660)

        let image = try XCTUnwrap(renderer.nsImage)

        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
        XCTAssertLessThanOrEqual(image.size.height, 660)
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
}

private struct RenderingPermissionClient: AudioCapturePermissionClient {
    func currentState() -> AudioCapturePermissionState {
        AudioCapturePermissionState(screenCapture: .granted, audioUsageDescription: .present)
    }

    func requestScreenCaptureAccess() -> AudioCapturePermissionState { currentState() }
    func openPrivacySettings() {}
    func relaunchApp() async throws {}
}
