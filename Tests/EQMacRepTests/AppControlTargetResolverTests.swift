import XCTest
@testable import EQMacRep

final class AppControlTargetResolverTests: XCTestCase {
    func testAudibleAppWinsOverFrontmost() {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let safari = AudioAppIdentity(rawValue: "com.example.Safari")
        let rows = [
            DisplayableAppRow(identity: music, displayName: "Music", isActive: true, isPinned: false, level: 0.4, settings: AppAudioSettings(displayName: "Music", volume: 0.8)),
            DisplayableAppRow(identity: safari, displayName: "Safari", isActive: true, isPinned: false, level: 0.1, settings: AppAudioSettings(displayName: "Safari", volume: 0.8))
        ]

        XCTAssertEqual(AppControlTargetResolver.resolve(rows: rows, frontmostBundleID: safari.rawValue, selectedAppID: nil), music)
    }

    func testFrontmostWinsWhenNoAudibleApp() {
        let safari = AudioAppIdentity(rawValue: "com.example.Safari")
        let rows = [
            DisplayableAppRow(identity: safari, displayName: "Safari", isActive: true, isPinned: false, level: 0.01, settings: AppAudioSettings(displayName: "Safari", volume: 0.8))
        ]

        XCTAssertEqual(AppControlTargetResolver.resolve(rows: rows, frontmostBundleID: safari.rawValue, selectedAppID: nil), safari)
    }

    func testFallsBackToPinnedThenFirst() {
        let a = AudioAppIdentity(rawValue: "a")
        let b = AudioAppIdentity(rawValue: "b")
        let rows = [
            DisplayableAppRow(identity: a, displayName: "A", isActive: false, isPinned: false, level: 0, settings: AppAudioSettings(displayName: "A", volume: 0.8)),
            DisplayableAppRow(identity: b, displayName: "B", isActive: false, isPinned: true, level: 0, settings: AppAudioSettings(displayName: "B", volume: 0.8))
        ]

        XCTAssertEqual(AppControlTargetResolver.resolve(rows: rows, frontmostBundleID: nil, selectedAppID: nil), b)
    }
}
