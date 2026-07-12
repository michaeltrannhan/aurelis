import CoreAudio
import XCTest
@testable import EQMacRep

final class CoreAudioOrphanedAggregateCleanupTests: XCTestCase {
    func testCleanupDestroysOnlyEQMacRepAggregateDevices() {
        let operations = FakeAggregateCleanupOperations(records: [
            .init(id: 1, name: "EQMacRep-Music", isAggregate: true),
            .init(id: 2, name: "FineTune-Music", isAggregate: true),
            .init(id: 3, name: "EQMacRep-USB", isAggregate: false),
            .init(id: 4, name: "EQMacRep-Browser", isAggregate: true)
        ])

        let destroyed = CoreAudioOrphanedAggregateCleanup.destroyOrphans(using: operations)

        XCTAssertEqual(destroyed, [1, 4])
        XCTAssertEqual(operations.destroyed, [1, 4])
    }
}

private final class FakeAggregateCleanupOperations: CoreAudioAggregateCleanupOperating {
    private let records: [CoreAudioAggregateRecord]
    private(set) var destroyed: [AudioObjectID] = []

    init(records: [CoreAudioAggregateRecord]) {
        self.records = records
    }

    func aggregateRecords() -> [CoreAudioAggregateRecord] { records }

    func destroyAggregateDevice(_ id: AudioObjectID) -> OSStatus {
        destroyed.append(id)
        return noErr
    }
}
