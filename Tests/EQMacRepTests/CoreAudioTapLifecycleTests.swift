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

    func testTapIOControllerRetainsOrderedOutputDeviceUIDs() {
        let controller = CoreAudioTapIOController(
            target: CoreAudioTapTarget(
                identity: AudioAppIdentity(rawValue: "com.example.Music"),
                displayName: "Music",
                processObjectIDs: [10]
            ),
            outputDeviceUIDs: ["usb", "hdmi"],
            initialGainState: CoreAudioRealtimeGainState(volume: 1, boost: .x1, isMuted: false),
            operations: FakeActiveTapOperations()
        )

        XCTAssertEqual(controller.outputDeviceUIDs, ["usb", "hdmi"])
    }

    func testMultiOutputRequiresMatchingFiniteNominalSampleRates() {
        XCTAssertEqual(
            CoreAudioTapIOController.compatibleNominalSampleRate([48_000, 48_000]),
            48_000
        )
        XCTAssertNil(CoreAudioTapIOController.compatibleNominalSampleRate([44_100, 48_000]))
        XCTAssertNil(CoreAudioTapIOController.compatibleNominalSampleRate([48_000, .nan]))
        XCTAssertNil(CoreAudioTapIOController.compatibleNominalSampleRate([]))
    }

    func testActiveAggregateSubdevicesAreComparedByNormalizedUID() {
        XCTAssertEqual(
            CoreAudioTapIOController.inactiveRequestedUIDs(
                requested: ["usb", " hdmi ", "usb", "missing"],
                active: ["hdmi", "usb"]
            ),
            ["missing"]
        )
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
        try manager.setRoute(music, .selectedDevice("usb"))

        // First controller built on default, second on the newly selected device;
        // the old (default) controller is stopped after the new one starts.
        XCTAssertEqual(factory.createdOutputUIDSets, [["built-in-output"], ["usb"]])
        XCTAssertEqual(factory.stoppedOutputUIDSets, [["built-in-output"]])
        XCTAssertEqual(manager.resolvedOutputUID(for: music), "usb")
        XCTAssertEqual(manager.resolvedOutputUIDs(for: music), ["usb"])
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
        try manager.setRoute(music, .selectedDevice("built-in-output"))

        XCTAssertEqual(factory.createdOutputUIDSets, [["built-in-output"]])
        XCTAssertTrue(factory.stoppedOutputUIDSets.isEmpty)
    }

    func testMultiOutputRouteRebuildsControllerWithOrderedDeviceSet() throws {
        let factory = FakeControllerFactory()
        let manager = CoreAudioProcessTapManager(
            operations: FakeTapOperations(),
            controllerFactory: factory.make
        )
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        manager.setAvailableOutputUIDs(["built-in", "usb", "hdmi"], defaultOutputUID: "built-in")
        try manager.reconcile(targets: [
            CoreAudioTapTarget(identity: music, displayName: "Music", processObjectIDs: [10])
        ])

        try manager.setRoute(music, .multiOutput(["hdmi", "missing", "usb", "hdmi"]))

        XCTAssertEqual(factory.createdOutputUIDSets, [["built-in"], ["hdmi", "usb"]])
        XCTAssertEqual(factory.stoppedOutputUIDSets, [["built-in"]])
        XCTAssertEqual(manager.resolvedOutputUIDs(for: music), ["hdmi", "usb"])
    }

    func testAvailableDeviceChangeRebuildsOnlyWhenResolvedMultiOutputSetChanges() throws {
        let factory = FakeControllerFactory()
        let manager = CoreAudioProcessTapManager(
            operations: FakeTapOperations(),
            controllerFactory: factory.make
        )
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        manager.setAvailableOutputUIDs(["built-in", "usb", "hdmi"], defaultOutputUID: "built-in")
        try manager.setRoute(music, .multiOutput(["usb", "hdmi"]))
        try manager.reconcile(targets: [
            CoreAudioTapTarget(identity: music, displayName: "Music", processObjectIDs: [10])
        ])

        manager.setAvailableOutputUIDs(["built-in", "usb", "hdmi", "unused"], defaultOutputUID: "built-in")
        manager.setAvailableOutputUIDs(["built-in", "hdmi"], defaultOutputUID: "built-in")
        manager.setAvailableOutputUIDs(["built-in", "usb", "hdmi"], defaultOutputUID: "built-in")

        XCTAssertEqual(factory.createdOutputUIDSets, [["usb", "hdmi"], ["hdmi"], ["usb", "hdmi"]])
        XCTAssertEqual(factory.stoppedOutputUIDSets, [["usb", "hdmi"], ["hdmi"]])
        XCTAssertEqual(manager.resolvedOutputUIDs(for: music), ["usb", "hdmi"])
    }

    func testNominalSampleRateChangeRebuildsUnchangedResolvedOutputs() throws {
        let factory = FakeControllerFactory()
        let manager = CoreAudioProcessTapManager(
            operations: FakeTapOperations(),
            controllerFactory: factory.make
        )
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        manager.setAvailableOutputUIDs(
            ["built-in", "usb"],
            defaultOutputUIDs: ["built-in"],
            nominalSampleRatesByUID: ["built-in": 48_000, "usb": 48_000]
        )
        try manager.setRoute(music, .multiOutput(["usb", "built-in"]))
        try manager.reconcile(targets: [
            CoreAudioTapTarget(identity: music, displayName: "Music", processObjectIDs: [10])
        ])

        manager.setAvailableOutputUIDs(
            ["built-in", "usb"],
            defaultOutputUIDs: ["built-in"],
            nominalSampleRatesByUID: ["built-in": 44_100, "usb": 44_100]
        )

        XCTAssertEqual(factory.createdOutputUIDSets, [["usb", "built-in"], ["usb", "built-in"]])
        XCTAssertEqual(factory.stoppedOutputUIDSets, [["usb", "built-in"]])
    }

    func testMultiOutputRouteFallsBackWhenEverySelectedDeviceDisappears() throws {
        let factory = FakeControllerFactory()
        let manager = CoreAudioProcessTapManager(
            operations: FakeTapOperations(),
            controllerFactory: factory.make
        )
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        manager.setAvailableOutputUIDs(["built-in", "usb"], defaultOutputUID: "built-in")
        try manager.setRoute(music, .multiOutput(["usb"]))
        try manager.reconcile(targets: [
            CoreAudioTapTarget(identity: music, displayName: "Music", processObjectIDs: [10])
        ])

        manager.setAvailableOutputUIDs(["built-in"], defaultOutputUID: "built-in")

        XCTAssertEqual(factory.createdOutputUIDSets, [["usb"], ["built-in"]])
        XCTAssertEqual(factory.stoppedOutputUIDSets, [["usb"]])
        XCTAssertEqual(manager.resolvedOutputUIDs(for: music), ["built-in"])
    }

    func testTapOnlySessionPromotesToControllerWhenOutputBecomesAvailable() throws {
        let operations = FakeTapOperations()
        let factory = FakeControllerFactory()
        let manager = CoreAudioProcessTapManager(
            operations: operations,
            controllerFactory: factory.make
        )
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        try manager.reconcile(targets: [
            CoreAudioTapTarget(identity: music, displayName: "Music", processObjectIDs: [10])
        ])

        XCTAssertEqual(operations.created.map(\.identity), [music])
        XCTAssertTrue(factory.createdOutputUIDSets.isEmpty)
        XCTAssertEqual(manager.health.issueCount, 1)
        XCTAssertEqual(manager.health.failedAppMessages[music], "Output device unavailable")

        manager.setAvailableOutputUIDs(["built-in"], defaultOutputUID: "built-in")

        XCTAssertEqual(operations.destroyed, [1000])
        XCTAssertEqual(factory.createdOutputUIDSets, [["built-in"]])
        XCTAssertEqual(manager.resolvedOutputUIDs(for: music), ["built-in"])
        XCTAssertEqual(manager.health.activeAppCount, 1)
    }

    func testTapOnlySessionPromotesImmediatelyWhenUserSelectsAvailableOutput() throws {
        let operations = FakeTapOperations()
        let factory = FakeControllerFactory()
        let manager = CoreAudioProcessTapManager(
            operations: operations,
            controllerFactory: factory.make
        )
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        manager.setAvailableOutputUIDs(["usb"], defaultOutputUID: nil)
        try manager.reconcile(targets: [
            CoreAudioTapTarget(identity: music, displayName: "Music", processObjectIDs: [10])
        ])

        try manager.setRoute(music, .selectedDevice("usb"))

        XCTAssertEqual(operations.destroyed, [1000])
        XCTAssertEqual(factory.createdOutputUIDSets, [["usb"]])
        XCTAssertEqual(manager.resolvedOutputUIDs(for: music), ["usb"])
        XCTAssertEqual(manager.health.activeAppCount, 1)
    }

    func testFollowAggregateDefaultStartsControllerWithAllPhysicalOutputs() throws {
        let factory = FakeControllerFactory()
        let manager = CoreAudioProcessTapManager(
            operations: FakeTapOperations(),
            controllerFactory: factory.make
        )
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        manager.setAvailableOutputUIDs(
            ["built-in", "usb", "hdmi"],
            defaultOutputUIDs: ["hdmi", "usb"]
        )

        try manager.reconcile(targets: [
            CoreAudioTapTarget(identity: music, displayName: "Music", processObjectIDs: [10])
        ])

        XCTAssertEqual(factory.createdOutputUIDSets, [["hdmi", "usb"]])
        XCTAssertEqual(manager.resolvedOutputUIDs(for: music), ["hdmi", "usb"])
    }

    func testFailedRouteRebuildThrowsAndKeepsPreviousControllerAndRoute() throws {
        let factory = FailsOnRebuildControllerFactory()
        let manager = CoreAudioProcessTapManager(
            operations: FakeTapOperations(),
            controllerFactory: factory.make
        )
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        manager.setAvailableOutputUIDs(["built-in", "usb"], defaultOutputUID: "built-in")
        try manager.reconcile(targets: [
            CoreAudioTapTarget(identity: music, displayName: "Music", processObjectIDs: [10])
        ])

        XCTAssertThrowsError(try manager.setRoute(music, .multiOutput(["usb", "built-in"])))

        XCTAssertEqual(manager.resolvedOutputUIDs(for: music), ["built-in"])
        XCTAssertTrue(factory.stoppedOutputUIDSets.isEmpty)
        XCTAssertEqual(manager.health.issueCount, 1)
    }

    func testUnchangedTopologyDoesNotRepeatFailedAutomaticRebuild() throws {
        let factory = FailsOnRebuildControllerFactory()
        var now = Date(timeIntervalSince1970: 0)
        let manager = CoreAudioProcessTapManager(
            operations: FakeTapOperations(),
            automaticRetryCooldown: 10,
            now: { now },
            controllerFactory: factory.make
        )
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        manager.setAvailableOutputUIDs(["built-in", "usb"], defaultOutputUID: "built-in")
        try manager.setRoute(music, .multiOutput(["usb", "built-in"]))
        try manager.reconcile(targets: [
            CoreAudioTapTarget(identity: music, displayName: "Music", processObjectIDs: [10])
        ])

        manager.setAvailableOutputUIDs(["built-in"], defaultOutputUID: "built-in")
        manager.setAvailableOutputUIDs(["built-in"], defaultOutputUID: "built-in")

        XCTAssertEqual(factory.attempts, 2)
        XCTAssertEqual(manager.health.issueCount, 1)
        now = now.addingTimeInterval(11)
        manager.setAvailableOutputUIDs(["built-in"], defaultOutputUID: "built-in")
        XCTAssertEqual(factory.attempts, 3, "The same topology should retry after backoff")
        XCTAssertThrowsError(try manager.setRoute(music, .multiOutput(["usb", "built-in"])))
        XCTAssertEqual(factory.attempts, 4, "Explicit route apply should retry immediately")
    }

    func testExplicitRouteChangeResetsInitialStartAttemptCap() throws {
        let factory = FailsFirstNControllerFactory(failureCount: 3)
        let manager = CoreAudioProcessTapManager(
            operations: FakeTapOperations(),
            maxStartAttempts: 3,
            controllerFactory: factory.make
        )
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let target = CoreAudioTapTarget(identity: music, displayName: "Music", processObjectIDs: [10])
        manager.setAvailableOutputUIDs(["built-in", "usb"], defaultOutputUID: "built-in")

        try manager.reconcile(targets: [target])
        try manager.reconcile(targets: [target])
        try manager.reconcile(targets: [target])
        try manager.reconcile(targets: [target])
        XCTAssertEqual(factory.attempts, 3)

        try manager.setRoute(music, .selectedDevice("usb"))
        try manager.reconcile(targets: [target])

        XCTAssertEqual(factory.attempts, 4)
        XCTAssertEqual(manager.resolvedOutputUIDs(for: music), ["usb"])
        XCTAssertEqual(manager.health.activeAppCount, 1)
        XCTAssertEqual(manager.health.issueCount, 0)
    }

    func testFailedTapOnlyPromotionKeepsPlaceholderSession() throws {
        let operations = FakeTapOperations()
        let factory = FailingControllerFactory(error: CoreAudioTapStartFailure.deviceUnavailable)
        let manager = CoreAudioProcessTapManager(
            operations: operations,
            controllerFactory: factory.make
        )
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        try manager.reconcile(targets: [
            CoreAudioTapTarget(identity: music, displayName: "Music", processObjectIDs: [10])
        ])

        manager.setAvailableOutputUIDs(["built-in"], defaultOutputUID: "built-in")

        XCTAssertEqual(manager.activeSessions.map(\.tapObjectID), [1000])
        XCTAssertTrue(operations.destroyed.isEmpty)
        XCTAssertEqual(factory.attempts, 1)
        XCTAssertEqual(manager.health.issueCount, 1)
    }

    func testFailedTapOnlyPromotionRetriesAutomaticallyAfterBackoff() throws {
        let promoted = expectation(description: "Tap-only session promoted")
        let factory = FailsFirstNControllerFactory(failureCount: 1) {
            promoted.fulfill()
        }
        let manager = CoreAudioProcessTapManager(
            operations: FakeTapOperations(),
            automaticRetryCooldown: 0.01,
            controllerFactory: factory.make
        )
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        try manager.reconcile(targets: [
            CoreAudioTapTarget(identity: music, displayName: "Music", processObjectIDs: [10])
        ])

        manager.setAvailableOutputUIDs(["built-in"], defaultOutputUID: "built-in")
        wait(for: [promoted], timeout: 1)

        XCTAssertEqual(factory.attempts, 2)
        XCTAssertEqual(manager.health.activeAppCount, 1)
        XCTAssertEqual(manager.health.issueCount, 0)
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

        XCTAssertEqual(factory.stoppedOutputUIDSets, [["built-in-output"]])
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

        XCTAssertEqual(factory.stoppedOutputUIDSets.count, 2)
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
    let outputDeviceUIDs: [String]
    let identity: AudioAppIdentity
    let onStop: ([String]) -> Void

    init(target: CoreAudioTapTarget, outputDeviceUIDs: [String], onStop: @escaping ([String]) -> Void) {
        self.outputDeviceUIDs = outputDeviceUIDs
        self.identity = target.identity
        self.onStop = onStop
    }

    func start() throws -> CoreAudioTapSession {
        CoreAudioTapSession(identity: identity, tapObjectID: 4242, processObjectIDs: [1])
    }

    func updateGainState(_ state: CoreAudioRealtimeGainState) {}

    func stop() {
        onStop(outputDeviceUIDs)
    }
}

private final class FakeControllerFactory {
    private(set) var createdOutputUIDSets: [[String]] = []
    private(set) var stoppedOutputUIDSets: [[String]] = []

    func make(
        _ target: CoreAudioTapTarget,
        _ outputUIDs: [String],
        _ gainState: CoreAudioRealtimeGainState
    ) throws -> CoreAudioActiveTapControlling {
        createdOutputUIDSets.append(outputUIDs)
        return FakeController(target: target, outputDeviceUIDs: outputUIDs) { [weak self] uids in
            self?.stoppedOutputUIDSets.append(uids)
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
        _ outputUIDs: [String],
        _ gainState: CoreAudioRealtimeGainState
    ) throws -> CoreAudioActiveTapControlling {
        attempts += 1
        throw error
    }
}

private final class FailsOnRebuildControllerFactory {
    private(set) var attempts = 0
    private(set) var stoppedOutputUIDSets: [[String]] = []

    func make(
        _ target: CoreAudioTapTarget,
        _ outputUIDs: [String],
        _ gainState: CoreAudioRealtimeGainState
    ) throws -> CoreAudioActiveTapControlling {
        attempts += 1
        if attempts > 1 {
            throw CoreAudioTapStartFailure.deviceUnavailable
        }
        return FakeController(target: target, outputDeviceUIDs: outputUIDs) { [weak self] uids in
            self?.stoppedOutputUIDSets.append(uids)
        }
    }
}

private final class FailsFirstNControllerFactory {
    private let failureCount: Int
    private let onSuccess: () -> Void
    private(set) var attempts = 0

    init(failureCount: Int, onSuccess: @escaping () -> Void = {}) {
        self.failureCount = failureCount
        self.onSuccess = onSuccess
    }

    func make(
        _ target: CoreAudioTapTarget,
        _ outputUIDs: [String],
        _ gainState: CoreAudioRealtimeGainState
    ) throws -> CoreAudioActiveTapControlling {
        attempts += 1
        if attempts <= failureCount {
            throw CoreAudioTapStartFailure.deviceUnavailable
        }
        onSuccess()
        return FakeController(target: target, outputDeviceUIDs: outputUIDs) { _ in }
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
