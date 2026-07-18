import AuralisWidgetShared
import Foundation
import XCTest
@testable import Auralis

final class WidgetCommandQueueTests: XCTestCase {
    func testConcurrentEnqueueAndDrainLosesNoCommands() async throws {
        let layout = try makeLayout()
        let commands = (0..<120).map { index in
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
                while true {
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
            execute: { _ in executionCount += 1 },
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
            execute: { command in
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
            execute: { command in
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
            execute: { _ in executionCount += 1 },
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
        let store = try makeStore(backend: backend)
        try await store.refresh()
        let command = WidgetCommand.outputDevice(identity: device.id, muted: true)
        try WidgetCommandQueue.enqueue(command, layout: layout)
        let processor = WidgetCommandProcessor(
            layout: layout,
            execute: { try await WidgetCommandStoreExecutor.apply($0, to: store) },
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
    func testAppliedSnapshotAndAckExistBeforeTimelineReloadCallback() async throws {
        let layout = try makeLayout()
        let command = WidgetCommand.app(identity: "music", action: .setVolume(0.25))
        try WidgetCommandQueue.enqueue(command, layout: layout)
        var appliedVolume = 1.0
        var callbackObservedAppliedSnapshot = false
        var callbackObservedAck = false
        let processor = WidgetCommandProcessor(
            layout: layout,
            execute: { command in
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
        let store = try makeStore(backend: MockAudioBackend())
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
        let store = try makeStore(backend: backend)
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

    private func makeLayout() throws -> WidgetSharedLayout {
        let root = try temporaryDirectory(prefix: "AuralisWidgetIPC")
        let layout = WidgetSharedContainer.testLayout(at: root)
        try WidgetSharedContainer.prepare(layout)
        return layout
    }

    @MainActor
    private func makeStore(backend: MockAudioBackend) throws -> AudioControlStore {
        let settingsURL = temporaryFileURL(prefix: "AuralisWidgetSettings", filename: "settings.json")
        return try AudioControlStore(
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
