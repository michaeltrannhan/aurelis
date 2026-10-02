import AuralisWidgetShared
import Foundation
import XCTest
@testable import Auralis

final class WidgetCommandQueueTests: XCTestCase {
    func testConcurrentEnqueueAndDrainLosesNoCommands() async throws {
        let layout = try makeLayout()
        let commands = (0..<48).map { index in
            WidgetCommand.app(
                identity: "app-\(index)",
                action: .setVolume(Double(index % 100) / 100)
            )
        }
        let expectedIDs = Set(commands.map(\.id))
        let state = WidgetQueueStressState(producerCount: commands.count)

        await withTaskGroup(of: Void.self) { group in
            for command in commands {
                group.addTask {
                    do {
                        guard try WidgetCommandQueue.enqueue(command, layout: layout) else {
                            await state.record(error: "Unexpected duplicate \(command.id)")
                            await state.finishedProducing()
                            return
                        }
                    } catch {
                        await state.record(error: error.localizedDescription)
                    }
                    await state.finishedProducing()
                }
            }
            group.addTask {
                let deadline = Date().addingTimeInterval(10)
                while Date() < deadline {
                    do {
                        for claim in try WidgetCommandQueue.claimAvailable(layout: layout) {
                            let command = try WidgetCommandQueue.readCommand(claim)
                            let result = WidgetCommandResult(
                                commandID: command.id,
                                status: .applied,
                                message: "Applied",
                                snapshotGeneratedAt: Date()
                            )
                            try WidgetCommandQueue.publish(result, for: claim, layout: layout)
                            try WidgetCommandQueue.complete(claim)
                            await state.record(processed: command.id)
                        }
                    } catch {
                        await state.record(error: error.localizedDescription)
                    }

                    if await state.allProducersFinished(),
                       WidgetCommandQueue.pendingCommandIDs(layout: layout).isEmpty {
                        return
                    }
                    await Task.yield()
                }
                await state.record(error: "Drain deadline exceeded; pending commands: \(WidgetCommandQueue.pendingCommandIDs(layout: layout))")
            }
        }

        let outcome = await state.outcome()
        XCTAssertEqual(outcome.errors, [])
        XCTAssertEqual(outcome.processed, expectedIDs)
        XCTAssertTrue(WidgetCommandQueue.pendingCommandIDs(layout: layout).isEmpty)
        XCTAssertTrue(expectedIDs.allSatisfy { WidgetCommandQueue.result(for: $0, layout: layout)?.status == .applied })
    }

    @MainActor
    func testDirectoryWatcherSurvivesAtomicCreationAndDeletion() async throws {
        let layout = try makeLayout()
        let watcher = WidgetCommandDirectoryWatcher()
        let firstCreation = expectation(description: "first atomic creation observed")
        let secondCreation = expectation(description: "creation after deletion observed")
        let second = WidgetCommand.refresh()
        var phase = 0
        let fileActor = WidgetIPCFileActor(layoutResolver: { layout })
        let descriptor = try await fileActor.openPendingDirectory()

        try watcher.start(fileDescriptor: descriptor) {
            if phase == 0 {
                phase = 1
                firstCreation.fulfill()
            } else if phase == 2,
                      FileManager.default.fileExists(atPath: layout.pendingCommandURL(for: second.id).path) {
                phase = 3
                secondCreation.fulfill()
            }
        }
        defer { watcher.stop() }

        let first = WidgetCommand.refresh()
        XCTAssertTrue(try WidgetCommandQueue.enqueue(first, layout: layout))
        await fulfillment(of: [firstCreation], timeout: 2)

        let claims = try WidgetCommandQueue.claimAvailable(layout: layout)
        XCTAssertEqual(claims.map(\.commandID), [first.id])
        try WidgetCommandQueue.complete(XCTUnwrap(claims.first))
        phase = 2
        XCTAssertTrue(try WidgetCommandQueue.enqueue(second, layout: layout))
        await fulfillment(of: [secondCreation], timeout: 2)
        XCTAssertEqual(phase, 3)
    }

    @MainActor
    func testDuplicateDeliveryIsAcknowledgedWithoutReexecution() async throws {
        let layout = try makeLayout()
        let command = WidgetCommand.app(identity: "music", action: .setMuted(true))
        XCTAssertTrue(try WidgetCommandQueue.enqueue(command, layout: layout))
        XCTAssertFalse(try WidgetCommandQueue.enqueue(command, layout: layout))
        var executionCount = 0
        let processor = WidgetCommandProcessor(
            layout: layout,
            execute: { _, _ in executionCount += 1 },
            publishSnapshot: { Date() }
        )

        let initialReport = await processor.drain()
        XCTAssertEqual(initialReport.results.first?.status, .applied)
        XCTAssertEqual(executionCount, 1)

        let duplicateData = try WidgetWireCodec.makeEncoder().encode(command)
        try duplicateData.write(to: layout.pendingCommandURL(for: command.id), options: .atomic)
        let duplicateReport = await processor.drain()
        XCTAssertTrue(duplicateReport.results.isEmpty)
        XCTAssertEqual(executionCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.pendingCommandURL(for: command.id).path))
    }

    @MainActor
    func testCrashAfterExecutionBeforeAcknowledgmentRecoversIdempotently() async throws {
        let layout = try makeLayout()
        let command = WidgetCommand.app(identity: "music", action: .setVolume(0.4))
        try WidgetCommandQueue.enqueue(command, layout: layout)
        var appliedVolume = 1.0
        var executionCount = 0

        let crashingProcessor = WidgetCommandProcessor(
            layout: layout,
            execute: { command, claim in
                guard case let .setVolume(value) = command.action else { return }
                appliedVolume = value
                executionCount += 1
            },
            publishSnapshot: {
                throw WidgetIPCError.cannotWrite(layout.snapshotURL, CocoaError(.fileWriteUnknown))
            }
        )
        let interrupted = await crashingProcessor.drain()
        XCTAssertEqual(appliedVolume, 0.4)
        XCTAssertEqual(executionCount, 1)
        XCTAssertFalse(interrupted.transportErrors.isEmpty)
        XCTAssertEqual(WidgetCommandQueue.pendingCommandIDs(layout: layout), [command.id])
        XCTAssertNil(WidgetCommandQueue.result(for: command.id, layout: layout))

        let recoveredProcessor = WidgetCommandProcessor(
            layout: layout,
            execute: { command, claim in
                guard case let .setVolume(value) = command.action else { return }
                appliedVolume = value
                executionCount += 1
            },
            publishSnapshot: { Date() }
        )
        let recovered = await recoveredProcessor.drain()

        XCTAssertEqual(recovered.results.first?.status, .applied)
        XCTAssertEqual(appliedVolume, 0.4)
        XCTAssertEqual(executionCount, 2, "Recovery replays the same absolute value without compounding it")
        XCTAssertTrue(WidgetCommandQueue.pendingCommandIDs(layout: layout).isEmpty)
        XCTAssertEqual(WidgetCommandQueue.result(for: command.id, layout: layout)?.status, .applied)
    }

    @MainActor
    func testRelativeGesturesRecoverWithoutRepeatingTheGesture() async throws {
        for action in [WidgetCommandAction.adjustVolume(0.05), .toggleMuted,
                       .adjustEQBandGain(band: 4, delta: 0.5), .cycleBoost] {
            let layout = try makeLayout()
            let command = WidgetCommand.app(identity: "music", action: action)
            try WidgetCommandQueue.enqueue(command, layout: layout)
            var volume = 0.5
            var muted = false
            var gain = 0.0
            var boost = 1.0
            let apply: @MainActor @Sendable (WidgetCommand) async throws -> Void = { command in
                switch command.action {
                case let .setVolume(value): volume = value
                case let .setMuted(value): muted = value
                case let .setEQBandGain(_, value): gain = value
                case let .setBoost(value): boost = value
                default: XCTFail("The gesture must resolve before execution")
                }
            }
            let resolve: @MainActor @Sendable (WidgetCommand) throws -> WidgetCommandAction = { command in
                switch command.action {
                case let .adjustVolume(delta): return .setVolume(volume + delta)
                case .toggleMuted: return .setMuted(!muted)
                case let .adjustEQBandGain(band, delta): return .setEQBandGain(band: band, gain: gain + delta)
                case .cycleBoost: return .setBoost(boost == 4 ? 1 : boost + 1)
                default: throw WidgetCommandExecutionError.unsupportedAction
                }
            }
            let interrupted = WidgetCommandProcessor(
                layout: layout, execute: { command, claim in
                    let action = try resolve(command)
                    let resolved = try WidgetCommandQueue.resolve(command, to: action, for: claim)
                    try await apply(resolved)
                },
                publishSnapshot: { throw CocoaError(.fileWriteUnknown) }
            )
            let report = await interrupted.drain()
            XCTAssertFalse(report.transportErrors.isEmpty)
            let expectedVolume = volume
            let expectedMuted = muted
            let expectedGain = gain
            let expectedBoost = boost
            let claim = try XCTUnwrap(WidgetCommandQueue.claimAvailable(layout: layout).first)
            XCTAssertFalse(try WidgetCommandQueue.readCommand(claim).action.isRelative)

            let recovered = WidgetCommandProcessor(
                layout: layout, execute: { command, _ in
                    XCTAssertFalse(command.action.isRelative, "A recovered claim must already be absolute")
                    try await apply(command)
                }, publishSnapshot: { Date() }
            )
            let recoveredReport = await recovered.drain()
            XCTAssertEqual(recoveredReport.results.first?.status, .applied)
            XCTAssertEqual(volume, expectedVolume, accuracy: 0.0001)
            XCTAssertEqual(muted, expectedMuted)
            XCTAssertEqual(gain, expectedGain)
            XCTAssertEqual(boost, expectedBoost)
        }
    }

    @MainActor
    func testPublicationFailurePreservesOrderingOfLaterGestures() async throws {
        for failResult in [false, true] {
            let layout = try makeLayout()
            let first = WidgetCommand.app(identity: "music", action: .adjustVolume(0.05))
            let second = WidgetCommand.app(identity: "music", action: .adjustVolume(0.05))
            try WidgetCommandQueue.enqueue(first, layout: layout)
            try WidgetCommandQueue.enqueue(second, layout: layout)
            var volume = 0.5
            var executionIDs: [UUID] = []
            var shouldFail = true
            let processor = WidgetCommandProcessor(
                layout: layout,
                execute: { incoming, claim in
                    let command: WidgetCommand
                    if case let .adjustVolume(delta) = incoming.action {
                        command = try WidgetCommandQueue.resolve(incoming, to: .setVolume(volume + delta), for: claim)
                    } else {
                        command = incoming
                    }
                    guard case let .setVolume(value) = command.action else {
                        XCTFail("Expected an absolute volume")
                        return
                    }
                    volume = value
                    executionIDs.append(command.id)
                },
                publishSnapshot: {
                    if shouldFail {
                        shouldFail = false
                        if failResult {
                            try FileManager.default.removeItem(at: layout.resultsURL)
                            try Data("blocks result publication".utf8).write(to: layout.resultsURL)
                        } else {
                            throw CocoaError(.fileWriteUnknown)
                        }
                    }
                    return Date()
                }
            )
            let interrupted = await processor.drain()
            XCTAssertFalse(interrupted.transportErrors.isEmpty)
            XCTAssertEqual(executionIDs, [first.id], "Unacknowledged work must block later gestures")
            XCTAssertEqual(volume, 0.55, accuracy: 0.0001)
            if failResult {
                try FileManager.default.removeItem(at: layout.resultsURL)
                try WidgetSharedContainer.prepare(layout)
            }
            XCTAssertNil(WidgetCommandQueue.result(for: second.id, layout: layout))
            let recovered = await processor.drain()
            XCTAssertEqual(recovered.results.map(\.commandID), [first.id, second.id])
            XCTAssertEqual(executionIDs, [first.id, first.id, second.id])
            XCTAssertEqual(volume, 0.6, accuracy: 0.0001)
        }
    }

    @MainActor
    func testWidgetResolutionSharesOrderingWithPendingSliderAndKeyboard() async throws {
        let layout = try makeLayout()
        let identity = AudioAppIdentity(rawValue: "music")
        let store = AudioControlStore(
            settingsStore: SettingsStore(settingsURL: layout.rootURL.appendingPathComponent("settings.json")),
            backend: MockAudioBackend(apps: [AudioAppSnapshot(identity: identity, displayName: "Music")])
        )
        try await store.refresh()
        try await store.setVolume(0.5, for: identity)
        var release: CheckedContinuation<Void, Never>?
        let blocker = Task {
            try await store.commandCoordinator.performOrdered {
                await withCheckedContinuation { release = $0 }
            }
        }
        for _ in 0..<1_000 where release == nil { await Task.yield() }
        XCTAssertNotNil(release)
        let slider = store.submit(ControlCommand(target: .app(identity), mutation: .setVolume(0.2)))
        let key = store.submit(ControlCommand(target: .app(identity), mutation: .adjustVolume(0.1), source: .hotkey))
        let widget = WidgetCommand.app(identity: identity.rawValue, action: .adjustVolume(0.05))
        try WidgetCommandQueue.enqueue(widget, layout: layout)
        var widgetAccepted = false
        let processor = WidgetCommandProcessor(
            layout: layout,
            execute: { command, claim in
                widgetAccepted = true
                try await WidgetCommandStoreExecutor.apply(command, claim: claim, to: store)
            },
            publishSnapshot: { Date() }
        )
        let drain = Task { await processor.drain() }
        for _ in 0..<1_000 where !widgetAccepted { await Task.yield() }
        XCTAssertTrue(widgetAccepted)
        // This key is accepted after the opaque widget operation, but must
        // resolve against its committed value when its worker turn arrives.
        let laterKey = store.submit(ControlCommand(
            target: .app(identity), mutation: .adjustVolume(0.1), source: .hotkey
        ))
        release?.resume()
        try await blocker.value
        _ = await store.result(for: slider.id)
        _ = await store.result(for: key.id)
        let report = await drain.value
        _ = await store.result(for: laterKey.id)
        XCTAssertEqual(report.results.first?.status, .applied)
        XCTAssertEqual(try XCTUnwrap(store.settings.appSettings[identity]?.volume), 0.45, accuracy: 0.0001)
        _ = await store.shutdown()
    }

    @MainActor
    func testRapidWidgetGesturesAccumulateAgainstLiveStore() async throws {
        let layout = try makeLayout()
        let identity = AudioAppIdentity(rawValue: "music")
        let device = AudioDeviceSnapshot(id: "main", name: "Main", isDefault: true)
        let store = makeStore(backend: MockAudioBackend(
            apps: [AudioAppSnapshot(identity: identity, displayName: "Music", isActive: true)],
            devices: [device]
        ))
        await store.waitUntilReady()
        try await store.refresh()
        try await store.setVolume(0.5, for: identity)
        try await store.setMuted(false, for: identity)
        try await store.setDeviceVolume(0.5, for: device.id)
        try await store.setDeviceMuted(false, for: device.id)
        for _ in 0..<2 {
            let commands = try [
                XCTUnwrap(WidgetIntentCommandFactory.adjustAppVolume(appID: identity.rawValue, delta: 0.05)),
                XCTUnwrap(WidgetIntentCommandFactory.toggleAppMuted(appID: identity.rawValue)),
                XCTUnwrap(WidgetIntentCommandFactory.adjustOutputDeviceVolume(deviceID: device.id, delta: 0.05)),
                XCTUnwrap(WidgetIntentCommandFactory.toggleOutputDeviceMuted(deviceID: device.id)),
                XCTUnwrap(WidgetIntentCommandFactory.adjustEQBandGain(appID: identity.rawValue, band: 4, delta: 0.5)),
                XCTUnwrap(WidgetIntentCommandFactory.cycleAppBoost(appID: identity.rawValue))
            ]
            for command in commands { try WidgetCommandQueue.enqueue(command, layout: layout) }
        }
        let processor = WidgetCommandProcessor(
            layout: layout,
            execute: { try await WidgetCommandStoreExecutor.apply($0, claim: $1, to: store) },
            publishSnapshot: { Date() }
        )
        let report = await processor.drain()
        XCTAssertEqual(report.results.count, 12)
        XCTAssertTrue(report.results.allSatisfy { $0.status == .applied })
        XCTAssertEqual(try XCTUnwrap(store.settings.appSettings[identity]?.volume), 0.6, accuracy: 0.0001)
        XCTAssertEqual(store.settings.appSettings[identity]?.isMuted, false)
        XCTAssertEqual(store.settings.appSettings[identity]?.eq.gains[4], 1)
        XCTAssertEqual(store.settings.appSettings[identity]?.boost, .x3)
        XCTAssertEqual(try XCTUnwrap(store.deviceVolumeStates[device.id]?.volume), 0.6, accuracy: 0.0001)
        XCTAssertEqual(store.deviceVolumeStates[device.id]?.isMuted, false)
        _ = await store.shutdown()
    }

    @MainActor
    func testBridgeRetriesAfterInitialSnapshotWriteFails() async throws {
        let layout = try makeLayout()
        try FileManager.default.createDirectory(at: layout.snapshotURL, withIntermediateDirectories: false)
        let store = makeStore(backend: MockAudioBackend())
        let bridge = WidgetBridge(store: store, layoutResolver: { layout }, reloadTimelines: {})
        let failed = await bridge.start()
        XCTAssertFalse(failed)
        XCTAssertFalse(bridge.hasActiveTransportResources)
        try FileManager.default.removeItem(at: layout.snapshotURL)
        let recovered = await bridge.start()
        XCTAssertTrue(recovered)
        XCTAssertTrue(bridge.hasActiveTransportResources)
        await bridge.stop()
        XCTAssertFalse(bridge.hasActiveTransportResources)
        _ = await store.shutdown()
    }

    @MainActor
    func testStaleAndMalformedCommandsAreRejectedWithoutExecution() async throws {
        let layout = try makeLayout()
        try WidgetSharedContainer.prepare(layout)
        let stale = WidgetCommand.app(
            identity: "music",
            action: .setMuted(true),
            createdAt: Date().addingTimeInterval(-90),
            lifetime: 10
        )
        let malformedID = UUID()
        let staleData = try WidgetWireCodec.makeEncoder().encode(stale)
        try staleData.write(to: layout.pendingCommandURL(for: stale.id), options: .atomic)
        try Data("not-json".utf8).write(to: layout.pendingCommandURL(for: malformedID), options: .atomic)
        var executionCount = 0
        let processor = WidgetCommandProcessor(
            layout: layout,
            execute: { _, _ in executionCount += 1 },
            publishSnapshot: { Date() }
        )

        let report = await processor.drain()

        XCTAssertEqual(executionCount, 0)
        XCTAssertEqual(report.results.count, 2)
        XCTAssertTrue(report.results.allSatisfy { $0.status == .rejected })
        XCTAssertEqual(WidgetCommandQueue.result(for: stale.id, layout: layout)?.status, .rejected)
        XCTAssertEqual(WidgetCommandQueue.result(for: malformedID, layout: layout)?.status, .rejected)
        XCTAssertTrue(WidgetCommandQueue.pendingCommandIDs(layout: layout).isEmpty)
    }

    @MainActor
    func testOutputDeviceMuteCommandUsesRealStoreBackendPath() async throws {
        let layout = try makeLayout()
        let device = AudioDeviceSnapshot(id: "usb-speakers", name: "USB Speakers", isDefault: true)
        let backend = MockAudioBackend(devices: [device])
        let store = makeStore(backend: backend)
        try await store.refresh()
        let command = WidgetCommand.outputDevice(identity: device.id, muted: true)
        try WidgetCommandQueue.enqueue(command, layout: layout)
        let processor = WidgetCommandProcessor(
            layout: layout,
            execute: { try await WidgetCommandStoreExecutor.apply($0, claim: $1, to: store) },
            publishSnapshot: {
                let snapshot = WidgetBridge.makeSnapshot(from: store)
                try WidgetSnapshotWriter.write(snapshot, layout: layout)
                return snapshot.generatedAt
            }
        )

        let report = await processor.drain()

        XCTAssertEqual(report.results.first?.status, .applied)
        XCTAssertEqual(backend.perDeviceMuted[device.id], true)
        XCTAssertEqual(store.deviceVolumeStates[device.id]?.isMuted, true)
    }

    @MainActor
    func testAssignPresetCommandUsesCurrentOutputAndAppliesItsEQ() async throws {
        let layout = try makeLayout()
        let music = AudioAppIdentity(rawValue: "music")
        let display = AudioDeviceSnapshot(
            id: "lg-ultrafine",
            name: "LG UltraFine",
            isDefault: true
        )
        let backend = MockAudioBackend(
            apps: [AudioAppSnapshot(identity: music, displayName: "Music", isActive: true)],
            devices: [display]
        )
        let store = makeStore(backend: backend)
        try await store.refresh()
        try await store.setEQGain(4, band: 1, for: music)
        let blackstarID = try await store.createProfile(named: "Blackstar", scope: .global)
        try await store.setEQGain(0, band: 1, for: music)
        let command = WidgetCommand.assignProfileToCurrentOutput(
            identity: blackstarID.uuidString
        )
        try WidgetCommandQueue.enqueue(command, layout: layout)
        let processor = WidgetCommandProcessor(
            layout: layout,
            execute: { try await WidgetCommandStoreExecutor.apply($0, claim: $1, to: store) },
            publishSnapshot: {
                let snapshot = WidgetBridge.makeSnapshot(from: store)
                try WidgetSnapshotWriter.write(snapshot, layout: layout)
                return snapshot.generatedAt
            }
        )

        let report = await processor.drain()

        XCTAssertEqual(report.results.first?.status, .applied)
        XCTAssertEqual(store.outputConfiguration(for: display.id)?.name, "Blackstar")
        XCTAssertEqual(store.settings.appSettings[music]?.eq.gains[1], 4)
    }

    @MainActor
    func testAppliedSnapshotAndAckExistBeforeTimelineReloadCallback() async throws {
        let layout = try makeLayout()
        let command = WidgetCommand.app(identity: "music", action: .setVolume(0.25))
        try WidgetCommandQueue.enqueue(command, layout: layout)
        var appliedVolume = 1.0
        var callbackObservedAppliedSnapshot = false
        var callbackObservedAck = false
        let processor = WidgetCommandProcessor(
            layout: layout,
            execute: { command, claim in
                guard case let .setVolume(value) = command.action else { return }
                appliedVolume = value
            },
            publishSnapshot: {
                let now = Date()
                let snapshot = WidgetSnapshot(
                    generatedAt: now,
                    hostState: .running,
                    hostUpdatedAt: now,
                    statusMessage: "Applied volume \(appliedVolume)",
                    activeAppCount: 0,
                    volumeStep: 0.05,
                    devices: [],
                    apps: []
                )
                try WidgetSnapshotWriter.write(snapshot, layout: layout)
                return now
            },
            resultPublished: { result in
                callbackObservedAppliedSnapshot = WidgetSnapshotReader.read(layout: layout).statusMessage == "Applied volume 0.25"
                let acknowledgment = WidgetCommandQueue.result(for: result.commandID, layout: layout)
                callbackObservedAck = acknowledgment?.commandID == result.commandID
                    && acknowledgment?.status == .applied
                    && acknowledgment?.snapshotGeneratedAt != nil
            }
        )

        let report = await processor.drain()

        XCTAssertEqual(report.results.first?.status, .applied)
        XCTAssertTrue(callbackObservedAppliedSnapshot)
        XCTAssertTrue(callbackObservedAck)
    }

    @MainActor
    func testMissingAppGroupIsPublishedAsConfigurationIssue() async throws {
        let store = makeStore(backend: MockAudioBackend())
        let bridge = WidgetBridge(
            store: store,
            layoutResolver: { throw WidgetIPCError.appGroupUnavailable("missing.group") },
            reloadTimelines: {}
        )

        let started = await bridge.start()
        XCTAssertFalse(started)

        XCTAssertEqual(store.issues.last?.id, "widget-ipc-configuration")
        XCTAssertEqual(store.issues.last?.severity, .error)
        XCTAssertTrue(store.issues.last?.message.contains("App Group missing.group is unavailable") == true)
    }

    @MainActor
    func testBridgePublishesClosedHostAndDrainsQueuedWorkAfterRestart() async throws {
        let layout = try makeLayout()
        let music = AudioAppIdentity(rawValue: "music")
        let backend = MockAudioBackend(apps: [
            AudioAppSnapshot(identity: music, displayName: "Music")
        ])
        let store = makeStore(backend: backend)
        try await store.refresh()
        let command = WidgetCommand.app(identity: music.rawValue, action: .setVolume(0.25))
        let applied = expectation(description: "bridge published command acknowledgment")
        var didObserveResult = false
        let bridge = WidgetBridge(
            store: store,
            layoutResolver: { layout },
            reloadTimelines: {
                guard !didObserveResult,
                      WidgetCommandQueue.result(for: command.id, layout: layout) != nil else { return }
                didObserveResult = true
                applied.fulfill()
            }
        )

        let firstStart = await bridge.start()
        let repeatedStart = await bridge.start()
        XCTAssertTrue(firstStart)
        XCTAssertTrue(repeatedStart, "Repeated startup must not duplicate the watcher")
        let running = WidgetSnapshotReader.read(layout: layout)
        XCTAssertEqual(running.hostState, .running)
        XCTAssertTrue(running.isHostAvailable(at: running.hostUpdatedAt))
        XCTAssertEqual(running.apps.map(\.id), [music.rawValue])

        await bridge.stop()
        let stopped = WidgetSnapshotReader.read(layout: layout)
        XCTAssertEqual(stopped.hostState, .stopped)
        XCTAssertFalse(stopped.isHostAvailable(at: stopped.hostUpdatedAt))
        XCTAssertTrue(stopped.statusMessage.contains("closed"))
        XCTAssertEqual(bridge.activeTransportResourceNames, [])

        XCTAssertTrue(try WidgetCommandQueue.enqueue(command, layout: layout))
        XCTAssertNil(WidgetCommandQueue.result(for: command.id, layout: layout))
        XCTAssertEqual(WidgetCommandQueue.pendingCommandIDs(layout: layout), [command.id])

        let restart = await bridge.start()
        XCTAssertTrue(restart)
        await fulfillment(of: [applied], timeout: 2)

        XCTAssertEqual(backend.commands.last, .setVolume(music, 0.25))
        XCTAssertEqual(store.settings.appSettings[music]?.volume, 0.25)
        let result = try XCTUnwrap(WidgetCommandQueue.result(for: command.id, layout: layout))
        XCTAssertEqual(result.status, .applied)
        XCTAssertNotNil(result.snapshotGeneratedAt)
        XCTAssertTrue(WidgetCommandQueue.pendingCommandIDs(layout: layout).isEmpty)

        await bridge.stop()
    }

    @MainActor
    func testStartedBridgeDoesNotRetainItself() async throws {
        let layout = try makeLayout()
        let store = makeStore(backend: MockAudioBackend())
        weak var releasedBridge: WidgetBridge?
        var bridge: WidgetBridge? = WidgetBridge(
            store: store,
            layoutResolver: { layout },
            reloadTimelines: {}
        )
        releasedBridge = bridge

        let started = await bridge?.start()
        XCTAssertEqual(started, true)
        bridge = nil
        for _ in 0..<100 where releasedBridge != nil {
            await Task.yield()
        }

        XCTAssertNil(releasedBridge, "The heartbeat task must not retain its WidgetBridge owner")
        _ = await store.shutdown()
    }

    private func makeLayout() throws -> WidgetSharedLayout {
        let root = try temporaryDirectory(prefix: "AuralisWidgetIPC")
        let layout = WidgetSharedContainer.testLayout(at: root)
        try WidgetSharedContainer.prepare(layout)
        return layout
    }

    @MainActor
    private func makeStore(backend: MockAudioBackend) -> AudioControlStore {
        let settingsURL = temporaryFileURL(prefix: "AuralisWidgetSettings", filename: "settings.json")
        return AudioControlStore(
            settingsStore: SettingsStore(settingsURL: settingsURL),
            backend: backend
        )
    }
}

private actor WidgetQueueStressState {
    private let producerCount: Int
    private var finishedProducerCount = 0
    private var processedIDs: Set<UUID> = []
    private var recordedErrors: [String] = []

    init(producerCount: Int) {
        self.producerCount = producerCount
    }

    func finishedProducing() {
        finishedProducerCount += 1
    }

    func record(processed id: UUID) {
        processedIDs.insert(id)
    }

    func record(error: String) {
        recordedErrors.append(error)
    }

    func allProducersFinished() -> Bool {
        finishedProducerCount == producerCount
    }

    func outcome() -> (processed: Set<UUID>, errors: [String]) {
        (processedIDs, recordedErrors)
    }
}
