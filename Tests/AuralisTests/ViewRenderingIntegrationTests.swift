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
        let launchAtLogin = LaunchAtLoginController(client: RenderingLoginItemClient())
        let view = MenuBarRootView(store: store)
            .environmentObject(controls)
            .environmentObject(launchAtLogin)
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

    func testRefinedMixerRendersInBothAppearancesAndWindowLayouts() async throws {
        for appearance in [AppAppearance.dark, .light] {
            let settingsURL = temporaryFileURL(prefix: "AuralisUXRendering", filename: "settings.json")
            var settings = PersistedSettings(hasCompletedOnboarding: true)
            settings.customization.popupDensity = .compact
            settings.customization.appearance = appearance
            let music = AudioAppIdentity(rawValue: "com.apple.Music")
            let safari = AudioAppIdentity(rawValue: "com.apple.Safari")
            let zoom = AudioAppIdentity(rawValue: "us.zoom.xos")
            settings.appSettings[music] = AppAudioSettings(displayName: "Music", volume: 0.8)
            settings.appSettings[safari] = AppAudioSettings(displayName: "Safari", volume: 1, boost: .x2)
            settings.appSettings[zoom] = AppAudioSettings(displayName: "Zoom", volume: 0.45, isMuted: true)
            try SettingsStore(settingsURL: settingsURL).save(settings)
            let backend = MockAudioBackend(
                apps: [
                    AudioAppSnapshot(identity: music, displayName: "Music", isActive: true, level: 0.6),
                    AudioAppSnapshot(identity: safari, displayName: "Safari", isActive: true, level: 0.35),
                    AudioAppSnapshot(identity: zoom, displayName: "Zoom", isActive: true, level: 0)
                ],
                devices: [
                    AudioDeviceSnapshot(id: "main", name: "MacBook Pro Speakers", isDefault: true),
                    AudioDeviceSnapshot(id: "usb", name: "USB DAC"),
                    AudioDeviceSnapshot(id: "display", name: "Studio Display")
                ]
            )
            let store = AudioControlStore(
                settingsStore: SettingsStore(settingsURL: settingsURL), backend: backend,
                permissionClient: RenderingPermissionClient()
            )
            await store.waitUntilReady()
            try await store.refresh()
            try await store.setVolume(0.8, for: music)
            try await store.setBoost(.x2, for: safari)
            try await store.setVolume(0.45, for: zoom)
            try await store.setMuted(true, for: zoom)
            let controls = ExternalControlsCoordinator()
            let launchAtLogin = LaunchAtLoginController(client: RenderingLoginItemClient())
            let popup = MenuBarRootView(store: store)
                .environmentObject(controls)
                .environmentObject(launchAtLogin)
            let popupRender = try await renderPNG(popup, size: CGSize(width: 360, height: 660))
            XCTAssertEqual(popupRender.size.width, 360)
            XCTAssertGreaterThan(popupRender.data.count, 20_000)
            try writeUXRender(popupRender.data, name: "popup-\(appearance.rawValue)")
            for width in [780.0, 1180.0] {
                let render = try await renderPNG(MainWindowView(store: store), size: CGSize(width: width, height: 660))
                XCTAssertEqual(render.size.width, width)
                XCTAssertEqual(render.size.height, 660)
                XCTAssertGreaterThan(render.data.count, 20_000)
                try writeUXRender(render.data, name: "desktop-\(Int(width))-\(appearance.rawValue)")
            }
            let emptyView = MixerEmptyStateView(
                state: .noMatchingApps, onRefresh: {}, onShowInactive: nil,
                onResetFilter: {}, compact: true
            )
            .background(AuralisColor.canvas)
            .preferredColorScheme(appearance.colorScheme)
            let emptyRender = try await renderPNG(emptyView, size: CGSize(width: 360, height: 144))
            XCTAssertEqual(emptyRender.size.height, 144)
            try writeUXRender(emptyRender.data, name: "empty-search-\(appearance.rawValue)")
        }
    }

    func testCompactEQEditorsRenderAtBothMenuBarWidths() async throws {
        for appearance in [AppAppearance.dark, .light] {
            for stage in EQStage.allCases {
                for width in [360.0, 400.0] {
                    let editor = EQBandEditor(
                        stage: stage,
                        targetName: stage == .process ? "Music" : "MacBook Pro Speakers",
                        curve: EQCurve(gains: [0, 1, 2, 3, 1, -1, -2, 0, 1, 0], range: .db18),
                        style: .compact, onClose: {}, onGain: { _, _ in }
                    )
                    .padding(8)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(AuralisColor.canvas)
                    .preferredColorScheme(appearance.colorScheme)
                    let render = try await renderPNG(editor, size: CGSize(width: width, height: 460))
                    XCTAssertEqual(render.size.width, width)
                    XCTAssertGreaterThan(render.data.count, 15_000)
                    try writeUXRender(render.data, name: "eq-\(stage.rawValue)-\(Int(width))-\(appearance.rawValue)")
                }
            }
        }
    }

    private func writeUXRender(_ data: Data, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["AURALIS_UX_RENDER_DIR"] else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try data.write(to: url.appendingPathComponent(name + ".png"), options: .atomic)
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

@MainActor
private struct RenderingLoginItemClient: LoginItemClient {
    func currentStatus() -> LoginItemStatus { .unavailable }
    func register() throws {}
    func unregister() throws {}
    func openLoginItemsSettings() -> Bool { true }
}

private struct RenderingPermissionClient: AudioCapturePermissionClient {
    func currentState() -> AudioCapturePermissionState {
        AudioCapturePermissionState(screenCapture: .granted, audioUsageDescription: .present)
    }

    func requestScreenCaptureAccess() -> AudioCapturePermissionState { currentState() }
    func openPrivacySettings() {}
    func relaunchApp() async throws {}
}
