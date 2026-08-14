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
            devices: [
                AudioDeviceSnapshot(id: "main", name: "Main Output", isDefault: true),
                AudioDeviceSnapshot(id: "usb", name: "USB DAC"),
                AudioDeviceSnapshot(id: "display", name: "Studio Display"),
            ]
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
