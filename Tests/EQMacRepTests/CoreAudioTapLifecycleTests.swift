import CoreAudio
import XCTest
@testable import EQMacRep

final class CoreAudioTapLifecycleTests: XCTestCase {
    func testTapTargetUsesAppIdentityAndProcessObjects() {
        let identity = AudioAppIdentity(rawValue: "com.example.Music")
        let target = CoreAudioTapTarget(
            identity: identity,
            displayName: "Music",
            processObjectIDs: [10, 11]
        )

        XCTAssertEqual(target.identity, identity)
        XCTAssertEqual(target.processObjectIDs, [10, 11])
    }

    func testTapManagerCreatesAndDestroysToMatchTargets() throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let safari = AudioAppIdentity(rawValue: "com.example.Safari")
        let operations = FakeTapOperations()
        let manager = CoreAudioProcessTapManager(operations: operations)

        try manager.reconcile(targets: [
            CoreAudioTapTarget(identity: music, displayName: "Music", processObjectIDs: [10]),
            CoreAudioTapTarget(identity: safari, displayName: "Safari", processObjectIDs: [11])
        ])
        try manager.reconcile(targets: [
            CoreAudioTapTarget(identity: safari, displayName: "Safari", processObjectIDs: [11])
        ])

        XCTAssertEqual(operations.created.map(\.identity), [music, safari])
        XCTAssertEqual(operations.destroyed, [1000])
        XCTAssertEqual(manager.activeSessions.map(\.identity), [safari])
    }

    func testActiveResourcesTearDownInSafeOrder() {
        let operations = FakeActiveTapOperations()
        var resources = CoreAudioTapResources(
            tapID: 10,
            aggregateDeviceID: 20,
            ioProcID: unsafeBitCast(0x01, to: AudioDeviceIOProcID.self)
        )

        resources.destroy(using: operations)

        XCTAssertEqual(operations.calls, ["stop:20", "destroyIO:20", "destroyAggregate:20", "destroyTap:10"])
    }

    func testBackendSynchronizesOnlyActiveNonIgnoredTargets() throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let safari = AudioAppIdentity(rawValue: "com.example.Safari")
        let manager = CoreAudioProcessTapManager(operations: FakeTapOperations())
        let backend = CoreAudioDiscoveryBackend(
            processDiscovery: CoreAudioProcessDiscovery(),
            deviceDiscovery: CoreAudioDeviceDiscovery(),
            tapManager: manager
        )
        backend.replaceTapTargetsForTesting([
            CoreAudioTapTarget(identity: music, displayName: "Music", processObjectIDs: [10]),
            CoreAudioTapTarget(identity: safari, displayName: "Safari", processObjectIDs: [11])
        ])

        try backend.synchronizeTaps(activeAppIDs: [music, safari], ignoredAppIDs: [music])

        XCTAssertEqual(manager.activeSessions.map(\.identity), [safari])
    }

    func testManagerUpdatesGainStateForActiveSession() {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let manager = CoreAudioProcessTapManager(operations: FakeTapOperations())

        manager.setVolume(0.25, for: music)
        manager.setMuted(true, for: music)
        manager.setBoost(.x4, for: music)

        XCTAssertEqual(manager.gainState(for: music), CoreAudioRealtimeGainState(volume: 0.25, boost: .x4, isMuted: true))
    }
}

private final class FakeTapOperations: CoreAudioTapOperating {
    var nextTapID: AudioObjectID = 1000
    private(set) var created: [CoreAudioTapTarget] = []
    private(set) var destroyed: [AudioObjectID] = []

    func createTap(for target: CoreAudioTapTarget) throws -> CoreAudioTapSession {
        created.append(target)
        defer { nextTapID += 1 }
        return CoreAudioTapSession(
            identity: target.identity,
            tapObjectID: nextTapID,
            processObjectIDs: target.processObjectIDs
        )
    }

    func destroyTap(_ tapObjectID: AudioObjectID) throws {
        destroyed.append(tapObjectID)
    }
}

private final class FakeActiveTapOperations: CoreAudioActiveTapOperating {
    var calls: [String] = []

    func stopDevice(_ deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID?) -> OSStatus {
        calls.append("stop:\(deviceID)")
        return noErr
    }

    func destroyIOProc(_ deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID?) -> OSStatus {
        calls.append("destroyIO:\(deviceID)")
        return noErr
    }

    func destroyAggregateDevice(_ deviceID: AudioObjectID) -> OSStatus {
        calls.append("destroyAggregate:\(deviceID)")
        return noErr
    }

    func destroyProcessTap(_ tapID: AudioObjectID) -> OSStatus {
        calls.append("destroyTap:\(tapID)")
        return noErr
    }
}
