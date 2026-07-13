import XCTest
@testable import EQMacRep

@MainActor
final class PopupKeyboardNavModelTests: XCTestCase {
    func testNextAndPreviousFollowVisibleRows() {
        let nav = PopupKeyboardNavModel()
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let safari = AudioAppIdentity(rawValue: "com.example.Safari")

        nav.sync(apps: [music, safari], isEditing: false)

        XCTAssertEqual(nav.next(after: nil), music)
        XCTAssertEqual(nav.next(after: music), safari)
        XCTAssertNil(nav.next(after: safari))
        XCTAssertEqual(nav.previous(before: safari), music)
        XCTAssertNil(nav.previous(before: music))
    }

    func testEditingClearsKeyboardOrder() {
        let nav = PopupKeyboardNavModel()

        nav.sync(apps: [AudioAppIdentity(rawValue: "com.example.Music")], isEditing: true)

        XCTAssertNil(nav.next(after: nil))
    }

    func testReturnTargetsSelectedRowOrDefaultsToFirstVisibleRow() {
        let nav = PopupKeyboardNavModel()
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let safari = AudioAppIdentity(rawValue: "com.example.Safari")
        nav.sync(apps: [music, safari], isEditing: false)

        XCTAssertEqual(nav.returnActionTarget(for: safari), safari)
        XCTAssertEqual(nav.returnActionTarget(for: nil), music)
    }

    func testQuickActionsPreferExplicitSelection() {
        let music = row("Music", isActive: true, level: 0.2)
        let safari = row("Safari", isActive: true, level: 0.8)

        XCTAssertEqual(
            PopupQuickActionTargetResolver.resolve(
                rows: [music, safari],
                selectedAppID: music.identity
            ),
            music.identity
        )
    }

    func testQuickActionsUseFirstActiveRowThenFirstVisibleRow() {
        let music = row("Music", isActive: false, level: 0.9)
        let safari = row("Safari", isActive: true, level: 0.3)

        XCTAssertEqual(
            PopupQuickActionTargetResolver.resolve(rows: [music, safari], selectedAppID: nil),
            safari.identity
        )
        XCTAssertEqual(
            PopupQuickActionTargetResolver.resolve(rows: [music], selectedAppID: nil),
            music.identity
        )
    }

    func testQuickActionTargetDoesNotFollowFluctuatingLevels() {
        let music = row("Music", isActive: true, level: 0.1)
        let safari = row("Safari", isActive: true, level: 0.9)

        XCTAssertEqual(
            PopupQuickActionTargetResolver.resolve(rows: [music, safari], selectedAppID: nil),
            music.identity
        )
    }

    private func row(_ name: String, isActive: Bool, level: Double) -> DisplayableAppRow {
        let identity = AudioAppIdentity(rawValue: "com.example.\(name)")
        return DisplayableAppRow(
            identity: identity,
            displayName: name,
            isActive: isActive,
            isPinned: false,
            level: level,
            settings: AppAudioSettings(displayName: name, volume: 0.5)
        )
    }
}
