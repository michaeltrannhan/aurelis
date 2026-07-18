import SwiftUI
import XCTest
@testable import EQMacRep

@MainActor
final class ViewRenderingIntegrationTests: XCTestCase {
    func testLargePopupRendersToBoundedBitmapWithProductionViewHierarchy() async throws {
        let settingsURL = temporaryFileURL(prefix: "EQMacRepRendering", filename: "settings.json")
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
        let store = try AudioControlStore(
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
}

private struct RenderingPermissionClient: AudioCapturePermissionClient {
    func currentState() -> AudioCapturePermissionState {
        AudioCapturePermissionState(screenCapture: .granted, audioUsageDescription: .present)
    }

    func requestScreenCaptureAccess() -> AudioCapturePermissionState { currentState() }
    func openPrivacySettings() {}
    func relaunchApp() async throws {}
}
