import Foundation
import XCTest
@testable import EQMacRepWidgetShared

final class WidgetModelsTests: XCTestCase {
    func testWidgetPresentationDrivesRenderingAndAccessibilityForRunningAndClosedHosts() {
        let now = Date(timeIntervalSince1970: 1_000)
        let apps = (0..<4).map { index in
            WidgetSnapshot.AppSummary(
                id: "app-\(index)",
                displayName: "App \(index)",
                isActive: true,
                isPinned: false,
                level: 0.5,
                volume: 0.755,
                isMuted: index == 0,
                boost: 2,
                routeLabel: "USB",
                eqGains: Array(repeating: 0, count: 10),
                eqRange: 12
            )
        }
        let running = WidgetSnapshot(
            generatedAt: now,
            hostState: .running,
            hostUpdatedAt: now,
            statusMessage: "Ready",
            activeAppCount: 4,
            volumeStep: 0.05,
            devices: [
                .init(id: "usb", name: "USB", volume: 0.8, isMuted: false, isDefault: false),
                .init(id: "main", name: "Main", volume: 0.7, isMuted: false, isDefault: true)
            ],
            apps: apps
        )

        let presentation = WidgetMixerPresentation(
            snapshot: running,
            date: now,
            maximumAppCount: 3
        )
        XCTAssertTrue(presentation.controlsEnabled)
        XCTAssertEqual(presentation.statusText, "Ready")
        XCTAssertEqual(presentation.defaultDevice?.id, "main")
        XCTAssertEqual(presentation.apps.map(\.id), ["app-0", "app-1", "app-2"])
        XCTAssertEqual(presentation.activeCountText, "4 active")
        XCTAssertEqual(
            WidgetMixerPresentation.appValue(apps[0]),
            "76 percent volume, muted, 2 times boost, USB"
        )
        XCTAssertEqual(WidgetMixerPresentation.muteLabel(name: "App 0", isMuted: true), "Unmute App 0")
        XCTAssertEqual(WidgetMixerPresentation.volumeLabel(name: "App 0", direction: -1), "Decrease App 0 volume")
        XCTAssertEqual(WidgetMixerPresentation.boostLabel(name: "App 0"), "Cycle App 0 boost")
        XCTAssertEqual(
            WidgetMixerPresentation.eqBandLabel(appName: "App 0", frequency: "1k", direction: 1),
            "Increase App 0 1k hertz gain"
        )

        let closed = WidgetSnapshot(
            generatedAt: now,
            hostState: .stopped,
            hostUpdatedAt: now,
            statusMessage: "Stopped",
            activeAppCount: 0,
            volumeStep: 0.05,
            devices: [],
            apps: []
        )
        let closedPresentation = WidgetMixerPresentation(
            snapshot: closed,
            date: now,
            maximumAppCount: 3
        )
        XCTAssertFalse(closedPresentation.controlsEnabled)
        XCTAssertEqual(closedPresentation.statusText, "Open EQMacRep to use controls")
    }

    func testWidgetIntentFactoryMapsAndValidatesEveryInteractiveControl() throws {
        let now = Date(timeIntervalSince1970: 12_345)
        let commands = try [
            XCTUnwrap(WidgetIntentCommandFactory.setAppMuted(appID: "music", muted: true, now: now)),
            XCTUnwrap(WidgetIntentCommandFactory.setAppVolume(appID: "music", volume: 0.4, now: now)),
            XCTUnwrap(WidgetIntentCommandFactory.setAppBoost(appID: "music", boost: 3, now: now)),
            XCTUnwrap(WidgetIntentCommandFactory.setEQBandGain(appID: "music", band: 4, gain: -2.5, now: now)),
            XCTUnwrap(WidgetIntentCommandFactory.setOutputDeviceMuted(deviceID: "usb", muted: false, now: now)),
            WidgetIntentCommandFactory.refresh(now: now)
        ]

        XCTAssertEqual(commands.map(\.targetType), [.app, .app, .app, .app, .outputDevice, .host])
        XCTAssertEqual(
            commands.map(\.action),
            [.setMuted(true), .setVolume(0.4), .setBoost(3), .setEQBandGain(band: 4, gain: -2.5), .setMuted(false), .refresh]
        )
        for command in commands {
            XCTAssertEqual(command.schemaVersion, WidgetCommand.currentSchemaVersion)
            XCTAssertEqual(command.createdAt, now)
            try command.validate(now: now)
        }
    }

    func testWidgetIntentFactoryRejectsInvalidParametersBeforeEnqueue() {
        XCTAssertNil(WidgetIntentCommandFactory.setAppMuted(appID: "", muted: true))
        XCTAssertNil(WidgetIntentCommandFactory.setAppVolume(appID: "music", volume: 2))
        XCTAssertNil(WidgetIntentCommandFactory.setAppBoost(appID: "music", boost: 5))
        XCTAssertNil(WidgetIntentCommandFactory.setEQBandGain(appID: "music", band: 10, gain: 0))
        XCTAssertNil(WidgetIntentCommandFactory.setEQBandGain(appID: "music", band: 0, gain: 25))
        XCTAssertNil(WidgetIntentCommandFactory.setOutputDeviceMuted(deviceID: "", muted: true))
    }

    func testSnapshotDecodingDefaultsMalformedFieldsAndNormalizesEQ() throws {
        let data = Data(
            """
            {
              "activeAppCount": -4,
              "volumeStep": "NaN",
              "devices": [
                {"id": "built-in", "name": "Speakers", "volume": -2},
                {"id": "", "name": "Invalid"}
              ],
              "apps": [
                {
                  "id": "music",
                  "displayName": "Music",
                  "level": 2,
                  "volume": "NaN",
                  "boost": 99,
                  "eqGains": ["NaN", 50, -50],
                  "eqRange": 12
                }
              ]
            }
            """.utf8
        )

        let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: data)

        XCTAssertEqual(snapshot.hostState, .stopped)
        XCTAssertFalse(snapshot.isHostAvailable())
        XCTAssertEqual(snapshot.activeAppCount, 0)
        XCTAssertEqual(snapshot.volumeStep, 0.05)
        XCTAssertEqual(snapshot.devices.count, 1)
        XCTAssertEqual(snapshot.devices[0].volume, 0)
        XCTAssertEqual(snapshot.apps[0].level, 1)
        XCTAssertEqual(snapshot.apps[0].volume, 1)
        XCTAssertEqual(snapshot.apps[0].boost, 1)
        XCTAssertEqual(snapshot.apps[0].eqGains, [0, 12, -12, 0, 0, 0, 0, 0, 0, 0])
    }

    func testSnapshotRoundTripsThroughSharedWireModel() throws {
        let now = Date(timeIntervalSince1970: 1_234)
        let snapshot = WidgetSnapshot(
            generatedAt: now,
            hostState: .running,
            hostUpdatedAt: now,
            statusMessage: "Ready",
            activeAppCount: 1,
            volumeStep: 0.05,
            devices: [
                .init(id: "built-in", name: "Speakers", volume: 0.75, isMuted: false, isDefault: true)
            ],
            apps: [
                .init(
                    id: "com.example.Music",
                    displayName: "Music",
                    isActive: true,
                    isPinned: false,
                    level: 0.5,
                    volume: 0.8,
                    isMuted: false,
                    boost: 2,
                    routeLabel: "Speakers",
                    eqGains: Array(repeating: 0, count: 10),
                    eqRange: 12
                )
            ]
        )

        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: encoded)

        XCTAssertEqual(decoded, snapshot)
    }

    func testEveryNormalizedCommandActionRoundTripsAndValidates() throws {
        let now = Date()
        let commands: [WidgetCommand] = [
            .app(identity: "music", action: .setMuted(true), createdAt: now),
            .app(identity: "music", action: .setVolume(0.4), createdAt: now),
            .app(identity: "music", action: .setBoost(3), createdAt: now),
            .app(identity: "music", action: .setEQBandGain(band: 4, gain: -1.5), createdAt: now),
            .outputDevice(identity: "built-in", muted: true, createdAt: now),
            .refresh(createdAt: now)
        ]

        for command in commands { try command.validate(now: now) }
        let encoded = try JSONEncoder().encode(commands)
        let decoded = try JSONDecoder().decode([WidgetCommand].self, from: encoded)

        XCTAssertEqual(decoded, commands)
    }

    func testValidationRejectsStaleUnsupportedAndMismatchedCommandsPredictably() {
        let now = Date()
        let expired = WidgetCommand.app(
            identity: "music",
            action: .setMuted(true),
            createdAt: now.addingTimeInterval(-60),
            lifetime: 10
        )
        let unsupported = WidgetCommand(
            schemaVersion: 99,
            createdAt: now,
            targetType: .host,
            targetIdentity: nil,
            action: .refresh
        )
        let mismatched = WidgetCommand(
            createdAt: now,
            targetType: .outputDevice,
            targetIdentity: "speakers",
            action: .setVolume(0.5)
        )
        let invalidValue = WidgetCommand.app(identity: "music", action: .setVolume(2), createdAt: now)

        XCTAssertThrowsError(try expired.validate(now: now)) {
            XCTAssertEqual($0 as? WidgetCommandValidationError, .expired)
        }
        XCTAssertThrowsError(try unsupported.validate(now: now)) {
            XCTAssertEqual($0 as? WidgetCommandValidationError, .unsupportedSchema)
        }
        XCTAssertThrowsError(try mismatched.validate(now: now)) {
            XCTAssertEqual($0 as? WidgetCommandValidationError, .invalidAction)
        }
        XCTAssertThrowsError(try invalidValue.validate(now: now)) {
            XCTAssertEqual($0 as? WidgetCommandValidationError, .invalidValue)
        }
    }

    func testHostLeaseMakesClosedHostExplicitAndTimelinePollsFastOnlyForPendingWork() {
        let now = Date()
        let running = WidgetSnapshot(
            generatedAt: now,
            hostState: .running,
            hostUpdatedAt: now,
            statusMessage: "Ready",
            activeAppCount: 0,
            volumeStep: 0.05,
            devices: [],
            apps: []
        )
        let stopped = WidgetSnapshot(
            generatedAt: now,
            hostState: .stopped,
            hostUpdatedAt: now,
            statusMessage: "Open EQMacRep",
            activeAppCount: 0,
            volumeStep: 0.05,
            devices: [],
            apps: []
        )

        XCTAssertTrue(running.isHostAvailable(at: now))
        XCTAssertFalse(running.isHostAvailable(at: now.addingTimeInterval(16)))
        XCTAssertFalse(stopped.isHostAvailable(at: now))
        XCTAssertEqual(
            WidgetTimelineRefreshPolicy.nextRefresh(now: now, snapshot: running, hasPendingCommand: true),
            now.addingTimeInterval(1)
        )
        XCTAssertEqual(
            WidgetTimelineRefreshPolicy.nextRefresh(now: now, snapshot: running, hasPendingCommand: false),
            now.addingTimeInterval(15)
        )
        XCTAssertEqual(
            WidgetTimelineRefreshPolicy.nextRefresh(now: now, snapshot: stopped, hasPendingCommand: false),
            now.addingTimeInterval(60)
        )
    }

    func testResultRoundTripsWithAppliedSnapshotRevision() throws {
        let result = WidgetCommandResult(
            commandID: UUID(),
            completedAt: Date(timeIntervalSince1970: 5_000),
            status: .applied,
            message: "Applied",
            snapshotGeneratedAt: Date(timeIntervalSince1970: 4_999)
        )

        let data = try JSONEncoder().encode(result)
        XCTAssertEqual(try JSONDecoder().decode(WidgetCommandResult.self, from: data), result)
    }
}
