import CoreAudio
import Foundation

final class CoreAudioDeviceDiscovery {
    struct DeviceRecord: Equatable {
        var objectID: AudioObjectID
        var uid: String?
        var name: String
        var hasOutputStreams: Bool
        var isHidden: Bool
    }

    func discoverDevices() throws -> [AudioDeviceSnapshot] {
        let state = try discoverOutputDeviceState()
        return state.devices
    }

    func discoverDefaultOutputDeviceUID() throws -> String? {
        try discoverOutputDeviceState().defaultOutputDeviceUID
    }

    func discoverOutputDeviceState() throws -> (devices: [AudioDeviceSnapshot], defaultOutputDeviceUID: String?) {
        let devices: [AudioObjectID] = try CoreAudioPropertyReader.array(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices
        )
        let defaultDeviceID: AudioObjectID? = try? CoreAudioPropertyReader.scalar(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice
        )
        let records = devices.compactMap { makeDeviceRecord(objectID: $0) }

        return (
            devices: records.compactMap { Self.mapDeviceRecord($0, defaultDeviceID: defaultDeviceID) },
            defaultOutputDeviceUID: Self.defaultOutputUID(records: records, defaultDeviceID: defaultDeviceID)
        )
    }

    static func mapDeviceRecord(_ record: DeviceRecord, defaultDeviceID: AudioObjectID?) -> AudioDeviceSnapshot? {
        guard record.hasOutputStreams, !record.isHidden else { return nil }

        let fallbackID = "device:\(record.objectID)"
        let id = normalized(record.uid) ?? fallbackID
        let name = normalized(record.name) ?? normalized(record.uid) ?? "Device \(record.objectID)"
        return AudioDeviceSnapshot(id: id, name: name, isDefault: record.objectID == defaultDeviceID)
    }

    static func defaultOutputUID(records: [DeviceRecord], defaultDeviceID: AudioObjectID?) -> String? {
        guard let defaultDeviceID else { return nil }
        return records.first { $0.objectID == defaultDeviceID }.flatMap { normalized($0.uid) }
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

        return DeviceRecord(
            objectID: objectID,
            uid: uid,
            name: name,
            hasOutputStreams: !streams.isEmpty,
            isHidden: isHidden
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
