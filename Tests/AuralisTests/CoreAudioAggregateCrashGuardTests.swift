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

    func testDefaultRecoveryJournalsCoverCurrentAndLegacyApplicationSupportLocations() {
        let journals = CoreAudioOrphanedAggregateCleanup.defaultRecoveryJournals()

        XCTAssertEqual(
            journals.map(\.journalURL),
            [
                CoreAudioAggregateOwnershipJournal.defaultJournalURL(),
                CoreAudioAggregateOwnershipJournal.legacyJournalURL()
            ]
        )
        XCTAssertEqual(
            journals.map(\.aggregateUIDPrefix),
            [
                CoreAudioOrphanedAggregateCleanup.aggregateUIDPrefix,
                CoreAudioOrphanedAggregateCleanup.legacyAggregateUIDPrefix
            ]
        )
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

    func testLegacyProductionJournalAcceptsOnlyLegacyOwnershipUIDs() throws {
        let url = uniqueJournalURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let legacyUID = legacyAggregateUID()
        let currentUID = aggregateUID()
        try Data(
            """
            {
              "version": 1,
              "records": [
                {"aggregateUID":"\(legacyUID)","lastKnownDeviceID":71},
                {"aggregateUID":"\(currentUID)","lastKnownDeviceID":72},
                {"aggregateUID":"EQMacRep-not-a-uuid","lastKnownDeviceID":73}
              ]
            }
            """.utf8
        ).write(to: url)
        let journal = CoreAudioAggregateOwnershipJournal(
            journalURL: url,
            aggregateUIDPrefix: CoreAudioOrphanedAggregateCleanup.legacyAggregateUIDPrefix
        )

        let records = try journal.records()

        XCTAssertEqual(records.map(\.aggregateUID), [legacyUID])
        XCTAssertEqual(records.map(\.lastKnownDeviceID), [71])
        XCTAssertThrowsError(try journal.recordAggregate(uid: currentUID, deviceID: 74)) {
            XCTAssertEqual(
                $0 as? CoreAudioAggregateOwnershipJournalError,
                .invalidAggregateUID(currentUID)
            )
        }
    }

    private func aggregateUID() -> String {
        "\(CoreAudioOrphanedAggregateCleanup.aggregateUIDPrefix)\(UUID().uuidString)"
    }

    private func legacyAggregateUID() -> String {
        "\(CoreAudioOrphanedAggregateCleanup.legacyAggregateUIDPrefix)\(UUID().uuidString)"
    }

    private func uniqueJournalURL() -> URL {
        temporaryFileURL(prefix: "AuralisJournal", filename: "aggregate-ownership.json")
    }
}
