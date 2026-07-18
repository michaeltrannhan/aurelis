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

/// Recovers only aggregates that were durably journaled by this process. A name
/// prefix alone is not ownership proof: a live device must match the journaled
/// stable UID and still report aggregate transport before it is destroyed.
enum CoreAudioOrphanedAggregateCleanup {
    static let aggregateNamePrefix = "EQMacRep-"
    static let aggregateUIDPrefix = "EQMacRep-"

    @discardableResult
    static func destroyOrphans(
        journal: any CoreAudioAggregateOwnershipJournaling = CoreAudioAggregateOwnershipJournal.shared,
        using operations: CoreAudioAggregateCleanupOperating = SystemAggregateCleanupOperations()
    ) -> [AudioObjectID] {
        guard let ownershipRecords = try? journal.records() else { return [] }
        let discovered = operations.aggregateRecords()
        var recovered: [AudioObjectID] = []

        for ownership in ownershipRecords where ownership.isValid {
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
        return recovered
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
