import CoreAudio
import Foundation

struct CoreAudioAggregateRecord: Equatable {
    var id: AudioObjectID
    var uid: String
    var name: String
    var isAggregate: Bool
}

protocol CoreAudioAggregateCleanupOperating: AnyObject {
    func aggregateRecords() -> [CoreAudioAggregateRecord]
    func destroyAggregateDevice(_ id: AudioObjectID) -> OSStatus
}

/// Recovers only aggregates that were durably journaled by Auralis or its
/// EQMacRep predecessor. A name prefix alone is not ownership proof: a live
/// device must match the journal identity, stable UID, and aggregate transport.
enum CoreAudioOrphanedAggregateCleanup {
    static let aggregateNamePrefix = "Auralis-"
    static let aggregateUIDPrefix = "Auralis-"
    static let legacyAggregateNamePrefix = "EQMacRep-"
    static let legacyAggregateUIDPrefix = "EQMacRep-"

    @discardableResult
    static func destroyOrphans(
        using operations: CoreAudioAggregateCleanupOperating = SystemAggregateCleanupOperations()
    ) -> [AudioObjectID] {
        destroyOrphans(journals: defaultRecoveryJournals(), using: operations)
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
        let discovered = operations.aggregateRecords()
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
                guard let live = discovered.first(where: {
                    $0.uid == ownership.aggregateUID
                        && $0.isAggregate
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

    static func defaultRecoveryJournals() -> [any CoreAudioAggregateOwnershipJournaling] {
        [
            CoreAudioAggregateOwnershipJournal.shared,
            CoreAudioAggregateOwnershipJournal.legacyShared
        ]
    }

    static func isOwnedAggregateIdentity(uid: String?, name: String) -> Bool {
        guard let uid else { return false }
        return matchesOwnedIdentity(
            uid: uid,
            name: name,
            uidPrefix: aggregateUIDPrefix,
            namePrefix: aggregateNamePrefix
        ) || matchesOwnedIdentity(
            uid: uid,
            name: name,
            uidPrefix: legacyAggregateUIDPrefix,
            namePrefix: legacyAggregateNamePrefix
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
        switch uidPrefix {
        case aggregateUIDPrefix:
            aggregateNamePrefix
        case legacyAggregateUIDPrefix:
            legacyAggregateNamePrefix
        default:
            nil
        }
    }
}

final class SystemAggregateCleanupOperations: CoreAudioAggregateCleanupOperating {
    func aggregateRecords() -> [CoreAudioAggregateRecord] {
        guard let devices: [AudioObjectID] = try? CoreAudioPropertyReader.array(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices
        ) else {
            return []
        }

        return devices.map { id in
            let uid = (try? CoreAudioPropertyReader.string(
                objectID: id,
                selector: kAudioDevicePropertyDeviceUID
            )) ?? ""
            let name = (try? CoreAudioPropertyReader.string(
                objectID: id,
                selector: kAudioObjectPropertyName
            )) ?? ""
            let transport: UInt32 = (try? CoreAudioPropertyReader.scalar(
                objectID: id,
                selector: kAudioDevicePropertyTransportType
            )) ?? 0
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
