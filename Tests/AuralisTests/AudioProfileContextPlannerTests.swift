import XCTest
@testable import Auralis

final class AudioProfileContextPlannerTests: XCTestCase {
    private let music = AudioAppIdentity(rawValue: "music")

    func testEnsuringContextsIsIdempotentAndAddsNeutralAppState() throws {
        let existing = AudioProfile(
            name: "Speakers",
            scope: .outputDevice("speakers"),
            activatesAutomatically: false,
            appSettings: [:],
            deviceSettings: [:],
            preferredOutputDeviceID: "speakers"
        )
        var settings = PersistedSettings(
            appSettings: [
                music: AppAudioSettings(displayName: "Music", volume: 0.3, isMuted: true)
            ],
            profiles: [existing]
        )
        let devices = [
            AudioDeviceSnapshot(id: "speakers", name: "Speakers", isDefault: true),
            AudioDeviceSnapshot(id: "usb", name: "USB DAC")
        ]

        AudioProfileContextPlanner.ensureAutomaticDeviceContexts(in: &settings, devices: devices)
        AudioProfileContextPlanner.ensureAutomaticDeviceContexts(in: &settings, devices: devices)

        let contexts = settings.profiles.filter { !$0.scope.isGlobal }
        XCTAssertEqual(Set(contexts.compactMap(\.scope.outputDeviceID)), ["speakers", "usb"])
        XCTAssertEqual(contexts.count, 2)
        let speakerContext = try XCTUnwrap(contexts.first { $0.scope.outputDeviceID == "speakers" })
        XCTAssertTrue(speakerContext.activatesAutomatically)
        XCTAssertEqual(speakerContext.appSettings[music]?.volume, 1)
        XCTAssertFalse(speakerContext.appSettings[music]?.isMuted ?? true)
    }

    func testUpsertKeepsOneOutputContextAndConvertsOlderDuplicateToPreset() throws {
        let oldID = UUID()
        let replacementID = UUID()
        let old = profile(id: oldID, name: "Old", outputID: "usb")
        let replacement = profile(id: replacementID, name: "Replacement", outputID: "usb")
        var settings = PersistedSettings(
            profiles: [old],
            activeLocalProfileID: oldID,
            activeProfileID: oldID
        )

        AudioProfileContextPlanner.upsertOutputConfiguration(
            replacement,
            for: "usb",
            currentOutputID: "usb",
            in: &settings
        )

        let oldResult = try XCTUnwrap(settings.profiles.first { $0.id == oldID })
        XCTAssertTrue(oldResult.scope.isGlobal)
        XCTAssertFalse(oldResult.activatesAutomatically)
        XCTAssertEqual(settings.profiles.filter { $0.scope.outputDeviceID == "usb" }.map(\.id), [replacementID])
        XCTAssertEqual(settings.activeLocalProfileID, replacementID)
        XCTAssertEqual(settings.activeProfileID, replacementID)
    }

    func testUpdatingCurrentContextCapturesOnlyRoutedDeviceSettings() throws {
        let contextID = UUID()
        let timestamp = Date(timeIntervalSinceReferenceDate: 42)
        var settings = PersistedSettings(
            appSettings: [
                music: AppAudioSettings(
                    displayName: "Music",
                    volume: 0.4,
                    route: .multiOutput(["usb", "display"])
                )
            ],
            deviceSettings: [
                "usb": DeviceAudioSettings(displayName: "USB", volume: 0.5, isMuted: false),
                "display": DeviceAudioSettings(displayName: "Display", volume: 0.6, isMuted: false),
                "unused": DeviceAudioSettings(displayName: "Unused", volume: 0.7, isMuted: false)
            ],
            profiles: [profile(id: contextID, name: "USB", outputID: "usb")],
            profileHasOverrides: true
        )

        AudioProfileContextPlanner.updateActiveDeviceContext(
            in: &settings,
            currentOutputID: "usb",
            updatedAt: timestamp
        )

        let context = try XCTUnwrap(settings.profiles.first { $0.id == contextID })
        XCTAssertEqual(context.appSettings, settings.appSettings)
        XCTAssertEqual(Set(context.deviceSettings.keys), ["usb", "display"])
        XCTAssertEqual(context.updatedAt, timestamp)
        XCTAssertEqual(settings.activeLocalProfileID, contextID)
        XCTAssertFalse(settings.profileHasOverrides)
    }

    private func profile(id: UUID, name: String, outputID: String) -> AudioProfile {
        AudioProfile(
            id: id,
            name: name,
            scope: .outputDevice(outputID),
            activatesAutomatically: true,
            appSettings: [:],
            deviceSettings: [:],
            preferredOutputDeviceID: outputID
        )
    }
}
