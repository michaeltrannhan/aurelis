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
        var curve = EQCurve()
        curve.setGain(4, at: 5)

        manager.setVolume(0.25, for: music)
        manager.setMuted(true, for: music)
        manager.setBoost(.x4, for: music)
        manager.setEQ(curve, for: music)

        XCTAssertEqual(manager.gainState(for: music), CoreAudioRealtimeGainState(volume: 0.25, boost: .x4, isMuted: true, eq: curve))
    }

    func testBackendForwardsEQCommandsToRealtimeTapController() throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let manager = FakeRealtimeTapManager()
        let backend = CoreAudioDiscoveryBackend(
            processDiscovery: CoreAudioProcessDiscovery(),
            deviceDiscovery: CoreAudioDeviceDiscovery(),
            tapManager: manager
        )
        var curve = EQCurve()
        curve.setGain(6, at: 4)

        try backend.apply(.setEQ(music, curve))

        XCTAssertEqual(manager.eqUpdates, [music: curve])
        XCTAssertTrue(backend.pendingCommands.isEmpty)
    }

    func testRouteChangeRebuildsControllerWithSelectedDevice() throws {
        let factory = FakeControllerFactory()
        let manager = CoreAudioProcessTapManager(
            operations: FakeTapOperations(),
            controllerFactory: factory.make
        )
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        manager.setAvailableOutputUIDs(["built-in-output", "usb"], defaultOutputUID: "built-in-output")

        try manager.reconcile(targets: [
            CoreAudioTapTarget(identity: music, displayName: "Music", processObjectIDs: [10])
        ])
        manager.setRoute(music, .selectedDevice("usb"))

        // First controller built on default, second on the newly selected device;
        // the old (default) controller is stopped after the new one starts.
        XCTAssertEqual(factory.createdOutputUIDs, ["built-in-output", "usb"])
        XCTAssertEqual(factory.stoppedOutputUIDs, ["built-in-output"])
        XCTAssertEqual(manager.resolvedOutputUID(for: music), "usb")
    }

    func testUnchangedResolvedRouteDoesNotRebuild() throws {
        let factory = FakeControllerFactory()
        let manager = CoreAudioProcessTapManager(
            operations: FakeTapOperations(),
            controllerFactory: factory.make
        )
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        manager.setAvailableOutputUIDs(["built-in-output", "usb"], defaultOutputUID: "built-in-output")
        try manager.reconcile(targets: [
            CoreAudioTapTarget(identity: music, displayName: "Music", processObjectIDs: [10])
        ])

        // Selecting the already-default device resolves to the same UID: no rebuild.
        manager.setRoute(music, .selectedDevice("built-in-output"))

        XCTAssertEqual(factory.createdOutputUIDs, ["built-in-output"])
        XCTAssertTrue(factory.stoppedOutputUIDs.isEmpty)
    }

    func testFailedTapDoesNotRetryForever() throws {
        let factory = FailingControllerFactory(error: CoreAudioTapStartFailure.unsupportedProcess)
        let manager = CoreAudioProcessTapManager(
            operations: FakeTapOperations(),
            maxStartAttempts: 2,
            controllerFactory: factory.make
        )
        let identity = AudioAppIdentity(rawValue: "com.example.DAW")
        manager.setAvailableOutputUIDs(["built-in-output"], defaultOutputUID: "built-in-output")
        let target = CoreAudioTapTarget(identity: identity, displayName: "DAW", processObjectIDs: [10])

        try manager.reconcile(targets: [target])
        try manager.reconcile(targets: [target])
        try manager.reconcile(targets: [target])

        XCTAssertEqual(factory.attempts, 2)
        XCTAssertEqual(manager.health.failedAppMessages[identity], "App cannot be tapped")
    }

    func testDisappearedAppStopsController() throws {
        let factory = FakeControllerFactory()
        let manager = CoreAudioProcessTapManager(
            operations: FakeTapOperations(),
            controllerFactory: factory.make
        )
        let identity = AudioAppIdentity(rawValue: "com.example.Music")
        manager.setAvailableOutputUIDs(["built-in-output"], defaultOutputUID: "built-in-output")

        try manager.reconcile(targets: [
            CoreAudioTapTarget(identity: identity, displayName: "Music", processObjectIDs: [10])
        ])
        try manager.reconcile(targets: [])

        XCTAssertEqual(factory.stoppedOutputUIDs, ["built-in-output"])
    }

    func testStopAllStopsEveryController() throws {
        let factory = FakeControllerFactory()
        let manager = CoreAudioProcessTapManager(
            operations: FakeTapOperations(),
            controllerFactory: factory.make
        )
        manager.setAvailableOutputUIDs(["built-in-output"], defaultOutputUID: "built-in-output")
        try manager.reconcile(targets: [
            CoreAudioTapTarget(identity: AudioAppIdentity(rawValue: "a"), displayName: "A", processObjectIDs: [1]),
            CoreAudioTapTarget(identity: AudioAppIdentity(rawValue: "b"), displayName: "B", processObjectIDs: [2])
        ])

        manager.stopAll()

        XCTAssertEqual(factory.stoppedOutputUIDs.count, 2)
        XCTAssertTrue(manager.activeSessions.isEmpty)
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

private final class FakeController: CoreAudioActiveTapControlling {
    let outputDeviceUID: String
    let identity: AudioAppIdentity
    let onStop: (String) -> Void

    init(target: CoreAudioTapTarget, outputDeviceUID: String, onStop: @escaping (String) -> Void) {
        self.outputDeviceUID = outputDeviceUID
        self.identity = target.identity
        self.onStop = onStop
    }

    func start() throws -> CoreAudioTapSession {
        CoreAudioTapSession(identity: identity, tapObjectID: 4242, processObjectIDs: [1])
    }

    func updateGainState(_ state: CoreAudioRealtimeGainState) {}

    func stop() {
        onStop(outputDeviceUID)
    }
}

private final class FakeControllerFactory {
    private(set) var createdOutputUIDs: [String] = []
    private(set) var stoppedOutputUIDs: [String] = []

    func make(
        _ target: CoreAudioTapTarget,
        _ outputUID: String,
        _ gainState: CoreAudioRealtimeGainState
    ) throws -> CoreAudioActiveTapControlling {
        createdOutputUIDs.append(outputUID)
        return FakeController(target: target, outputDeviceUID: outputUID) { [weak self] uid in
            self?.stoppedOutputUIDs.append(uid)
        }
    }
}

private final class FailingControllerFactory {
    private let error: Error
    private(set) var attempts = 0

    init(error: Error) {
        self.error = error
    }

    func make(
        _ target: CoreAudioTapTarget,
        _ outputUID: String,
        _ gainState: CoreAudioRealtimeGainState
    ) throws -> CoreAudioActiveTapControlling {
        attempts += 1
        throw error
    }
}

private final class FakeRealtimeTapManager: CoreAudioTapManaging, CoreAudioRealtimeTapControlling {
    private(set) var eqUpdates: [AudioAppIdentity: EQCurve] = [:]
    var activeSessions: [CoreAudioTapSession] = []

    func reconcile(targets: [CoreAudioTapTarget]) throws {}
    func tearDown(identity: AudioAppIdentity) throws {}
    func tearDownAll() throws {}
    func setVolume(_ volume: Double, for identity: AudioAppIdentity) {}
    func setMuted(_ muted: Bool, for identity: AudioAppIdentity) {}
    func setBoost(_ boost: BoostLevel, for identity: AudioAppIdentity) {}

    func setEQ(_ eq: EQCurve, for identity: AudioAppIdentity) {
        eqUpdates[identity] = eq
    }
}
