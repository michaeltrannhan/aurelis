import CoreAudio
import XCTest
@testable import EQMacRep

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

        XCTAssertThrowsError(try journal.recordAggregate(uid: "EQMacRep-not-a-uuid", deviceID: 10)) {
            XCTAssertEqual(
                $0 as? CoreAudioAggregateOwnershipJournalError,
                .invalidAggregateUID("EQMacRep-not-a-uuid")
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
                {"aggregateUID":"EQMacRep-not-a-uuid","lastKnownDeviceID":99}
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
        temporaryFileURL(prefix: "EQMacRepJournal", filename: "aggregate-ownership.json")
    }
}
