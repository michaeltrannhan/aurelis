import CoreAudio
import XCTest
@testable import Auralis

final class CoreAudioOrphanedAggregateCleanupTests: XCTestCase {
    func testCleanupDestroysOnlyJournaledAggregateWithMatchingStableUID() throws {
        let journal = CoreAudioAggregateOwnershipJournal(journalURL: uniqueJournalURL())
        let ownedUID = aggregateUID()
        let wrongTransportUID = aggregateUID()
        try journal.recordAggregate(uid: ownedUID, deviceID: 900)
        try journal.recordAggregate(uid: wrongTransportUID, deviceID: 901)
        let operations = FakeAggregateCleanupOperations(records: [
            .init(id: 1, uid: ownedUID, name: "Auralis-Music", isAggregate: true),
            .init(id: 2, uid: aggregateUID(), name: "Auralis-Unjournaled", isAggregate: true),
            .init(id: 3, uid: wrongTransportUID, name: "Auralis-USB", isAggregate: false),
            .init(id: 4, uid: ownedUID, name: "FineTune-Music", isAggregate: true)
        ])

        let destroyed = CoreAudioOrphanedAggregateCleanup.destroyOrphans(
            journal: journal,
            using: operations
        )

        XCTAssertEqual(destroyed, [1])
        XCTAssertEqual(operations.destroyed, [1])
        XCTAssertEqual(try journal.records().map(\.aggregateUID), [wrongTransportUID])
    }

    func testFailedRecoveryKeepsJournalRecordForNextLaunchRetry() throws {
        let journal = CoreAudioAggregateOwnershipJournal(journalURL: uniqueJournalURL())
        let uid = aggregateUID()
        try journal.recordAggregate(uid: uid, deviceID: 100)
        let record = CoreAudioAggregateRecord(
            id: 7,
            uid: uid,
            name: "Auralis-Browser",
            isAggregate: true
        )
        let failed = FakeAggregateCleanupOperations(records: [record], destroyStatus: -1)

        XCTAssertTrue(CoreAudioOrphanedAggregateCleanup.destroyOrphans(journal: journal, using: failed).isEmpty)
        XCTAssertEqual(try journal.records().map(\.aggregateUID), [uid])

        let recovered = FakeAggregateCleanupOperations(records: [record])
        XCTAssertEqual(
            CoreAudioOrphanedAggregateCleanup.destroyOrphans(journal: journal, using: recovered),
            [7]
        )
        XCTAssertTrue(try journal.records().isEmpty)
    }

    func testLegacyCleanupRequiresMatchingUIDNamePrefixAndAggregateTransport() throws {
        let journal = legacyJournal()
        let ownedUID = legacyAggregateUID()
        let wrongNameUID = legacyAggregateUID()
        let wrongTransportUID = legacyAggregateUID()
        try journal.recordAggregate(uid: ownedUID, deviceID: 200)
        try journal.recordAggregate(uid: wrongNameUID, deviceID: 201)
        try journal.recordAggregate(uid: wrongTransportUID, deviceID: 202)
        let operations = FakeAggregateCleanupOperations(records: [
            .init(id: 20, uid: ownedUID, name: "EQMacRep-Music", isAggregate: true),
            .init(id: 21, uid: wrongNameUID, name: "Auralis-Browser", isAggregate: true),
            .init(id: 22, uid: wrongTransportUID, name: "EQMacRep-USB", isAggregate: false),
            .init(id: 23, uid: legacyAggregateUID(), name: "EQMacRep-Unjournaled", isAggregate: true)
        ])

        let destroyed = CoreAudioOrphanedAggregateCleanup.destroyOrphans(
            journal: journal,
            using: operations
        )

        XCTAssertEqual(destroyed, [20])
        XCTAssertEqual(operations.destroyed, [20])
        XCTAssertEqual(
            try journal.records().map(\.aggregateUID),
            [wrongNameUID, wrongTransportUID]
        )
    }

    func testMixedRecoveryCleansCurrentAndLegacyJournals() throws {
        let currentJournal = CoreAudioAggregateOwnershipJournal(journalURL: uniqueJournalURL())
        let legacyJournal = legacyJournal()
        let currentUID = aggregateUID()
        let legacyUID = legacyAggregateUID()
        try currentJournal.recordAggregate(uid: currentUID, deviceID: 300)
        try legacyJournal.recordAggregate(uid: legacyUID, deviceID: 301)
        let operations = FakeAggregateCleanupOperations(records: [
            .init(id: 30, uid: currentUID, name: "Auralis-Music", isAggregate: true),
            .init(id: 31, uid: legacyUID, name: "EQMacRep-Browser", isAggregate: true)
        ])

        let destroyed = CoreAudioOrphanedAggregateCleanup.destroyOrphans(
            journals: [currentJournal, legacyJournal],
            using: operations
        )

        XCTAssertEqual(destroyed, [30, 31])
        XCTAssertEqual(operations.destroyed, [30, 31])
        XCTAssertTrue(try currentJournal.records().isEmpty)
        XCTAssertTrue(try legacyJournal.records().isEmpty)
    }

    func testInjectedJournalCleanupDoesNotReadLegacyJournal() throws {
        let currentJournal = CoreAudioAggregateOwnershipJournal(journalURL: uniqueJournalURL())
        let legacyJournal = legacyJournal()
        let currentUID = aggregateUID()
        let legacyUID = legacyAggregateUID()
        try currentJournal.recordAggregate(uid: currentUID, deviceID: 400)
        try legacyJournal.recordAggregate(uid: legacyUID, deviceID: 401)
        let operations = FakeAggregateCleanupOperations(records: [
            .init(id: 40, uid: currentUID, name: "Auralis-Music", isAggregate: true),
            .init(id: 41, uid: legacyUID, name: "EQMacRep-Music", isAggregate: true)
        ])

        let destroyed = CoreAudioOrphanedAggregateCleanup.destroyOrphans(
            journal: currentJournal,
            using: operations
        )

        XCTAssertEqual(destroyed, [40])
        XCTAssertEqual(operations.destroyed, [40])
        XCTAssertTrue(try currentJournal.records().isEmpty)
        XCTAssertEqual(try legacyJournal.records().map(\.aggregateUID), [legacyUID])
    }

    private func aggregateUID() -> String {
        "\(CoreAudioOrphanedAggregateCleanup.aggregateUIDPrefix)\(UUID().uuidString)"
    }

    private func legacyAggregateUID() -> String {
        "\(CoreAudioOrphanedAggregateCleanup.legacyAggregateUIDPrefix)\(UUID().uuidString)"
    }

    private func legacyJournal() -> CoreAudioAggregateOwnershipJournal {
        CoreAudioAggregateOwnershipJournal(
            journalURL: temporaryFileURL(
                prefix: "AuralisLegacyCleanup",
                filename: "aggregate-ownership.json"
            ),
            aggregateUIDPrefix: CoreAudioOrphanedAggregateCleanup.legacyAggregateUIDPrefix
        )
    }

    private func uniqueJournalURL() -> URL {
        temporaryFileURL(prefix: "AuralisCleanup", filename: "aggregate-ownership.json")
    }
}

private final class FakeAggregateCleanupOperations: CoreAudioAggregateCleanupOperating {
    private let records: [CoreAudioAggregateRecord]
    private let destroyStatus: OSStatus
    private(set) var destroyed: [AudioObjectID] = []

    init(records: [CoreAudioAggregateRecord], destroyStatus: OSStatus = noErr) {
        self.records = records
        self.destroyStatus = destroyStatus
    }

    func aggregateRecords() -> [CoreAudioAggregateRecord] { records }

    func destroyAggregateDevice(_ id: AudioObjectID) -> OSStatus {
        destroyed.append(id)
        return destroyStatus
    }
}
