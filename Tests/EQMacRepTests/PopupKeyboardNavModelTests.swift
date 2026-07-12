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
}
