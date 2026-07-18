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
        let factory = FakeControllerFactory()
        let manager = CoreAudioProcessTapManager(
            operations: operations,
            controllerFactory: factory.make
        )
        manager.setAvailableOutputUIDs(["built-in"], defaultOutputUID: "built-in")

        try manager.reconcile(targets: [
            CoreAudioTapTarget(identity: music, displayName: "Music", processObjectIDs: [10]),
            CoreAudioTapTarget(identity: safari, displayName: "Safari", processObjectIDs: [11])
        ])
        try manager.reconcile(targets: [
            CoreAudioTapTarget(identity: safari, displayName: "Safari", processObjectIDs: [11])
        ])

        XCTAssertTrue(operations.created.isEmpty, "No unrouted placeholder taps should be created")
        XCTAssertTrue(operations.destroyed.isEmpty)
        XCTAssertEqual(factory.createdOutputUIDSets, [["built-in"], ["built-in"]])
        XCTAssertEqual(factory.stoppedOutputUIDSets, [["built-in"]])
        XCTAssertEqual(manager.activeSessions.map(\.identity), [safari])
    }

    func testActiveResourcesTearDownInSafeOrder() throws {
        let operations = FakeActiveTapOperations()
        var resources = CoreAudioTapResources(
            tapID: 10,
            aggregateDeviceID: 20,
            ioProcID: unsafeBitCast(0x01, to: AudioDeviceIOProcID.self)
        )

        try resources.destroy(using: operations)

        XCTAssertEqual(operations.calls, ["stop:20", "destroyIO:20", "destroyAggregate:20", "destroyTap:10"])
    }

    func testAggregateJournalEntryIsRemovedOnlyAfterSuccessfulDestruction() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EQMacRepResourceJournal-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("aggregate-ownership.json")
        let journal = CoreAudioAggregateOwnershipJournal(journalURL: url)
        let uid = "\(CoreAudioOrphanedAggregateCleanup.aggregateUIDPrefix)\(UUID().uuidString)"
        try journal.recordAggregate(uid: uid, deviceID: 20)
        var resources = CoreAudioTapResources(
            tapID: 10,
            aggregateDeviceID: 20,
            ioProcID: nil,
            aggregateDeviceUID: uid
        )

        try resources.destroy(using: FakeActiveTapOperations(), ownershipJournal: journal)

        XCTAssertTrue(try journal.records().isEmpty)
    }

    func testFailedAggregateDestructionLeavesOwnershipJournalForRecovery() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EQMacRepResourceJournal-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("aggregate-ownership.json")
        let journal = CoreAudioAggregateOwnershipJournal(journalURL: url)
        let uid = "\(CoreAudioOrphanedAggregateCleanup.aggregateUIDPrefix)\(UUID().uuidString)"
        try journal.recordAggregate(uid: uid, deviceID: 20)
        var resources = CoreAudioTapResources(
            tapID: 10,
            aggregateDeviceID: 20,
            ioProcID: nil,
            aggregateDeviceUID: uid
        )

        XCTAssertThrowsError(try resources.destroy(
            using: FakeActiveTapOperations(aggregateDestroyStatus: -1),
            ownershipJournal: journal
        ))

        XCTAssertEqual(try journal.records().map(\.aggregateUID), [uid])
        XCTAssertEqual(resources.aggregateDeviceID, 20)
        XCTAssertEqual(resources.aggregateDeviceUID, uid)

        try resources.destroy(
            using: FakeActiveTapOperations(),
            ownershipJournal: journal
        )
        XCTAssertFalse(resources.ownsResources)
        XCTAssertTrue(try journal.records().isEmpty)
    }

    func testJournalRemovalFailureRetainsUIDAndRetriesWithoutRedestroyingHandles() throws {
        let operations = FakeActiveTapOperations()
        let journal = FailsFirstRemoveJournal()
        let uid = "\(CoreAudioOrphanedAggregateCleanup.aggregateUIDPrefix)\(UUID().uuidString)"
        var resources = CoreAudioTapResources(
            tapID: 10,
            aggregateDeviceID: 20,
            ioProcID: nil,
            aggregateDeviceUID: uid
        )

        XCTAssertThrowsError(try resources.destroy(
            using: operations,
            ownershipJournal: journal
        ))
        XCTAssertEqual(operations.calls, ["destroyAggregate:20", "destroyTap:10"])
        XCTAssertEqual(resources.aggregateDeviceID, AudioObjectID(kAudioObjectUnknown))
        XCTAssertEqual(resources.tapID, AudioObjectID(kAudioObjectUnknown))
        XCTAssertEqual(resources.aggregateDeviceUID, uid)
        XCTAssertTrue(resources.ownsResources)

        try resources.destroy(using: operations, ownershipJournal: journal)

        XCTAssertEqual(operations.calls, ["destroyAggregate:20", "destroyTap:10"])
        XCTAssertEqual(journal.removeAttempts, 2)
        XCTAssertFalse(resources.ownsResources)
    }

    func testFailedIOProcDestructionPreservesDependentHandlesAndStillAttemptsTap() {
        let operations = FakeActiveTapOperations(ioProcDestroyStatus: -2)
        var resources = CoreAudioTapResources(
            tapID: 10,
            aggregateDeviceID: 20,
            ioProcID: unsafeBitCast(0x01, to: AudioDeviceIOProcID.self),
            aggregateDeviceUID: "EQMacRep-test"
        )

        XCTAssertThrowsError(try resources.destroy(using: operations)) { error in
            XCTAssertEqual(
                (error as? CoreAudioTapResourceTeardownError)?.failures.map(\.operation),
                [.destroyIOProc]
            )
        }

        XCTAssertEqual(operations.calls, ["stop:20", "destroyIO:20", "destroyTap:10"])
        XCTAssertNotNil(resources.ioProcID)
        XCTAssertEqual(resources.aggregateDeviceID, 20)
        XCTAssertEqual(resources.tapID, AudioObjectID(kAudioObjectUnknown))
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

    func testActiveAggregateSubdevicesAreComparedByNormalizedUID() {
        XCTAssertEqual(
            CoreAudioTapIOController.inactiveRequestedUIDs(
                requested: ["usb", " hdmi ", "usb", "missing"],
                active: ["hdmi", "usb"]
            ),
            ["missing"]
        )
    }

    func testAggregateReadinessProbeRetriesUntilHALPublishesStreams() throws {
        var attempts = 0
        var waits = 0

        let value: Int = try CoreAudioAggregateReadiness.resolve(
            attemptLimit: 4,
            wait: { waits += 1 }
        ) {
            attempts += 1
            if attempts < 3 { throw TestTapLifecycleError.stopFailed }
            return 42
        }

        XCTAssertEqual(value, 42)
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(waits, 2)
    }

    func testBackendSynchronizesOnlyActiveNonIgnoredTargets() throws {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let safari = AudioAppIdentity(rawValue: "com.example.Safari")
        let factory = FakeControllerFactory()
        let manager = CoreAudioProcessTapManager(
            operations: FakeTapOperations(),
            controllerFactory: factory.make
        )
        manager.setAvailableOutputUIDs(["built-in"], defaultOutputUID: "built-in")
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

    func testNominalSampleRateChangeDoesNotRaceControllerRateListenerWithRebuild() throws {
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

        XCTAssertEqual(factory.createdOutputUIDSets, [["usb", "built-in"]])
        XCTAssertTrue(factory.stoppedOutputUIDSets.isEmpty)
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

    func testNoOutputRouteKeepsDesiredStateWithoutCreatingPlaceholderTap() throws {
        let operations = FakeTapOperations()
        let factory = FakeControllerFactory()
        let scheduler = ManualTapRetryScheduler()
        let manager = CoreAudioProcessTapManager(
            operations: operations,
            automaticRetryCooldown: 10,
            retryScheduler: scheduler.schedule,
            controllerFactory: factory.make
        )
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        try manager.reconcile(targets: [
            CoreAudioTapTarget(identity: music, displayName: "Music", processObjectIDs: [10])
        ])

        XCTAssertTrue(operations.created.isEmpty)
        XCTAssertTrue(manager.activeSessions.isEmpty)
        XCTAssertTrue(factory.createdOutputUIDSets.isEmpty)
        XCTAssertEqual(manager.health.issueCount, 1)
        XCTAssertEqual(manager.health.failedAppMessages[music], "Output device unavailable")
        XCTAssertEqual(manager.lifecycleSnapshot(for: music)?.phase, .retrying)
        XCTAssertEqual(manager.lifecycleSnapshot(for: music)?.hasTarget, true)

        manager.setAvailableOutputUIDs(["built-in"], defaultOutputUID: "built-in")

        XCTAssertTrue(operations.destroyed.isEmpty)
        XCTAssertEqual(factory.createdOutputUIDSets, [["built-in"]])
        XCTAssertEqual(manager.resolvedOutputUIDs(for: music), ["built-in"])
        XCTAssertEqual(manager.health.activeAppCount, 1)
    }

    func testDesiredAppStartsImmediatelyWhenUserSelectsAvailableOutput() throws {
        let operations = FakeTapOperations()
        let factory = FakeControllerFactory()
        let scheduler = ManualTapRetryScheduler()
        let manager = CoreAudioProcessTapManager(
            operations: operations,
            automaticRetryCooldown: 10,
            retryScheduler: scheduler.schedule,
            controllerFactory: factory.make
        )
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        manager.setAvailableOutputUIDs(["usb"], defaultOutputUID: nil)
        try manager.reconcile(targets: [
            CoreAudioTapTarget(identity: music, displayName: "Music", processObjectIDs: [10])
        ])

        try manager.setRoute(music, .selectedDevice("usb"))

        XCTAssertTrue(operations.created.isEmpty)
        XCTAssertTrue(operations.destroyed.isEmpty)
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
        XCTAssertEqual(manager.lifecycleSnapshot(for: music)?.phase, .running)
        XCTAssertEqual(manager.health.issueCount, 0)
    }

    func testFailedReplacementCleanupRetriesThenResumesOldController() throws {
        let scheduler = ManualTapRetryScheduler()
        let factory = StartFailureControllerFactory(
            succeedsFirst: true,
            startError: CoreAudioTapStartFailure.deviceUnavailable,
            cleanupFailuresBeforeSuccess: 1
        )
        let manager = CoreAudioProcessTapManager(
            operations: FakeTapOperations(),
            automaticRetryCooldown: 0.01,
            retryScheduler: scheduler.schedule,
            controllerFactory: factory.make
        )
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        manager.setAvailableOutputUIDs(["built-in", "usb"], defaultOutputUID: "built-in")
        try manager.reconcile(targets: [
            CoreAudioTapTarget(identity: music, displayName: "Music", processObjectIDs: [10])
        ])

        XCTAssertThrowsError(try manager.setRoute(music, .selectedDevice("usb")))
        XCTAssertEqual(manager.lifecycleSnapshot(for: music)?.phase, .stopping)
        XCTAssertEqual(manager.lifecycleSnapshot(for: music)?.ownedControllerCount, 2)

        scheduler.runUntilIdle()

        XCTAssertEqual(factory.makeAttempts, 2, "A rolled-back route must not restart the rejected replacement")
        XCTAssertEqual(factory.failingControllers.first?.startAttempts, 1)
        XCTAssertEqual(factory.failingControllers.first?.stopAttempts, 2)
        XCTAssertEqual(manager.lifecycleSnapshot(for: music)?.ownedControllerCount, 1)
        XCTAssertEqual(manager.resolvedOutputUIDs(for: music), ["built-in"])
        XCTAssertEqual(manager.health.issueCount, 0)
    }

    func testTerminalStartFailureBoundsCleanupRetriesWithoutRestarting() throws {
        let scheduler = ManualTapRetryScheduler()
        let factory = StartFailureControllerFactory(
            startError: CoreAudioTapStartFailure.fatal("invalid tap format"),
            cleanupFailuresBeforeSuccess: .max
        )
        let manager = CoreAudioProcessTapManager(
            operations: FakeTapOperations(),
            maxStartAttempts: 3,
            automaticRetryCooldown: 0.005,
            retryScheduler: scheduler.schedule,
            controllerFactory: factory.make
        )
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        manager.setAvailableOutputUIDs(["built-in"], defaultOutputUID: "built-in")

        try manager.reconcile(targets: [
            CoreAudioTapTarget(identity: music, displayName: "Music", processObjectIDs: [10])
        ])
        scheduler.runUntilIdle()

        XCTAssertEqual(factory.makeAttempts, 1, "Terminal start failures must never restart")
        XCTAssertEqual(factory.failingControllers.first?.startAttempts, 1)
        XCTAssertEqual(factory.failingControllers.first?.stopAttempts, 3, "Cleanup retries must respect the cap")
        XCTAssertEqual(manager.lifecycleSnapshot(for: music)?.phase, .stopping)
        XCTAssertEqual(manager.lifecycleSnapshot(for: music)?.ownedControllerCount, 1)
    }

    func testHandoverStopFailureRollsBackThenRepairsOldConfiguration() throws {
        let scheduler = ManualTapRetryScheduler()
        let factory = FailsFirstControllerStopFactory(onFirstControllerRecovered: {})
        let manager = CoreAudioProcessTapManager(
            operations: FakeTapOperations(),
            automaticRetryCooldown: 0.01,
            retryScheduler: scheduler.schedule,
            controllerFactory: factory.make
        )
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        manager.setAvailableOutputUIDs(["built-in", "usb"], defaultOutputUID: "built-in")
        try manager.reconcile(targets: [
            CoreAudioTapTarget(identity: music, displayName: "Music", processObjectIDs: [10])
        ])

        XCTAssertThrowsError(try manager.setRoute(music, .selectedDevice("usb")))

        XCTAssertEqual(manager.resolvedOutputUIDs(for: music), ["built-in"])
        XCTAssertEqual(factory.createdOutputUIDSets, [["built-in"], ["usb"]])
        XCTAssertEqual(manager.lifecycleSnapshot(for: music)?.phase, .unhealthy)
        scheduler.runUntilIdle()

        XCTAssertEqual(factory.createdOutputUIDSets, [["built-in"], ["usb"], ["built-in"]])
        XCTAssertEqual(manager.lifecycleSnapshot(for: music)?.ownedControllerCount, 1)
        XCTAssertEqual(manager.health.issueCount, 0)
    }

    func testRuntimeRecoverableFailureRetriesWithoutAnotherHALEvent() throws {
        let factory = FailsOnRebuildControllerFactory()
        let scheduler = ManualTapRetryScheduler()
        let manager = CoreAudioProcessTapManager(
            operations: FakeTapOperations(),
            maxStartAttempts: 3,
            automaticRetryCooldown: 0.01,
            retryScheduler: scheduler.schedule,
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
        manager.setAvailableOutputUIDs(["built-in", "unused"], defaultOutputUID: "built-in")
        XCTAssertEqual(factory.attempts, 2, "An unrelated topology change must not bypass backoff")
        scheduler.runUntilIdle()
        XCTAssertEqual(factory.attempts, 4, "Runtime retries must not depend on another HAL event")
        XCTAssertEqual(manager.lifecycleSnapshot(for: music)?.phase, .unhealthy)
        XCTAssertThrowsError(try manager.setRoute(music, .multiOutput(["usb", "built-in"])))
        XCTAssertEqual(factory.attempts, 5, "Explicit route apply should reset the retry cap")
    }

    func testExplicitRouteChangeResetsInitialStartAttemptCap() throws {
        let scheduler = ManualTapRetryScheduler()
        let factory = FailsFirstNControllerFactory(failureCount: 3)
        let manager = CoreAudioProcessTapManager(
            operations: FakeTapOperations(),
            maxStartAttempts: 3,
            automaticRetryCooldown: 0.01,
            retryScheduler: scheduler.schedule,
            controllerFactory: factory.make
        )
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let target = CoreAudioTapTarget(identity: music, displayName: "Music", processObjectIDs: [10])
        manager.setAvailableOutputUIDs(["built-in", "usb"], defaultOutputUID: "built-in")

        try manager.reconcile(targets: [target])
        scheduler.runUntilIdle()
        XCTAssertEqual(factory.attempts, 3)
        XCTAssertEqual(manager.lifecycleSnapshot(for: music)?.phase, .failed)

        try manager.setRoute(music, .selectedDevice("usb"))

        XCTAssertEqual(factory.attempts, 4)
        XCTAssertEqual(manager.resolvedOutputUIDs(for: music), ["usb"])
        XCTAssertEqual(manager.health.activeAppCount, 1)
        XCTAssertEqual(manager.health.issueCount, 0)
    }

    func testInitialRecoverableFailureKeepsDesiredBookkeepingWithoutPlaceholder() throws {
        let operations = FakeTapOperations()
        let factory = FailingControllerFactory(error: CoreAudioTapStartFailure.deviceUnavailable)
        let scheduler = ManualTapRetryScheduler()
        let manager = CoreAudioProcessTapManager(
            operations: operations,
            automaticRetryCooldown: 10,
            retryScheduler: scheduler.schedule,
            controllerFactory: factory.make
        )
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        manager.setAvailableOutputUIDs(["built-in"], defaultOutputUID: "built-in")
        try manager.reconcile(targets: [
            CoreAudioTapTarget(identity: music, displayName: "Music", processObjectIDs: [10])
        ])

        XCTAssertTrue(manager.activeSessions.isEmpty)
        XCTAssertTrue(operations.created.isEmpty)
        XCTAssertTrue(operations.destroyed.isEmpty)
        XCTAssertEqual(factory.attempts, 1)
        XCTAssertEqual(manager.health.issueCount, 1)
        XCTAssertEqual(manager.lifecycleSnapshot(for: music)?.phase, .retrying)
        XCTAssertEqual(manager.lifecycleSnapshot(for: music)?.hasTarget, true)
        XCTAssertEqual(manager.lifecycleSnapshot(for: music)?.ownedControllerCount, 0)
    }

    func testRunningRetryingAndFailedTargetsAllRemainRepresentedUntilRemoved() throws {
        let running = AudioAppIdentity(rawValue: "running")
        let retrying = AudioAppIdentity(rawValue: "retrying")
        let failed = AudioAppIdentity(rawValue: "failed")
        let scheduler = ManualTapRetryScheduler()
        let manager = CoreAudioProcessTapManager(
            operations: FakeTapOperations(),
            automaticRetryCooldown: 10,
            retryScheduler: scheduler.schedule,
            controllerFactory: { target, outputs, _ in
                switch target.identity {
                case retrying: throw CoreAudioTapStartFailure.deviceUnavailable
                case failed: throw CoreAudioTapStartFailure.fatal("fatal fixture")
                default: return FakeController(target: target, outputDeviceUIDs: outputs) { _ in }
                }
            }
        )
        manager.setAvailableOutputUIDs(["built-in"], defaultOutputUID: "built-in")

        try manager.reconcile(targets: [
            CoreAudioTapTarget(identity: running, displayName: "Running", processObjectIDs: [1]),
            CoreAudioTapTarget(identity: retrying, displayName: "Retrying", processObjectIDs: [2]),
            CoreAudioTapTarget(identity: failed, displayName: "Failed", processObjectIDs: [3])
        ])

        XCTAssertEqual(manager.lifecycleSnapshot(for: running)?.phase, .running)
        XCTAssertEqual(manager.lifecycleSnapshot(for: retrying)?.phase, .retrying)
        XCTAssertEqual(manager.lifecycleSnapshot(for: failed)?.phase, .failed)
        XCTAssertEqual(manager.lifecycleSnapshot(for: running)?.hasTarget, true)
        XCTAssertEqual(manager.lifecycleSnapshot(for: retrying)?.hasTarget, true)
        XCTAssertEqual(manager.lifecycleSnapshot(for: failed)?.hasTarget, true)

        try manager.reconcile(targets: [])
        XCTAssertNil(manager.lifecycleSnapshot(for: running))
        XCTAssertNil(manager.lifecycleSnapshot(for: retrying))
        XCTAssertNil(manager.lifecycleSnapshot(for: failed))
    }

    func testInitialRecoverableFailureRetriesAutomaticallyAfterBackoff() throws {
        let scheduler = ManualTapRetryScheduler()
        let factory = FailsFirstNControllerFactory(failureCount: 1)
        let manager = CoreAudioProcessTapManager(
            operations: FakeTapOperations(),
            automaticRetryCooldown: 0.01,
            retryScheduler: scheduler.schedule,
            controllerFactory: factory.make
        )
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        manager.setAvailableOutputUIDs(["built-in"], defaultOutputUID: "built-in")
        try manager.reconcile(targets: [
            CoreAudioTapTarget(identity: music, displayName: "Music", processObjectIDs: [10])
        ])

        scheduler.runUntilIdle()

        XCTAssertEqual(factory.attempts, 2)
        XCTAssertEqual(manager.health.activeAppCount, 1)
        XCTAssertEqual(manager.health.issueCount, 0)
    }

    func testUnsupportedFailureIsTerminalAndDoesNotRetry() throws {
        let factory = FailingControllerFactory(error: CoreAudioTapStartFailure.unsupportedProcess)
        let scheduler = ManualTapRetryScheduler()
        let manager = CoreAudioProcessTapManager(
            operations: FakeTapOperations(),
            maxStartAttempts: 2,
            automaticRetryCooldown: 0.01,
            retryScheduler: scheduler.schedule,
            controllerFactory: factory.make
        )
        let identity = AudioAppIdentity(rawValue: "com.example.DAW")
        manager.setAvailableOutputUIDs(["built-in-output"], defaultOutputUID: "built-in-output")
        let target = CoreAudioTapTarget(identity: identity, displayName: "DAW", processObjectIDs: [10])

        try manager.reconcile(targets: [target])
        try manager.reconcile(targets: [target])
        try manager.reconcile(targets: [target])
        XCTAssertEqual(factory.attempts, 1)
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertEqual(manager.health.failedAppMessages[identity], "App cannot be tapped")
        XCTAssertEqual(manager.lifecycleSnapshot(for: identity)?.phase, .failed)
    }

    func testDisabledAndFatalFailuresAreExecutableTerminalDecisions() throws {
        let cases: [(CoreAudioTapStartFailure, CoreAudioTapFailureDecision)] = [
            (.permissionDenied, .disabled("Screen & System Audio Recording permission denied")),
            (.fatal("Unrecoverable HAL state"), .fatal("Unrecoverable HAL state"))
        ]

        for (index, value) in cases.enumerated() {
            let factory = FailingControllerFactory(error: value.0)
            let scheduler = ManualTapRetryScheduler()
            let manager = CoreAudioProcessTapManager(
                operations: FakeTapOperations(),
                automaticRetryCooldown: 0.01,
                retryScheduler: scheduler.schedule,
                controllerFactory: factory.make
            )
            let identity = AudioAppIdentity(rawValue: "terminal-\(index)")
            manager.setAvailableOutputUIDs(["built-in"], defaultOutputUID: "built-in")
            try manager.reconcile(targets: [
                CoreAudioTapTarget(identity: identity, displayName: "Terminal", processObjectIDs: [10])
            ])
            XCTAssertEqual(factory.attempts, 1)
            XCTAssertEqual(scheduler.pendingCount, 0)
            XCTAssertEqual(manager.lifecycleSnapshot(for: identity)?.phase, .failed)
            XCTAssertEqual(manager.lifecycleSnapshot(for: identity)?.failure, value.1)
        }
    }

    func testCachedRouteAndGainSurviveAbsenceThenAreReused() throws {
        let factory = FakeControllerFactory()
        let manager = CoreAudioProcessTapManager(
            operations: FakeTapOperations(),
            controllerFactory: factory.make
        )
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let target = CoreAudioTapTarget(identity: music, displayName: "Music", processObjectIDs: [10])
        manager.setAvailableOutputUIDs(["built-in", "usb"], defaultOutputUID: "built-in")
        try manager.setRoute(music, .selectedDevice("usb"))
        manager.setVolume(0.25, for: music)

        try manager.reconcile(targets: [target])
        try manager.reconcile(targets: [])

        XCTAssertEqual(manager.lifecycleSnapshot(for: music)?.phase, .absent)
        try manager.reconcile(targets: [target])

        XCTAssertEqual(factory.createdOutputUIDSets, [["usb"], ["usb"]])
        XCTAssertEqual(factory.createdGainStates.map(\.volume), [0.25, 0.25])
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

    func testTeardownFailureRetainsControllerAndRetriesSuccessfully() throws {
        let scheduler = ManualTapRetryScheduler()
        let factory = RetryingStopControllerFactory(failuresBeforeSuccess: 1) {}
        let manager = CoreAudioProcessTapManager(
            operations: FakeTapOperations(),
            automaticRetryCooldown: 0.01,
            retryScheduler: scheduler.schedule,
            controllerFactory: factory.make
        )
        let identity = AudioAppIdentity(rawValue: "com.example.Music")
        manager.setAvailableOutputUIDs(["built-in"], defaultOutputUID: "built-in")
        try manager.reconcile(targets: [
            CoreAudioTapTarget(identity: identity, displayName: "Music", processObjectIDs: [10])
        ])

        XCTAssertThrowsError(try manager.tearDown(identity: identity))
        XCTAssertEqual(manager.lifecycleSnapshot(for: identity)?.phase, .stopping)
        XCTAssertEqual(manager.lifecycleSnapshot(for: identity)?.hasSession, true)
        XCTAssertEqual(manager.lifecycleSnapshot(for: identity)?.ownedControllerCount, 1)

        scheduler.runUntilIdle()
        XCTAssertNil(manager.lifecycleSnapshot(for: identity))
        XCTAssertTrue(manager.activeSessions.isEmpty)
    }

    func testTeardownAllAttemptsEverySessionAndAggregatesFailures() throws {
        let factory = AlwaysFailingStopControllerFactory()
        let scheduler = ManualTapRetryScheduler()
        let manager = CoreAudioProcessTapManager(
            operations: FakeTapOperations(),
            automaticRetryCooldown: 10,
            retryScheduler: scheduler.schedule,
            controllerFactory: factory.make
        )
        manager.setAvailableOutputUIDs(["built-in"], defaultOutputUID: "built-in")
        try manager.reconcile(targets: [
            CoreAudioTapTarget(identity: AudioAppIdentity(rawValue: "a"), displayName: "A", processObjectIDs: [1]),
            CoreAudioTapTarget(identity: AudioAppIdentity(rawValue: "b"), displayName: "B", processObjectIDs: [2])
        ])

        XCTAssertThrowsError(try manager.tearDownAll()) { error in
            XCTAssertEqual((error as? CoreAudioTapTeardownAggregateError)?.failures.count, 2)
        }
        XCTAssertEqual(Set(factory.stopAttempts), ["a", "b"])
        XCTAssertEqual(manager.activeSessions.count, 2)
        XCTAssertEqual(manager.lifecycleSnapshot(for: AudioAppIdentity(rawValue: "a"))?.phase, .stopping)
        XCTAssertEqual(manager.lifecycleSnapshot(for: AudioAppIdentity(rawValue: "b"))?.phase, .stopping)
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

private enum TestJournalError: Error {
    case removeFailed
}

private final class FailsFirstRemoveJournal: CoreAudioAggregateOwnershipJournaling, @unchecked Sendable {
    let journalURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("EQMacRep-FakeJournal-\(UUID().uuidString).json")
    private(set) var removeAttempts = 0

    func records() throws -> [CoreAudioAggregateOwnershipRecord] { [] }
    func recordAggregate(uid: String, deviceID: AudioObjectID) throws {}

    func removeAggregate(uid: String) throws {
        removeAttempts += 1
        if removeAttempts == 1 { throw TestJournalError.removeFailed }
    }
}

private final class FakeActiveTapOperations: CoreAudioActiveTapOperating {
    var calls: [String] = []
    private let stopStatus: OSStatus
    private let ioProcDestroyStatus: OSStatus
    private let aggregateDestroyStatus: OSStatus
    private let tapDestroyStatus: OSStatus

    init(
        stopStatus: OSStatus = noErr,
        ioProcDestroyStatus: OSStatus = noErr,
        aggregateDestroyStatus: OSStatus = noErr,
        tapDestroyStatus: OSStatus = noErr
    ) {
        self.stopStatus = stopStatus
        self.ioProcDestroyStatus = ioProcDestroyStatus
        self.aggregateDestroyStatus = aggregateDestroyStatus
        self.tapDestroyStatus = tapDestroyStatus
    }

    func stopDevice(_ deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID?) -> OSStatus {
        calls.append("stop:\(deviceID)")
        return stopStatus
    }

    func destroyIOProc(_ deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID?) -> OSStatus {
        calls.append("destroyIO:\(deviceID)")
        return ioProcDestroyStatus
    }

    func destroyAggregateDevice(_ deviceID: AudioObjectID) -> OSStatus {
        calls.append("destroyAggregate:\(deviceID)")
        return aggregateDestroyStatus
    }

    func destroyProcessTap(_ tapID: AudioObjectID) -> OSStatus {
        calls.append("destroyTap:\(tapID)")
        return tapDestroyStatus
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
    private(set) var createdGainStates: [CoreAudioRealtimeGainState] = []
    private(set) var stoppedOutputUIDSets: [[String]] = []

    func make(
        _ target: CoreAudioTapTarget,
        _ outputUIDs: [String],
        _ gainState: CoreAudioRealtimeGainState
    ) throws -> CoreAudioActiveTapControlling {
        createdOutputUIDSets.append(outputUIDs)
        createdGainStates.append(gainState)
        return FakeController(target: target, outputDeviceUIDs: outputUIDs) { [weak self] uids in
            self?.stoppedOutputUIDSets.append(uids)
        }
    }
}

private enum TestTapLifecycleError: Error {
    case stopFailed
}

private final class RetryingStopController: CoreAudioActiveTapControlling {
    let outputDeviceUIDs: [String]
    private let identity: AudioAppIdentity
    private var failuresRemaining: Int
    private let onSuccessfulStop: () -> Void

    init(
        target: CoreAudioTapTarget,
        outputDeviceUIDs: [String],
        failuresBeforeSuccess: Int,
        onSuccessfulStop: @escaping () -> Void
    ) {
        identity = target.identity
        self.outputDeviceUIDs = outputDeviceUIDs
        failuresRemaining = failuresBeforeSuccess
        self.onSuccessfulStop = onSuccessfulStop
    }

    func start() throws -> CoreAudioTapSession {
        CoreAudioTapSession(identity: identity, tapObjectID: 7000, processObjectIDs: [1])
    }

    func updateGainState(_ state: CoreAudioRealtimeGainState) {}

    func stop() throws {
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw TestTapLifecycleError.stopFailed
        }
        onSuccessfulStop()
    }
}

private final class RetryingStopControllerFactory {
    private let failuresBeforeSuccess: Int
    private let onSuccessfulStop: () -> Void

    init(failuresBeforeSuccess: Int, onSuccessfulStop: @escaping () -> Void) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
        self.onSuccessfulStop = onSuccessfulStop
    }

    func make(
        _ target: CoreAudioTapTarget,
        _ outputUIDs: [String],
        _ gainState: CoreAudioRealtimeGainState
    ) throws -> CoreAudioActiveTapControlling {
        RetryingStopController(
            target: target,
            outputDeviceUIDs: outputUIDs,
            failuresBeforeSuccess: failuresBeforeSuccess,
            onSuccessfulStop: onSuccessfulStop
        )
    }
}

private final class AlwaysFailingStopControllerFactory {
    private(set) var stopAttempts: [String] = []

    func make(
        _ target: CoreAudioTapTarget,
        _ outputUIDs: [String],
        _ gainState: CoreAudioRealtimeGainState
    ) throws -> CoreAudioActiveTapControlling {
        AlwaysFailingStopController(target: target, outputDeviceUIDs: outputUIDs) { [weak self] identity in
            self?.stopAttempts.append(identity.rawValue)
        }
    }
}

private final class AlwaysFailingStopController: CoreAudioActiveTapControlling {
    let outputDeviceUIDs: [String]
    private let identity: AudioAppIdentity
    private let onStop: (AudioAppIdentity) -> Void

    init(
        target: CoreAudioTapTarget,
        outputDeviceUIDs: [String],
        onStop: @escaping (AudioAppIdentity) -> Void
    ) {
        identity = target.identity
        self.outputDeviceUIDs = outputDeviceUIDs
        self.onStop = onStop
    }

    func start() throws -> CoreAudioTapSession {
        CoreAudioTapSession(identity: identity, tapObjectID: 8000, processObjectIDs: [1])
    }

    func updateGainState(_ state: CoreAudioRealtimeGainState) {}

    func stop() throws {
        onStop(identity)
        throw TestTapLifecycleError.stopFailed
    }
}

private final class FailsFirstControllerStopFactory {
    private(set) var createdOutputUIDSets: [[String]] = []
    private let onFirstControllerRecovered: () -> Void

    init(onFirstControllerRecovered: @escaping () -> Void) {
        self.onFirstControllerRecovered = onFirstControllerRecovered
    }

    func make(
        _ target: CoreAudioTapTarget,
        _ outputUIDs: [String],
        _ gainState: CoreAudioRealtimeGainState
    ) throws -> CoreAudioActiveTapControlling {
        createdOutputUIDSets.append(outputUIDs)
        let isFirst = createdOutputUIDSets.count == 1
        return RetryingStopController(
            target: target,
            outputDeviceUIDs: outputUIDs,
            failuresBeforeSuccess: isFirst ? 1 : 0,
            onSuccessfulStop: isFirst ? onFirstControllerRecovered : {}
        )
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

private final class StartFailureControllerFactory {
    private let succeedsFirst: Bool
    private let startError: Error
    private let cleanupFailuresBeforeSuccess: Int
    private let onSuccessfulCleanup: () -> Void
    private(set) var makeAttempts = 0
    private(set) var failingControllers: [StartFailureController] = []

    init(
        succeedsFirst: Bool = false,
        startError: Error,
        cleanupFailuresBeforeSuccess: Int,
        onSuccessfulCleanup: @escaping () -> Void = {}
    ) {
        self.succeedsFirst = succeedsFirst
        self.startError = startError
        self.cleanupFailuresBeforeSuccess = cleanupFailuresBeforeSuccess
        self.onSuccessfulCleanup = onSuccessfulCleanup
    }

    func make(
        _ target: CoreAudioTapTarget,
        _ outputUIDs: [String],
        _ gainState: CoreAudioRealtimeGainState
    ) throws -> CoreAudioActiveTapControlling {
        makeAttempts += 1
        if succeedsFirst, makeAttempts == 1 {
            return FakeController(target: target, outputDeviceUIDs: outputUIDs) { _ in }
        }
        let controller = StartFailureController(
            target: target,
            outputDeviceUIDs: outputUIDs,
            startError: startError,
            cleanupFailuresBeforeSuccess: cleanupFailuresBeforeSuccess,
            onSuccessfulCleanup: onSuccessfulCleanup
        )
        failingControllers.append(controller)
        return controller
    }
}

private final class StartFailureController: CoreAudioActiveTapControlling {
    let outputDeviceUIDs: [String]
    private let identity: AudioAppIdentity
    private let startError: Error
    private var cleanupFailuresRemaining: Int
    private let onSuccessfulCleanup: () -> Void
    private(set) var startAttempts = 0
    private(set) var stopAttempts = 0

    init(
        target: CoreAudioTapTarget,
        outputDeviceUIDs: [String],
        startError: Error,
        cleanupFailuresBeforeSuccess: Int,
        onSuccessfulCleanup: @escaping () -> Void
    ) {
        identity = target.identity
        self.outputDeviceUIDs = outputDeviceUIDs
        self.startError = startError
        cleanupFailuresRemaining = cleanupFailuresBeforeSuccess
        self.onSuccessfulCleanup = onSuccessfulCleanup
    }

    func start() throws -> CoreAudioTapSession {
        startAttempts += 1
        throw startError
    }

    func updateGainState(_ state: CoreAudioRealtimeGainState) {}

    func stop() throws {
        stopAttempts += 1
        if cleanupFailuresRemaining > 0 {
            cleanupFailuresRemaining -= 1
            throw TestTapLifecycleError.stopFailed
        }
        onSuccessfulCleanup()
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
