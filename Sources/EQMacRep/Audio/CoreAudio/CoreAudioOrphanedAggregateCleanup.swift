import CoreAudio
import Foundation

struct CoreAudioAggregateRecord: Equatable {
    var id: AudioObjectID
    var name: String
    var isAggregate: Bool
}

protocol CoreAudioAggregateCleanupOperating: AnyObject {
    func aggregateRecords() -> [CoreAudioAggregateRecord]
    func destroyAggregateDevice(_ id: AudioObjectID) -> OSStatus
}

/// Destroys leftover `EQMacRep-` aggregate devices from a previous run (e.g. after
/// a crash) so system audio returns to normal on startup. Only touches our own
/// aggregates, identified by name prefix and aggregate transport type.
enum CoreAudioOrphanedAggregateCleanup {
    static let aggregateNamePrefix = "EQMacRep-"

    @discardableResult
    static func destroyOrphans(
        using operations: CoreAudioAggregateCleanupOperating = SystemAggregateCleanupOperations()
    ) -> [AudioObjectID] {
        operations.aggregateRecords().compactMap { record in
            guard record.isAggregate, record.name.hasPrefix(aggregateNamePrefix) else { return nil }
            return operations.destroyAggregateDevice(record.id) == noErr ? record.id : nil
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
            let name = (try? CoreAudioPropertyReader.string(objectID: id, selector: kAudioObjectPropertyName)) ?? ""
            let transport: UInt32 = (try? CoreAudioPropertyReader.scalar(objectID: id, selector: kAudioDevicePropertyTransportType)) ?? 0
            return CoreAudioAggregateRecord(id: id, name: name, isAggregate: transport == kAudioDeviceTransportTypeAggregate)
        }
    }

    func destroyAggregateDevice(_ id: AudioObjectID) -> OSStatus {
        AudioHardwareDestroyAggregateDevice(id)
    }
}
