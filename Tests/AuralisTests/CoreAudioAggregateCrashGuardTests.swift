import CoreAudio
import XCTest
@testable import Auralis

final class CoreAudioAggregateCrashGuardTests: XCTestCase {
    func testFatalSignalHandlerPerformsNoCoreAudioOrFilesystemCleanup() {
        XCTAssertFalse(CoreAudioAggregateCrashGuard.fatalSignalHandlerPerformsExternalCleanup)
    }

    func testProductionOwnershipJournalRoundTripsAndDeduplicatesByStableUID() throws {
        let journal = CoreAudioAggregateOwnershipJournal(journalURL: uniqueJournalURL())
        let uid = aggregateUID()

        try journal.recordAggregate(uid: uid, deviceID: 10)
        try journal.recordAggregate(uid: uid, deviceID: 11)

        let record = try XCTUnwrap(journal.records().first)
        XCTAssertEqual(try journal.records().count, 1)
        XCTAssertEqual(record.aggregateUID, uid)
        XCTAssertEqual(record.lastKnownDeviceID, 11)

        try journal.removeAggregate(uid: uid)
        XCTAssertTrue(try journal.records().isEmpty)
    }

    func testConcurrentJournalMutationsKeepCompleteSameInstanceTransactions() throws {
        let journal = CoreAudioAggregateOwnershipJournal(journalURL: uniqueJournalURL())
        let uids = (0..<32).map { _ in aggregateUID() }
        let failures = ConcurrentJournalFailures()

        DispatchQueue.concurrentPerform(iterations: uids.count) { index in
            do {
                try journal.recordAggregate(uid: uids[index], deviceID: AudioObjectID(index + 1))
            } catch {
                failures.record(error)
            }
        }
        XCTAssertTrue(failures.messages.isEmpty, failures.messages.joined(separator: "; "))
        let initialRecords = try journal.records()
        XCTAssertEqual(Set(initialRecords.map(\.aggregateUID)), Set(uids))
        XCTAssertEqual(initialRecords.count, uids.count)

        DispatchQueue.concurrentPerform(iterations: uids.count) { index in
            do {
                if index.isMultiple(of: 2) {
                    try journal.removeAggregate(uid: uids[index])
                } else {
                    try journal.recordAggregate(uid: uids[index], deviceID: AudioObjectID(index + 100))
                }
            } catch {
                failures.record(error)
            }
        }
        XCTAssertTrue(failures.messages.isEmpty, failures.messages.joined(separator: "; "))
        let records = try journal.records()
        let expectedIndices = uids.indices.filter { !$0.isMultiple(of: 2) }
        XCTAssertEqual(Set(records.map(\.aggregateUID)), Set(expectedIndices.map { uids[$0] }))
        XCTAssertEqual(records.count, expectedIndices.count)
        for index in expectedIndices {
            XCTAssertEqual(
                records.first(where: { $0.aggregateUID == uids[index] })?.lastKnownDeviceID,
                AudioObjectID(index + 100)
            )
        }
    }

    func testProductionJournalPersistsPrecreationIntentUsingStableUIDAlone() throws {
        let journal = CoreAudioAggregateOwnershipJournal(journalURL: uniqueJournalURL())
        let uid = aggregateUID()

        try journal.recordAggregate(
            uid: uid,
            deviceID: AudioObjectID(kAudioObjectUnknown)
        )

        let record = try XCTUnwrap(journal.records().first)
        XCTAssertTrue(record.isValid)
        XCTAssertEqual(record.aggregateUID, uid)
        XCTAssertEqual(record.lastKnownDeviceID, AudioObjectID(kAudioObjectUnknown))
    }

    func testProductionJournalRejectsInvalidOwnershipUID() throws {
        let journal = CoreAudioAggregateOwnershipJournal(journalURL: uniqueJournalURL())

        XCTAssertThrowsError(try journal.recordAggregate(uid: "Auralis-not-a-uuid", deviceID: 10)) {
            XCTAssertEqual(
                $0 as? CoreAudioAggregateOwnershipJournalError,
                .invalidAggregateUID("Auralis-not-a-uuid")
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.journalURL.path))
    }

    func testProductionJournalSkipsMalformedAndUnownedEntries() throws {
        let url = uniqueJournalURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let validUID = aggregateUID()
        try Data(
            """
            {
              "version": 1,
              "records": [
                null,
                {"aggregateUID":"OtherApp-device","lastKnownDeviceID":12},
                {"aggregateUID":"\(validUID)","lastKnownDeviceID":42},
                {"aggregateUID":"Auralis-not-a-uuid","lastKnownDeviceID":99}
              ]
            }
            """.utf8
        ).write(to: url)

        let records = try CoreAudioAggregateOwnershipJournal(journalURL: url).records()

        XCTAssertEqual(records.map(\.aggregateUID), [validUID])
        XCTAssertEqual(records.map(\.lastKnownDeviceID), [42])
    }

    private func aggregateUID() -> String {
        "\(CoreAudioOrphanedAggregateCleanup.aggregateUIDPrefix)\(UUID().uuidString)"
    }

    private func uniqueJournalURL() -> URL {
        temporaryFileURL(prefix: "AuralisJournal", filename: "aggregate-ownership.json")
    }
}

private final class ConcurrentJournalFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var storedMessages: [String] = []

    var messages: [String] { lock.withLock { storedMessages } }

    func record(_ error: Error) {
        lock.withLock { storedMessages.append(error.localizedDescription) }
    }
}
