import XCTest
@testable import Auralis

final class AppControlTargetResolverTests: XCTestCase {
    func testAudibleAppWinsOverFrontmost() {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let safari = AudioAppIdentity(rawValue: "com.example.Safari")
        let rows = [
            DisplayableAppRow(identity: music, displayName: "Music", isActive: true, isPinned: false, settings: AppAudioSettings(displayName: "Music", volume: 0.8)),
            DisplayableAppRow(identity: safari, displayName: "Safari", isActive: true, isPinned: false, settings: AppAudioSettings(displayName: "Safari", volume: 0.8))
        ]
        let levels: [AudioAppIdentity: Double] = [music: 0.4, safari: 0.1]

        XCTAssertEqual(AppControlTargetResolver.resolve(rows: rows, levels: levels, frontmostBundleID: safari.rawValue, selectedAppID: nil), music)
    }

    func testFrontmostWinsWhenNoAudibleApp() {
        let safari = AudioAppIdentity(rawValue: "com.example.Safari")
        let rows = [
            DisplayableAppRow(identity: safari, displayName: "Safari", isActive: true, isPinned: false, settings: AppAudioSettings(displayName: "Safari", volume: 0.8))
        ]
        let levels: [AudioAppIdentity: Double] = [safari: 0.01]

        XCTAssertEqual(AppControlTargetResolver.resolve(rows: rows, levels: levels, frontmostBundleID: safari.rawValue, selectedAppID: nil), safari)
    }

    func testFallsBackToPinnedThenFirst() {
        let a = AudioAppIdentity(rawValue: "a")
        let b = AudioAppIdentity(rawValue: "b")
        let rows = [
            DisplayableAppRow(identity: a, displayName: "A", isActive: false, isPinned: false, settings: AppAudioSettings(displayName: "A", volume: 0.8)),
            DisplayableAppRow(identity: b, displayName: "B", isActive: false, isPinned: true, settings: AppAudioSettings(displayName: "B", volume: 0.8))
        ]

        XCTAssertEqual(AppControlTargetResolver.resolve(rows: rows, levels: [:], frontmostBundleID: nil, selectedAppID: nil), b)
    }
}
