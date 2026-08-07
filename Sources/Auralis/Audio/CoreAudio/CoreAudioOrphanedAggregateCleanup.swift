import CoreAudio
import Foundation

struct CoreAudioAggregateRecord: Equatable {
    var id: AudioObjectID
    var uid: String
    var name: String
    var isAggregate: Bool
}

protocol CoreAudioAggregateCleanupOperating: AnyObject {
    func aggregateRecords() throws -> [CoreAudioAggregateRecord]
    func destroyAggregateDevice(_ id: AudioObjectID) -> OSStatus
}

/// Recovers only aggregates that were durably journaled by Auralis. A name
/// prefix alone is not ownership proof: a live device must match the journal
/// identity, stable UID, and aggregate transport.
enum CoreAudioOrphanedAggregateCleanup {
    static let aggregateNamePrefix = "Auralis-"
    static let aggregateUIDPrefix = "Auralis-"

    @discardableResult
    static func destroyOrphans(
        using operations: CoreAudioAggregateCleanupOperating = SystemAggregateCleanupOperations()
    ) -> [AudioObjectID] {
        destroyOrphans(journal: CoreAudioAggregateOwnershipJournal.shared, using: operations)
    }

    @discardableResult
    static func destroyOrphans(
        journal: any CoreAudioAggregateOwnershipJournaling,
        using operations: CoreAudioAggregateCleanupOperating = SystemAggregateCleanupOperations()
    ) -> [AudioObjectID] {
        destroyOrphans(journals: [journal], using: operations)
    }

    @discardableResult
    static func destroyOrphans(
        journals: [any CoreAudioAggregateOwnershipJournaling],
        using operations: CoreAudioAggregateCleanupOperating
    ) -> [AudioObjectID] {
        // Never discard durable ownership proof when Core Audio inventory is
        // incomplete. A transient property failure is indistinguishable from
        // an absent device unless discovery reports failure explicitly.
        guard let discovered = try? operations.aggregateRecords() else {
            return []
        }
        var recovered: [AudioObjectID] = []

        for journal in journals {
            guard let aggregateNamePrefix = aggregateNamePrefix(
                matchingUIDPrefix: journal.aggregateUIDPrefix
            ), let ownershipRecords = try? journal.records() else {
                continue
            }

            for ownership in ownershipRecords where ownership.isValid(
                aggregateUIDPrefix: journal.aggregateUIDPrefix
            ) {
                let recordsWithMatchingUID = discovered.filter {
                    $0.uid == ownership.aggregateUID
                }
                guard !recordsWithMatchingUID.isEmpty else {
                    // HAL can remove a private aggregate when its owner exits
                    // before Auralis gets a chance to clear the journal. Once a
                    // complete inventory proves the stable UID is gone, the
                    // ownership record is itself stale and safe to prune.
                    try? journal.removeAggregate(uid: ownership.aggregateUID)
                    continue
                }
                guard let live = recordsWithMatchingUID.first(where: {
                    $0.isAggregate
                        && $0.name.hasPrefix(aggregateNamePrefix)
                }) else {
                    continue
                }
                guard operations.destroyAggregateDevice(live.id) == noErr else { continue }
                recovered.append(live.id)
                try? journal.removeAggregate(uid: ownership.aggregateUID)
            }
        }
        return recovered
    }

    static func isOwnedAggregateIdentity(uid: String?, name: String) -> Bool {
        guard let uid else { return false }
        return matchesOwnedIdentity(
            uid: uid,
            name: name,
            uidPrefix: aggregateUIDPrefix,
            namePrefix: aggregateNamePrefix
        )
    }

    private static func matchesOwnedIdentity(
        uid: String,
        name: String,
        uidPrefix: String,
        namePrefix: String
    ) -> Bool {
        guard name.hasPrefix(namePrefix), uid.hasPrefix(uidPrefix) else { return false }
        return UUID(uuidString: String(uid.dropFirst(uidPrefix.count))) != nil
    }

    private static func aggregateNamePrefix(matchingUIDPrefix uidPrefix: String) -> String? {
        uidPrefix == aggregateUIDPrefix ? aggregateNamePrefix : nil
    }
}

final class SystemAggregateCleanupOperations: CoreAudioAggregateCleanupOperating {
    func aggregateRecords() throws -> [CoreAudioAggregateRecord] {
        let devices: [AudioObjectID] = try CoreAudioPropertyReader.array(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices
        )

        return try devices.map { id in
            let uid = try CoreAudioPropertyReader.string(
                objectID: id,
                selector: kAudioDevicePropertyDeviceUID
            )
            let name = try CoreAudioPropertyReader.string(
                objectID: id,
                selector: kAudioObjectPropertyName
            )
            let transport: UInt32 = try CoreAudioPropertyReader.scalar(
                objectID: id,
                selector: kAudioDevicePropertyTransportType
            )
            return CoreAudioAggregateRecord(
                id: id,
                uid: uid,
                name: name,
                isAggregate: transport == kAudioDeviceTransportTypeAggregate
            )
        }
    }

    func destroyAggregateDevice(_ id: AudioObjectID) -> OSStatus {
        AudioHardwareDestroyAggregateDevice(id)
    }
}
