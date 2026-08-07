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

    func testCleanupPrunesJournalRecordWhenAggregateNoLongerExists() throws {
        let journal = CoreAudioAggregateOwnershipJournal(journalURL: uniqueJournalURL())
        let uid = aggregateUID()
        try journal.recordAggregate(uid: uid, deviceID: 100)
        let operations = FakeAggregateCleanupOperations(records: [])

        XCTAssertTrue(
            CoreAudioOrphanedAggregateCleanup.destroyOrphans(
                journal: journal,
                using: operations
            ).isEmpty
        )
        XCTAssertTrue(operations.destroyed.isEmpty)
        XCTAssertTrue(try journal.records().isEmpty)
    }

    func testDiscoveryFailurePreservesJournalForNextLaunchRetry() throws {
        let journal = CoreAudioAggregateOwnershipJournal(journalURL: uniqueJournalURL())
        let uid = aggregateUID()
        try journal.recordAggregate(uid: uid, deviceID: 100)
        let operations = FakeAggregateCleanupOperations(
            records: [],
            discoveryFails: true
        )

        XCTAssertTrue(
            CoreAudioOrphanedAggregateCleanup.destroyOrphans(
                journal: journal,
                using: operations
            ).isEmpty
        )
        XCTAssertEqual(try journal.records().map(\.aggregateUID), [uid])
    }

    private func aggregateUID() -> String {
        "\(CoreAudioOrphanedAggregateCleanup.aggregateUIDPrefix)\(UUID().uuidString)"
    }

    private func uniqueJournalURL() -> URL {
        temporaryFileURL(prefix: "AuralisCleanup", filename: "aggregate-ownership.json")
    }
}

private final class FakeAggregateCleanupOperations: CoreAudioAggregateCleanupOperating {
    private enum DiscoveryError: Error {
        case failed
    }

    private let records: [CoreAudioAggregateRecord]
    private let destroyStatus: OSStatus
    private let discoveryFails: Bool
    private(set) var destroyed: [AudioObjectID] = []

    init(
        records: [CoreAudioAggregateRecord],
        destroyStatus: OSStatus = noErr,
        discoveryFails: Bool = false
    ) {
        self.records = records
        self.destroyStatus = destroyStatus
        self.discoveryFails = discoveryFails
    }

    func aggregateRecords() throws -> [CoreAudioAggregateRecord] {
        if discoveryFails { throw DiscoveryError.failed }
        return records
    }

    func destroyAggregateDevice(_ id: AudioObjectID) -> OSStatus {
        destroyed.append(id)
        return destroyStatus
    }
}
