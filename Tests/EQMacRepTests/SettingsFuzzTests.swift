import Foundation
import XCTest
@testable import EQMacRep

final class SettingsFuzzTests: XCTestCase {
    func testSeededMalformedSettingsDecodePropertyProducesCanonicalRoundTrips() throws {
        var generator = SeededRandomNumberGenerator(seed: 0x4551_4D41_4352_4550)

        for iteration in 0..<400 {
            let appID = "app-\(iteration % 23)"
            let gainCount = Int.random(in: 0...28, using: &generator)
            let gains: [Any] = (0..<gainCount).map { index in
                randomJSONScalar(index: index, using: &generator)
            }
            let route: [String: Any]
            switch iteration % 4 {
            case 0:
                route = ["type": "selectedDevice", "deviceID": iteration.isMultiple(of: 3) ? "" : " usb "]
            case 1:
                route = ["type": "multiOutput", "deviceIDs": ["usb", "usb", " ", "built-in"]]
            case 2:
                route = ["selectedDevice": ["_0": iteration]]
            default:
                route = ["unknown": true]
            }
            let appValue: Any = iteration.isMultiple(of: 11)
                ? NSNull()
                : [
                    "displayName": iteration.isMultiple(of: 7) ? iteration : "Application \(iteration)",
                    "volume": randomJSONScalar(index: iteration, using: &generator),
                    "isMuted": iteration.isMultiple(of: 2),
                    "boost": [1, 2, 3, 4, 99][iteration % 5],
                    "eq": [
                        "range": [6, 12, 18, 99][iteration % 4],
                        "gains": gains
                    ],
                    "route": route
                ] as [String: Any]
            let object: [String: Any] = [
                "version": iteration.isMultiple(of: 9) ? "legacy" : Int.random(in: 1...PersistedSettings.currentVersion, using: &generator),
                "customization": [
                    "appearance": ["system", "light", "dark", "invalid"][iteration % 4],
                    "popupDensity": ["compact", "comfortable", "spacious", 12][iteration % 4],
                    "defaultNewAppVolume": randomJSONScalar(index: iteration + 1, using: &generator),
                    "eqGainRange": [6, 12, 18, -1][iteration % 4],
                    "volumeStep": [0.01, 0.02, 0.05, 0.10, 9][iteration % 5],
                    "showInactiveApps": iteration.isMultiple(of: 2),
                    "backendMode": iteration.isMultiple(of: 5) ? "invalid" : "coreAudioDiscovery"
                ],
                "appSettings": [appID: appValue],
                "pinnedAppIDs": [appID, appID, "", iteration],
                "ignoredAppIDs": [NSNull(), appID],
                "appDisplayOrder": [appID, appID, " ", "other-\(iteration % 5)"],
                "hasCompletedOnboarding": iteration.isMultiple(of: 2) ? true : "not-a-bool"
            ]

            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let decoded = try JSONDecoder().decode(PersistedSettings.self, from: data)

            assertCanonical(decoded, iteration: iteration)
            let encoded = try JSONEncoder().encode(decoded)
            let roundTrip = try JSONDecoder().decode(PersistedSettings.self, from: encoded)
            XCTAssertEqual(roundTrip, decoded, "seed iteration \(iteration)")
        }
    }

    func testSeededCorruptByteStreamsAreQuarantinedByteForByte() throws {
        var generator = SeededRandomNumberGenerator(seed: 0x434F_5252_5550_5421)

        for iteration in 0..<32 {
            let url = temporaryFileURL(prefix: "EQMacRepCorruptFuzz", filename: "settings.json")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let byteCount = Int.random(in: 1...512, using: &generator)
            var bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
            bytes[0] = 0xFF
            let original = Data(bytes)
            try original.write(to: url)

            let result = try SettingsStore(settingsURL: url).loadWithRecovery()

            XCTAssertEqual(result.settings, PersistedSettings(), "seed iteration \(iteration)")
            let quarantine = try XCTUnwrap(result.recoveryNotice?.quarantineURL)
            XCTAssertEqual(try Data(contentsOf: quarantine), original, "seed iteration \(iteration)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testFutureVersionPropertyNeverRewritesOrQuarantines() throws {
        var generator = SeededRandomNumberGenerator(seed: 0x4655_5455_5245_2121)

        for _ in 0..<32 {
            let version = Int.random(
                in: (PersistedSettings.currentVersion + 1)...10_000,
                using: &generator
            )
            let url = temporaryFileURL(prefix: "EQMacRepFutureFuzz", filename: "settings.json")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let original = Data("{\"version\":\(version),\"future\":true}".utf8)
            try original.write(to: url)

            XCTAssertThrowsError(try SettingsStore(settingsURL: url).load()) { error in
                XCTAssertEqual(
                    error as? SettingsStoreError,
                    .futureVersion(found: version, supported: PersistedSettings.currentVersion)
                )
            }
            XCTAssertEqual(try Data(contentsOf: url), original)
            let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            XCTAssertFalse(siblings.contains { $0.contains(".corrupt-") })
        }
    }

    private func randomJSONScalar(
        index: Int,
        using generator: inout SeededRandomNumberGenerator
    ) -> Any {
        switch index % 5 {
        case 0: Double.random(in: -100...100, using: &generator)
        case 1: Int.random(in: -100...100, using: &generator)
        case 2: "not-a-number"
        case 3: NSNull()
        default: index.isMultiple(of: 2)
        }
    }

    private func assertCanonical(_ settings: PersistedSettings, iteration: Int) {
        XCTAssertEqual(settings.version, PersistedSettings.currentVersion, "seed iteration \(iteration)")
        XCTAssertTrue((0...1).contains(settings.customization.defaultNewAppVolume), "seed iteration \(iteration)")
        XCTAssertEqual(Set(settings.appDisplayOrder).count, settings.appDisplayOrder.count, "seed iteration \(iteration)")
        XCTAssertTrue(settings.appDisplayOrder.allSatisfy(\.isPersistable), "seed iteration \(iteration)")
        for (identity, app) in settings.appSettings {
            XCTAssertTrue(identity.isPersistable, "seed iteration \(iteration)")
            XCTAssertTrue(app.volume.isFinite && (0...1).contains(app.volume), "seed iteration \(iteration)")
            XCTAssertEqual(app.eq.gains.count, EQCurve.bandCount, "seed iteration \(iteration)")
            XCTAssertTrue(
                app.eq.gains.allSatisfy { $0.isFinite && abs($0) <= app.eq.range.rawValue },
                "seed iteration \(iteration)"
            )
            XCTAssertEqual(app.route, app.route.normalized, "seed iteration \(iteration)")
        }
    }
}
