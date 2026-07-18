import EQMacRepWidgetShared
import SwiftUI
import WidgetKit
import XCTest
@testable import EQMacRep

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

    func testMixerRendersProductionSmallAndMediumFamilies() throws {
        let entry = makeEntry(hostState: .running)

        try assertRenders(
            EQMacRepMixerWidgetView(entry: entry.withFamily(.systemSmall)),
            size: CGSize(width: 158, height: 158)
        )
        try assertRenders(
            EQMacRepMixerWidgetView(entry: entry.withFamily(.systemMedium)),
            size: CGSize(width: 338, height: 158)
        )
    }

    func testEQViewRendersProductionLargeFamily() throws {
        try assertRenders(
            EQMacRepEQWidgetView(entry: makeEntry(hostState: .running).withFamily(.systemLarge)),
            size: CGSize(width: 338, height: 354)
        )
    }

    func testClosedHostStatesRenderWithoutInteractiveData() throws {
        let entry = makeEntry(hostState: .stopped)

        try assertRenders(
            EQMacRepMixerWidgetView(entry: entry.withFamily(.systemMedium)),
            size: CGSize(width: 338, height: 158)
        )
        try assertRenders(
            EQMacRepEQWidgetView(entry: entry.withFamily(.systemLarge)),
            size: CGSize(width: 338, height: 354)
        )
    }

    private func assertRenders<V: View>(
        _ view: V,
        size: CGSize,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(size)
        let image = try XCTUnwrap(renderer.nsImage, file: file, line: line)
        XCTAssertEqual(image.size.width, size.width, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(image.size.height, size.height, accuracy: 0.5, file: file, line: line)
        XCTAssertNotNil(image.tiffRepresentation, file: file, line: line)
    }

    private func makeEntry(hostState: WidgetHostState) -> EQMacRepEntry {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = WidgetSnapshot(
            generatedAt: now,
            hostState: hostState,
            hostUpdatedAt: now,
            statusMessage: hostState == .running ? "Ready" : "Open EQMacRep",
            activeAppCount: hostState == .running ? 2 : 0,
            volumeStep: 0.05,
            devices: hostState == .running ? [
                .init(id: "main", name: "Main Output", volume: 0.75, isMuted: false, isDefault: true)
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
                )
            ] : []
        )
        return EQMacRepEntry(date: now, snapshot: snapshot, family: .systemMedium)
    }
}

private extension EQMacRepEntry {
    func withFamily(_ family: WidgetFamily) -> EQMacRepEntry {
        EQMacRepEntry(date: date, snapshot: snapshot, family: family)
    }
}
