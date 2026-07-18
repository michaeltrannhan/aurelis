import CoreAudio
import XCTest
@testable import Auralis

final class CoreAudioMappingTests: XCTestCase {
    func testDeviceMappingUsesUIDNameAndDefaultFlag() {
        let record = CoreAudioDeviceDiscovery.DeviceRecord(
            objectID: 42,
            uid: "built-in-output",
            name: "MacBook Speakers",
            hasOutputStreams: true,
            isHidden: false
        )

        let snapshot = CoreAudioDeviceDiscovery.mapDeviceRecord(record, defaultDeviceID: 42)

        XCTAssertEqual(
            snapshot,
            AudioDeviceSnapshot(id: "built-in-output", name: "MacBook Speakers", isDefault: true)
        )
    }

    func testDeviceMappingSkipsHiddenOrInputOnlyDevices() {
        let hidden = CoreAudioDeviceDiscovery.DeviceRecord(
            objectID: 7,
            uid: "hidden",
            name: "Hidden Device",
            hasOutputStreams: true,
            isHidden: true
        )
        let inputOnly = CoreAudioDeviceDiscovery.DeviceRecord(
            objectID: 8,
            uid: "input",
            name: "Input Device",
            hasOutputStreams: false,
            isHidden: false
        )

        XCTAssertNil(CoreAudioDeviceDiscovery.mapDeviceRecord(hidden, defaultDeviceID: nil))
        XCTAssertNil(CoreAudioDeviceDiscovery.mapDeviceRecord(inputOnly, defaultDeviceID: nil))
    }

    func testDeviceMappingSkipsUIDlessAndAggregateDevices() {
        let uidless = CoreAudioDeviceDiscovery.DeviceRecord(
            objectID: 9,
            uid: nil,
            name: "Unknown Output",
            hasOutputStreams: true,
            isHidden: false
        )
        let ownAggregate = CoreAudioDeviceDiscovery.DeviceRecord(
            objectID: 10,
            uid: "Auralis-tap-uuid",
            name: "Auralis-Music",
            hasOutputStreams: true,
            isHidden: false,
            transportType: kAudioDeviceTransportTypeAggregate
        )
        let userAggregate = CoreAudioDeviceDiscovery.DeviceRecord(
            objectID: 11,
            uid: "user-multi-output",
            name: "Living Room Multi-Output",
            hasOutputStreams: true,
            isHidden: false,
            transportType: kAudioDeviceTransportTypeAggregate
        )
        let legacyOwnedOutput = CoreAudioDeviceDiscovery.DeviceRecord(
            objectID: 12,
            uid: "legacy-owned-output",
            name: "EQMacRep-Legacy",
            hasOutputStreams: true,
            isHidden: false
        )
        let autoAggregate = CoreAudioDeviceDiscovery.DeviceRecord(
            objectID: 13,
            uid: "auto-aggregate",
            name: "Automatic Aggregate",
            hasOutputStreams: true,
            isHidden: false,
            transportType: kAudioDeviceTransportTypeAutoAggregate
        )

        XCTAssertNil(CoreAudioDeviceDiscovery.mapDeviceRecord(uidless, defaultDeviceID: nil))
        XCTAssertNil(CoreAudioDeviceDiscovery.mapDeviceRecord(ownAggregate, defaultDeviceID: nil))
        XCTAssertNil(CoreAudioDeviceDiscovery.mapDeviceRecord(userAggregate, defaultDeviceID: nil))
        XCTAssertEqual(
            CoreAudioDeviceDiscovery.mapDeviceRecord(legacyOwnedOutput, defaultDeviceID: nil),
            AudioDeviceSnapshot(id: "legacy-owned-output", name: "EQMacRep-Legacy", isDefault: false)
        )
        XCTAssertNil(CoreAudioDeviceDiscovery.mapDeviceRecord(autoAggregate, defaultDeviceID: nil))
        XCTAssertNil(CoreAudioDeviceDiscovery.defaultOutputUID(records: [userAggregate], defaultDeviceID: 11))
    }

    func testProcessMappingUsesBundleIdentifierAsStableIdentity() {
        let record = CoreAudioProcessDiscovery.ProcessRecord(
            processObjectID: 100,
            processID: 1234,
            bundleIdentifier: "com.apple.Music",
            displayName: "Music",
            executableName: "Music",
            isRunning: true
        )

        let snapshot = CoreAudioProcessDiscovery.mapProcessRecord(record, currentProcessID: 9999)

        XCTAssertEqual(snapshot?.identity.rawValue, "com.apple.Music")
        XCTAssertEqual(snapshot?.displayName, "Music")
        XCTAssertEqual(snapshot?.bundleIdentifier, "com.apple.Music")
        XCTAssertEqual(snapshot?.isActive, true)
    }

    func testProcessMappingFallsBackToNameAndFiltersSelfAndDaemons() {
        let helper = CoreAudioProcessDiscovery.ProcessRecord(
            processObjectID: 101,
            processID: 1235,
            bundleIdentifier: nil,
            displayName: "Browser Helper",
            executableName: "Browser Helper",
            isRunning: true
        )
        let selfProcess = CoreAudioProcessDiscovery.ProcessRecord(
            processObjectID: 102,
            processID: 1236,
            bundleIdentifier: "com.example.Auralis",
            displayName: "Auralis",
            executableName: "Auralis",
            isRunning: true
        )
        let daemon = CoreAudioProcessDiscovery.ProcessRecord(
            processObjectID: 103,
            processID: 1237,
            bundleIdentifier: nil,
            displayName: "coreaudiod",
            executableName: "coreaudiod",
            isRunning: true
        )

        XCTAssertEqual(
            CoreAudioProcessDiscovery.mapProcessRecord(helper, currentProcessID: 9999)?.identity.rawValue,
            "name:Browser Helper"
        )
        XCTAssertNil(CoreAudioProcessDiscovery.mapProcessRecord(selfProcess, currentProcessID: 1236))
        XCTAssertNil(CoreAudioProcessDiscovery.mapProcessRecord(daemon, currentProcessID: 9999))
    }

    func testProcessSnapshotsAreCoalescedByIdentity() {
        let identity = AudioAppIdentity(rawValue: "com.example.Browser")
        let helper = AudioAppSnapshot(
            identity: identity,
            displayName: "Browser Helper",
            bundleIdentifier: identity.rawValue,
            isActive: true,
            level: 0.2
        )
        let app = AudioAppSnapshot(
            identity: identity,
            displayName: "Browser",
            bundleIdentifier: identity.rawValue,
            isActive: true,
            level: 0.4
        )

        let snapshots = CoreAudioProcessDiscovery.coalescedSnapshots([helper, app])

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].displayName, "Browser")
        XCTAssertEqual(snapshots[0].level, 0.4)
    }

    func testRunningHelperProcessMapsToParentAppRecord() {
        let parent = CoreAudioProcessDiscovery.ProcessRecord(
            processObjectID: 200,
            processID: 2000,
            bundleIdentifier: "company.thebrowser.Browser",
            displayName: "Arc",
            executableName: "Arc",
            isRunning: false
        )
        let helper = CoreAudioProcessDiscovery.ProcessRecord(
            processObjectID: 201,
            processID: 2001,
            bundleIdentifier: "company.thebrowser.browser.helper",
            displayName: nil,
            executableName: nil,
            isRunning: true
        )

        let snapshots = CoreAudioProcessDiscovery.mapProcessRecords([helper, parent], currentProcessID: 9999)

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].identity.rawValue, "company.thebrowser.Browser")
        XCTAssertEqual(snapshots[0].displayName, "Arc")
        XCTAssertEqual(snapshots[0].bundleIdentifier, "company.thebrowser.Browser")
    }

    func testProcessRecordsCoalesceIntoTapTargets() {
        let first = CoreAudioProcessDiscovery.ProcessRecord(
            processObjectID: 10,
            processID: 100,
            bundleIdentifier: "com.example.Browser",
            displayName: "Browser Helper",
            executableName: "Browser Helper",
            isRunning: true
        )
        let second = CoreAudioProcessDiscovery.ProcessRecord(
            processObjectID: 11,
            processID: 101,
            bundleIdentifier: "com.example.Browser",
            displayName: "Browser",
            executableName: "Browser",
            isRunning: true
        )

        let targets = CoreAudioProcessDiscovery.mapTapTargets(
            records: [first, second],
            currentProcessID: 999
        )

        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(targets[0].identity.rawValue, "com.example.Browser")
        XCTAssertEqual(targets[0].displayName, "Browser")
        XCTAssertEqual(targets[0].processObjectIDs, [10, 11])
    }

    func testDeviceSnapshotsSortDefaultFirstThenName() {
        let headphones = AudioDeviceSnapshot(id: "headphones", name: "Headphones", isDefault: false)
        let speakers = AudioDeviceSnapshot(id: "speakers", name: "MacBook Speakers", isDefault: true)
        let display = AudioDeviceSnapshot(id: "display", name: "Studio Display", isDefault: false)

        let sorted = CoreAudioDeviceDiscovery.sortedSnapshots([headphones, speakers, display])

        XCTAssertEqual(sorted.map(\.id), ["speakers", "headphones", "display"])
    }

    func testCoalescingPrefersNonHelperName() {
        let identity = AudioAppIdentity(rawValue: "com.example.Browser")
        let helper = AudioAppSnapshot(
            identity: identity,
            displayName: "Browser Helper",
            bundleIdentifier: identity.rawValue
        )
        let renderer = AudioAppSnapshot(
            identity: identity,
            displayName: "Browser Renderer",
            bundleIdentifier: identity.rawValue
        )
        let app = AudioAppSnapshot(
            identity: identity,
            displayName: "Browser",
            bundleIdentifier: identity.rawValue
        )

        let snapshots = CoreAudioProcessDiscovery.coalescedSnapshots([helper, renderer, app])

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].displayName, "Browser")
    }

    func testDefaultOutputUIDComesFromDefaultDeviceRecord() {
        let record = CoreAudioDeviceDiscovery.DeviceRecord(
            objectID: 42,
            uid: "built-in-output",
            name: "MacBook Speakers",
            hasOutputStreams: true,
            isHidden: false
        )

        XCTAssertEqual(CoreAudioDeviceDiscovery.defaultOutputUID(records: [record], defaultDeviceID: 42), "built-in-output")
    }

    func testAggregateDefaultExpandsToOrderedRouteablePhysicalOutputs() {
        let usb = CoreAudioDeviceDiscovery.DeviceRecord(
            objectID: 1,
            uid: "usb",
            name: "USB Interface",
            hasOutputStreams: true,
            isHidden: false
        )
        let hdmi = CoreAudioDeviceDiscovery.DeviceRecord(
            objectID: 2,
            uid: "hdmi",
            name: "Display",
            hasOutputStreams: true,
            isHidden: false
        )
        let hidden = CoreAudioDeviceDiscovery.DeviceRecord(
            objectID: 3,
            uid: "hidden",
            name: "Hidden",
            hasOutputStreams: true,
            isHidden: true
        )
        let inputOnly = CoreAudioDeviceDiscovery.DeviceRecord(
            objectID: 4,
            uid: "input",
            name: "Microphone",
            hasOutputStreams: false,
            isHidden: false
        )
        let nestedAggregate = CoreAudioDeviceDiscovery.DeviceRecord(
            objectID: 5,
            uid: "nested",
            name: "Nested Aggregate",
            hasOutputStreams: true,
            isHidden: false,
            transportType: kAudioDeviceTransportTypeAggregate
        )
        let systemDefault = CoreAudioDeviceDiscovery.DeviceRecord(
            objectID: 10,
            uid: "user-multi-output",
            name: "Living Room Multi-Output",
            hasOutputStreams: true,
            isHidden: false,
            transportType: kAudioDeviceTransportTypeAggregate,
            aggregateSubdeviceUIDs: [" usb ", "missing", "hdmi", "usb", "", "hidden", "input", "nested"],
            aggregateActiveSubdeviceUIDs: ["usb", "hdmi"]
        )

        XCTAssertEqual(
            CoreAudioDeviceDiscovery.defaultOutputUIDs(
                records: [systemDefault, hidden, nestedAggregate, hdmi, inputOnly, usb],
                defaultDeviceID: 10
            ),
            ["usb", "hdmi"]
        )
        XCTAssertEqual(
            CoreAudioDeviceDiscovery.defaultOutputUID(
                records: [systemDefault, usb, hdmi],
                defaultDeviceID: 10
            ),
            "usb"
        )
    }

    func testAggregateDefaultWithoutPhysicalOutputsIsUnavailable() {
        let systemDefault = CoreAudioDeviceDiscovery.DeviceRecord(
            objectID: 10,
            uid: "user-multi-output",
            name: "Living Room Multi-Output",
            hasOutputStreams: true,
            isHidden: false,
            transportType: kAudioDeviceTransportTypeAggregate,
            aggregateSubdeviceUIDs: ["missing"]
        )

        XCTAssertEqual(
            CoreAudioDeviceDiscovery.defaultOutputUIDs(records: [systemDefault], defaultDeviceID: 10),
            []
        )
    }

    func testAggregateDefaultNamedLikeAuralisIsStillRouteableWithoutOwnedUID() {
        let usb = CoreAudioDeviceDiscovery.DeviceRecord(
            objectID: 1,
            uid: "usb",
            name: "USB Interface",
            hasOutputStreams: true,
            isHidden: false
        )
        let userAggregate = CoreAudioDeviceDiscovery.DeviceRecord(
            objectID: 10,
            uid: "user-created-aggregate",
            name: "Auralis-Manual Mix",
            hasOutputStreams: true,
            isHidden: false,
            transportType: kAudioDeviceTransportTypeAggregate,
            aggregateSubdeviceUIDs: ["usb"]
        )

        XCTAssertEqual(
            CoreAudioDeviceDiscovery.defaultOutputUIDs(
                records: [userAggregate, usb],
                defaultDeviceID: 10
            ),
            ["usb"]
        )
    }

    func testOwnedAggregateDefaultIsNotExpandedIntoItsConstituents() {
        let usb = CoreAudioDeviceDiscovery.DeviceRecord(
            objectID: 1,
            uid: "usb",
            name: "USB Interface",
            hasOutputStreams: true,
            isHidden: false
        )
        let ownedAggregate = CoreAudioDeviceDiscovery.DeviceRecord(
            objectID: 10,
            uid: "Auralis-\(UUID().uuidString)",
            name: "Auralis-Music",
            hasOutputStreams: true,
            isHidden: false,
            transportType: kAudioDeviceTransportTypeAggregate,
            aggregateSubdeviceUIDs: ["usb"]
        )

        XCTAssertEqual(
            CoreAudioDeviceDiscovery.defaultOutputUIDs(
                records: [ownedAggregate, usb],
                defaultDeviceID: 10
            ),
            []
        )
    }

    func testAggregateDefaultOmitsPresentButInactiveConstituents() {
        let usb = CoreAudioDeviceDiscovery.DeviceRecord(
            objectID: 1,
            uid: "usb",
            name: "USB Interface",
            hasOutputStreams: true,
            isHidden: false
        )
        let hdmi = CoreAudioDeviceDiscovery.DeviceRecord(
            objectID: 2,
            uid: "hdmi",
            name: "Display",
            hasOutputStreams: true,
            isHidden: false
        )
        let systemDefault = CoreAudioDeviceDiscovery.DeviceRecord(
            objectID: 10,
            uid: "user-multi-output",
            name: "Living Room Multi-Output",
            hasOutputStreams: true,
            isHidden: false,
            transportType: kAudioDeviceTransportTypeAggregate,
            aggregateSubdeviceUIDs: ["usb", "hdmi"],
            aggregateActiveSubdeviceUIDs: ["hdmi"]
        )

        XCTAssertEqual(
            CoreAudioDeviceDiscovery.defaultOutputUIDs(
                records: [systemDefault, usb, hdmi],
                defaultDeviceID: 10
            ),
            ["hdmi"]
        )
    }
}
