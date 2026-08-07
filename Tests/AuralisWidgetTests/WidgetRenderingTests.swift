import AuralisWidgetShared
import SwiftUI
import WidgetKit
import XCTest
@testable import Auralis

@MainActor
final class WidgetRenderingTests: XCTestCase {
    func testSignedHostResolvesConfiguredApplicationGroup() throws {
        let layout = try WidgetSharedContainer.resolveLayout()
        XCTAssertEqual(layout.rootURL.lastPathComponent, WidgetSharedContainer.widgetDirectoryName)
        XCTAssertTrue(
            layout.rootURL.path.contains(WidgetSharedContainer.appGroupID),
            "Signed host resolved unexpected container: \(layout.rootURL.path)"
        )
    }

    func testMixerRendersProductionSmallMediumAndLargeFamilies() throws {
        let entry = makeEntry(hostState: .running)

        try assertRenders(
            AuralisMixerWidgetView(entry: entry.withFamily(.systemSmall)),
            size: CGSize(width: 158, height: 158),
            captureName: "mixer-small"
        )
        try assertRenders(
            AuralisMixerWidgetView(entry: entry.withFamily(.systemMedium)),
            size: CGSize(width: 338, height: 158),
            captureName: "mixer-medium"
        )
        try assertRenders(
            AuralisMixerWidgetView(entry: entry.withFamily(.systemLarge)),
            size: CGSize(width: 344, height: 344),
            captureName: "mixer-large"
        )
    }

    func testEQViewRendersProductionLargeFamily() throws {
        try assertRenders(
            AuralisEQWidgetView(entry: makeEntry(hostState: .running).withFamily(.systemLarge)),
            size: CGSize(width: 344, height: 344)
        )
    }

    func testClosedHostStatesRenderWithoutInteractiveData() throws {
        let entry = makeEntry(hostState: .stopped)

        try assertRenders(
            AuralisMixerWidgetView(entry: entry.withFamily(.systemMedium)),
            size: CGSize(width: 338, height: 158)
        )
        try assertRenders(
            AuralisEQWidgetView(entry: entry.withFamily(.systemLarge)),
            size: CGSize(width: 344, height: 344)
        )
    }

    private func assertRenders<V: View>(
        _ view: V,
        size: CGSize,
        captureName: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let renderer = ImageRenderer(
            content: view
                .frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor))
        )
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(size)
        let image = try XCTUnwrap(renderer.nsImage, file: file, line: line)
        XCTAssertEqual(image.size.width, size.width, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(image.size.height, size.height, accuracy: 0.5, file: file, line: line)
        XCTAssertNotNil(image.tiffRepresentation, file: file, line: line)
        try captureIfRequested(image, name: captureName)
    }

    private func captureIfRequested(_ image: NSImage, name: String?) throws {
        guard let name,
              let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let png = representation.representation(using: .png, properties: [:]) else { return }
        let directory = ProcessInfo.processInfo.environment["AURALIS_WIDGET_CAPTURE_DIR"]
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("AuralisWidgetCaptures", isDirectory: true)
                .path
        let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try png.write(to: directoryURL.appendingPathComponent("\(name).png"), options: .atomic)
    }

    private func makeEntry(hostState: WidgetHostState) -> AuralisEntry {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = WidgetSnapshot(
            generatedAt: now,
            hostState: hostState,
            hostUpdatedAt: now,
            statusMessage: hostState == .running ? "Ready" : "Open Auralis",
            activeAppCount: hostState == .running ? 2 : 0,
            volumeStep: 0.05,
            devices: hostState == .running ? [
                .init(id: "main", name: "Main Output", volume: 0.75, isMuted: false, isDefault: true),
                .init(id: "home", name: "Home Speaker", volume: 0.62, isMuted: false, isDefault: false),
                .init(id: "display", name: "Display", volume: 0.45, isMuted: false, isDefault: false)
            ] : [],
            apps: hostState == .running ? [
                .init(
                    id: "music",
                    displayName: "Music",
                    isActive: true,
                    isPinned: true,
                    level: 0.7,
                    volume: 0.8,
                    isMuted: false,
                    boost: 2,
                    routeLabel: "Main Output",
                    eqGains: [0, 1, 2, 1, 0, -1, -2, -1, 0, 1],
                    eqRange: 12
                ),
                .init(
                    id: "browser",
                    displayName: "Browser",
                    isActive: true,
                    isPinned: false,
                    level: 0.35,
                    volume: 0.6,
                    isMuted: false,
                    boost: 1,
                    routeLabel: "Main Output",
                    eqGains: Array(repeating: 0, count: 10),
                    eqRange: 12
                ),
                .init(
                    id: "meeting",
                    displayName: "Meeting",
                    isActive: true,
                    isPinned: false,
                    level: 0.22,
                    volume: 0.55,
                    isMuted: false,
                    boost: 1,
                    routeLabel: "Main Output",
                    eqGains: Array(repeating: 0, count: 10),
                    eqRange: 12
                ),
                .init(
                    id: "editor",
                    displayName: "Editor",
                    isActive: false,
                    isPinned: true,
                    level: 0,
                    volume: 0.7,
                    isMuted: true,
                    boost: 1,
                    routeLabel: "Main Output",
                    eqGains: Array(repeating: 0, count: 10),
                    eqRange: 12
                )
            ] : [],
            profiles: hostState == .running ? [
                .init(id: "11111111-1111-1111-1111-111111111111", name: "Everywhere"),
                .init(
                    id: "22222222-2222-2222-2222-222222222222",
                    name: "Home Speaker",
                    scope: .outputDevice,
                    outputDeviceID: "main"
                ),
                .init(id: "33333333-3333-3333-3333-333333333333", name: "Focus")
            ] : [],
            activeGlobalProfileID: hostState == .running
                ? "11111111-1111-1111-1111-111111111111"
                : nil,
            activeLocalProfileID: hostState == .running
                ? "22222222-2222-2222-2222-222222222222"
                : nil,
            profileHasOverrides: hostState == .running
        )
        return AuralisEntry(date: now, snapshot: snapshot, family: .systemMedium)
    }
}

private extension AuralisEntry {
    func withFamily(_ family: WidgetFamily) -> AuralisEntry {
        AuralisEntry(date: date, snapshot: snapshot, family: family)
    }
}
