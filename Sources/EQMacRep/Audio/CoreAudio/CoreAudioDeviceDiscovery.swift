import CoreAudio
import Foundation

final class CoreAudioDeviceDiscovery {
    struct DeviceRecord: Equatable {
        var objectID: AudioObjectID
        var uid: String?
        var name: String
        var hasOutputStreams: Bool
        var isHidden: Bool
        var transportType: UInt32 = 0
        var aggregateSubdeviceUIDs: [String] = []
        var aggregateActiveSubdeviceUIDs: [String]? = nil
        var nominalSampleRate: Double? = nil
    }

    func discoverDevices() throws -> [AudioDeviceSnapshot] {
        let state = try discoverOutputDeviceState()
        return state.devices
    }

    func discoverDefaultOutputDeviceUID() throws -> String? {
        try discoverOutputDeviceState().defaultOutputDeviceUIDs.first
    }

    func discoverOutputDeviceState() throws -> (
        devices: [AudioDeviceSnapshot],
        defaultOutputDeviceUID: String?,
        defaultOutputDeviceUIDs: [String],
        nominalSampleRatesByUID: [String: Double]
    ) {
        let devices: [AudioObjectID] = try CoreAudioPropertyReader.array(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices
        )
        let defaultDeviceID: AudioObjectID? = try? CoreAudioPropertyReader.scalar(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice
        )
        let records = devices.compactMap { makeDeviceRecord(objectID: $0) }
        let defaultOutputDeviceUIDs = Self.defaultOutputUIDs(records: records, defaultDeviceID: defaultDeviceID)
        var nominalSampleRatesByUID: [String: Double] = [:]
        for record in records {
            guard Self.mapDeviceRecord(record, defaultDeviceID: defaultDeviceID) != nil,
                  let uid = Self.normalized(record.uid),
                  let sampleRate = record.nominalSampleRate,
                  sampleRate.isFinite,
                  sampleRate > 0 else { continue }
            nominalSampleRatesByUID[uid] = sampleRate
        }

        return (
            devices: Self.sortedSnapshots(records.compactMap { Self.mapDeviceRecord($0, defaultDeviceID: defaultDeviceID) }),
            defaultOutputDeviceUID: defaultOutputDeviceUIDs.first,
            defaultOutputDeviceUIDs: defaultOutputDeviceUIDs,
            nominalSampleRatesByUID: nominalSampleRatesByUID
        )
    }

    /// Orders device snapshots default-output first, then case-insensitively by
    /// name, so the list stays stable across refreshes and the default is obvious.
    static func sortedSnapshots(_ snapshots: [AudioDeviceSnapshot]) -> [AudioDeviceSnapshot] {
        snapshots.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault && !rhs.isDefault }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    static func mapDeviceRecord(_ record: DeviceRecord, defaultDeviceID: AudioObjectID?) -> AudioDeviceSnapshot? {
        guard record.hasOutputStreams,
              !record.isHidden,
              record.transportType != kAudioDeviceTransportTypeAggregate,
              !record.name.hasPrefix(CoreAudioOrphanedAggregateCleanup.aggregateNamePrefix),
              let id = normalized(record.uid) else { return nil }

        let name = normalized(record.name) ?? normalized(record.uid) ?? "Device \(record.objectID)"
        return AudioDeviceSnapshot(id: id, name: name, isDefault: record.objectID == defaultDeviceID)
    }

    static func defaultOutputUID(records: [DeviceRecord], defaultDeviceID: AudioObjectID?) -> String? {
        defaultOutputUIDs(records: records, defaultDeviceID: defaultDeviceID).first
    }

    /// Resolves the system default to routeable physical output UIDs. macOS can
    /// make a user-created Aggregate/Multi-Output Device the default; nesting that
    /// aggregate inside EQMacRep's tap aggregate is fragile, so expand its ordered
    /// composition instead. Aggregate devices remain hidden from the picker.
    static func defaultOutputUIDs(records: [DeviceRecord], defaultDeviceID: AudioObjectID?) -> [String] {
        guard let defaultDeviceID,
              let record = records.first(where: { $0.objectID == defaultDeviceID }) else { return [] }

        if record.transportType != kAudioDeviceTransportTypeAggregate {
            guard mapDeviceRecord(record, defaultDeviceID: defaultDeviceID) != nil,
                  let uid = normalized(record.uid) else { return [] }
            return [uid]
        }

        guard record.hasOutputStreams,
              !record.isHidden,
              !record.name.hasPrefix(CoreAudioOrphanedAggregateCleanup.aggregateNamePrefix) else { return [] }

        let routeableUIDs = Set(records.compactMap { candidate -> String? in
            guard candidate.hasOutputStreams,
                  !candidate.isHidden,
                  candidate.transportType != kAudioDeviceTransportTypeAggregate,
                  !candidate.name.hasPrefix(CoreAudioOrphanedAggregateCleanup.aggregateNamePrefix) else { return nil }
            return normalized(candidate.uid)
        })
        let activeUIDs = record.aggregateActiveSubdeviceUIDs.map { uids in
            Set(uids.compactMap(normalized))
        }
        var seen = Set<String>()
        return record.aggregateSubdeviceUIDs.compactMap { rawUID in
            guard let uid = normalized(rawUID),
                  routeableUIDs.contains(uid),
                  activeUIDs?.contains(uid) ?? true,
                  seen.insert(uid).inserted else { return nil }
            return uid
        }
    }

    private func makeDeviceRecord(objectID: AudioObjectID) -> DeviceRecord? {
        let name = (try? CoreAudioPropertyReader.string(
            objectID: objectID,
            selector: kAudioObjectPropertyName
        )) ?? "Device \(objectID)"
        let uid = try? CoreAudioPropertyReader.string(
            objectID: objectID,
            selector: kAudioDevicePropertyDeviceUID
        )
        let streams: [AudioStreamID] = (try? CoreAudioPropertyReader.array(
            objectID: objectID,
            selector: kAudioDevicePropertyStreams,
            scope: kAudioObjectPropertyScopeOutput
        )) ?? []
        let isHidden: Bool
        if CoreAudioPropertyReader.hasProperty(objectID: objectID, selector: kAudioDevicePropertyIsHidden) {
            isHidden = (try? CoreAudioPropertyReader.bool(
                objectID: objectID,
                selector: kAudioDevicePropertyIsHidden
            )) ?? false
        } else {
            isHidden = false
        }
        let transportType: UInt32 = (try? CoreAudioPropertyReader.scalar(
            objectID: objectID,
            selector: kAudioDevicePropertyTransportType
        )) ?? 0
        let nominalSampleRate = try? CoreAudioPropertyReader.double(
            objectID: objectID,
            selector: kAudioDevicePropertyNominalSampleRate
        )
        let aggregateSubdeviceUIDs: [String]
        let aggregateActiveSubdeviceUIDs: [String]?
        if transportType == kAudioDeviceTransportTypeAggregate,
           CoreAudioPropertyReader.hasProperty(
               objectID: objectID,
               selector: kAudioAggregateDevicePropertyFullSubDeviceList
           ) {
            aggregateSubdeviceUIDs = (try? CoreAudioPropertyReader.stringArray(
                objectID: objectID,
                selector: kAudioAggregateDevicePropertyFullSubDeviceList
            )) ?? []
            if let activeSubdeviceIDs: [AudioObjectID] = try? CoreAudioPropertyReader.array(
                objectID: objectID,
                selector: kAudioAggregateDevicePropertyActiveSubDeviceList
            ) {
                aggregateActiveSubdeviceUIDs = activeSubdeviceIDs.compactMap {
                    try? CoreAudioPropertyReader.string(
                        objectID: $0,
                        selector: kAudioDevicePropertyDeviceUID
                    )
                }
            } else {
                aggregateActiveSubdeviceUIDs = nil
            }
        } else {
            aggregateSubdeviceUIDs = []
            aggregateActiveSubdeviceUIDs = nil
        }

        return DeviceRecord(
            objectID: objectID,
            uid: uid,
            name: name,
            hasOutputStreams: !streams.isEmpty,
            isHidden: isHidden,
            transportType: transportType,
            aggregateSubdeviceUIDs: aggregateSubdeviceUIDs,
            aggregateActiveSubdeviceUIDs: aggregateActiveSubdeviceUIDs,
            nominalSampleRate: nominalSampleRate
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
