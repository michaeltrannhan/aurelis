import XCTest
@testable import Auralis

final class MixerListPresentationTests: XCTestCase {
    private func row(_ name: String, active: Bool = false, pinned: Bool = false) -> DisplayableAppRow {
        DisplayableAppRow(
            identity: AudioAppIdentity(rawValue: name), displayName: name,
            isActive: active, isPinned: pinned, settings: AppAudioSettings(displayName: name, volume: 1)
        )
    }

    func testDefaultPlayingFilterDoesNotMaskDiscoveryState() {
        let phases: [MixerPhase] = [.starting, .permissionLimited, .degraded, .failed, .empty]
        for phase in phases {
            let model = MixerListPresentation(rows: [], search: "", filter: .playing, phase: phase)
            XCTAssertEqual(model.emptyState, MixerEmptyState(phase: phase))
        }
        let model = MixerListPresentation(rows: [row("Music")], search: "missing", filter: .playing, phase: .failed)
        XCTAssertEqual(model.emptyState, .failed)
    }

    func testSearchTrimsWhitespaceAndMatchesNameWithoutChangingIdentity() {
        let music = row("Music", active: true)
        let model = MixerListPresentation(rows: [music, row("Safari", active: true)], search: "  mUs  ", filter: .playing, phase: .ready)
        XCTAssertEqual(model.rows.map(\.identity), [music.identity])
        let whitespace = MixerListPresentation(rows: [music], search: " \n ", filter: .all, phase: .ready)
        XCTAssertEqual(whitespace.rows, [music])
    }

    func testEmptySearchPinnedAndPlayingHaveDifferentRecoveryActions() {
        let rows = [row("Music")]
        XCTAssertEqual(MixerListPresentation(rows: rows, search: "Safari", filter: .all, phase: .ready).emptyState, .noMatchingApps)
        XCTAssertEqual(MixerListPresentation(rows: rows, search: "", filter: .pinned, phase: .ready).emptyState, .noPinnedApps)
        XCTAssertEqual(MixerListPresentation(rows: rows, search: "", filter: .playing, phase: .ready).emptyState, .noPlayingApps)
        XCTAssertEqual(MixerListPresentation(rows: rows, search: " \n", filter: .pinned, phase: .ready).emptyState, .noPinnedApps)
    }

    func testFiltersPreserveOrderAndIncludeInactivePinnedApps() {
        let music = row("Music", active: true)
        let safari = row("Safari", pinned: true)
        let rows = [music, safari]
        XCTAssertEqual(MixerListPresentation(rows: rows, search: "", filter: .playing, phase: .ready).rows, [music])
        XCTAssertEqual(MixerListPresentation(rows: rows, search: "", filter: .pinned, phase: .ready).rows, [safari])
        XCTAssertEqual(MixerListPresentation(rows: rows, search: "", filter: .all, phase: .ready).rows, rows)
    }
}
