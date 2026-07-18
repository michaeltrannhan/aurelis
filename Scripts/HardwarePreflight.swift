import CoreAudio
import Foundation

private enum HardwarePreflightError: Error, CustomStringConvertible {
    case invalidMinimum(String)
    case propertyRead(AudioObjectID, AudioObjectPropertySelector, OSStatus)
    case corruptJournal(String)

    var description: String {
        switch self {
        case let .invalidMinimum(value):
            "minimum physical output count must be a nonnegative integer, got '\(value)'"
        case let .propertyRead(objectID, selector, status):
            "CoreAudio property \(fourCC(selector)) failed for object \(objectID): \(status)"
        case let .corruptJournal(reason):
            "aggregate ownership journal is unreadable: \(reason)"
        }
    }
}

private enum AggregateIdentity {
    static let currentPrefix = "Auralis-"
    // Retained only so an upgrade can detect and clean devices left by the
    // previous application identity after a crash.
    static let legacyPrefix = "EQMacRep-"
    static let recognizedPrefixes = [currentPrefix, legacyPrefix]
}

private struct OutputDevice {
    var id: AudioObjectID
    var uid: String
    var name: String
    var transport: UInt32
    var sampleRate: Double
    var isDefault: Bool

    var isPhysical: Bool {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn,
             kAudioDeviceTransportTypePCI,
             kAudioDeviceTransportTypeUSB,
             kAudioDeviceTransportTypeFireWire,
             kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE,
             kAudioDeviceTransportTypeHDMI,
             kAudioDeviceTransportTypeDisplayPort,
             kAudioDeviceTransportTypeAirPlay,
             kAudioDeviceTransportTypeAVB,
             kAudioDeviceTransportTypeThunderbolt:
            true
        default:
            false
        }
    }

    var isOwnedAggregate: Bool {
        let isAggregate = transport == kAudioDeviceTransportTypeAggregate
            || transport == kAudioDeviceTransportTypeAutoAggregate
        return isAggregate && AggregateIdentity.recognizedPrefixes.contains { prefix in
            uid.hasPrefix(prefix) || name.hasPrefix(prefix)
        }
    }
}

private func address(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
}

private func scalar<T: FixedWidthInteger>(
    _ type: T.Type,
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) throws -> T {
    var property = address(selector, scope: scope)
    var value = T.zero
    var size = UInt32(MemoryLayout<T>.size)
    let status = AudioObjectGetPropertyData(objectID, &property, 0, nil, &size, &value)
    guard status == noErr else {
        throw HardwarePreflightError.propertyRead(objectID, selector, status)
    }
    return value
}

private func double(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector
) throws -> Double {
    var property = address(selector)
    var value: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    let status = AudioObjectGetPropertyData(objectID, &property, 0, nil, &size, &value)
    guard status == noErr else {
        throw HardwarePreflightError.propertyRead(objectID, selector, status)
    }
    return value
}

private func array<T: FixedWidthInteger>(
    _ type: T.Type,
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) throws -> [T] {
    var property = address(selector, scope: scope)
    var size: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(objectID, &property, 0, nil, &size)
    guard status == noErr else {
        throw HardwarePreflightError.propertyRead(objectID, selector, status)
    }
    guard size > 0 else { return [] }

    var values = Array(repeating: T.zero, count: Int(size) / MemoryLayout<T>.stride)
    status = values.withUnsafeMutableBufferPointer { buffer in
        AudioObjectGetPropertyData(objectID, &property, 0, nil, &size, buffer.baseAddress!)
    }
    guard status == noErr else {
        throw HardwarePreflightError.propertyRead(objectID, selector, status)
    }
    return values
}

private func string(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector
) throws -> String {
    var property = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &value) { pointer in
        AudioObjectGetPropertyData(objectID, &property, 0, nil, &size, pointer)
    }
    guard status == noErr else {
        throw HardwarePreflightError.propertyRead(objectID, selector, status)
    }
    return value?.takeRetainedValue() as String? ?? ""
}

private func outputDevices() throws -> [OutputDevice] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    let defaultOutput = try scalar(
        AudioObjectID.self,
        objectID: system,
        selector: kAudioHardwarePropertyDefaultOutputDevice
    )
    let deviceIDs = try array(
        AudioObjectID.self,
        objectID: system,
        selector: kAudioHardwarePropertyDevices
    )

    return try deviceIDs.compactMap { id -> OutputDevice? in
        let streams = try array(
            AudioStreamID.self,
            objectID: id,
            selector: kAudioDevicePropertyStreams,
            scope: kAudioDevicePropertyScopeOutput
        )
        guard !streams.isEmpty else { return nil }
        return try OutputDevice(
            id: id,
            uid: string(objectID: id, selector: kAudioDevicePropertyDeviceUID),
            name: string(objectID: id, selector: kAudioObjectPropertyName),
            transport: scalar(
                UInt32.self,
                objectID: id,
                selector: kAudioDevicePropertyTransportType
            ),
            sampleRate: double(objectID: id, selector: kAudioDevicePropertyNominalSampleRate),
            isDefault: id == defaultOutput
        )
    }
}

private func journalRecordUIDs(at url: URL) throws -> [String] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    do {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = object["records"] as? [[String: Any]] else {
            throw HardwarePreflightError.corruptJournal("missing records array")
        }
        return records.compactMap { $0["aggregateUID"] as? String }
    } catch let error as HardwarePreflightError {
        throw error
    } catch {
        throw HardwarePreflightError.corruptJournal(error.localizedDescription)
    }
}

private func transportName(_ transport: UInt32) -> String {
    switch transport {
    case kAudioDeviceTransportTypeBuiltIn: "built-in"
    case kAudioDeviceTransportTypePCI: "PCI"
    case kAudioDeviceTransportTypeUSB: "USB"
    case kAudioDeviceTransportTypeFireWire: "FireWire"
    case kAudioDeviceTransportTypeBluetooth: "Bluetooth"
    case kAudioDeviceTransportTypeBluetoothLE: "Bluetooth LE"
    case kAudioDeviceTransportTypeHDMI: "HDMI"
    case kAudioDeviceTransportTypeDisplayPort: "DisplayPort"
    case kAudioDeviceTransportTypeAirPlay: "AirPlay"
    case kAudioDeviceTransportTypeAVB: "AVB"
    case kAudioDeviceTransportTypeThunderbolt: "Thunderbolt"
    case kAudioDeviceTransportTypeAggregate: "aggregate"
    case kAudioDeviceTransportTypeAutoAggregate: "auto-aggregate"
    case kAudioDeviceTransportTypeVirtual: "virtual"
    default: fourCC(transport)
    }
}

private func fourCC(_ value: UInt32) -> String {
    let bytes = [
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff)
    ]
    return String(bytes: bytes, encoding: .macOSRoman) ?? String(value)
}

do {
    let minimumArgument = CommandLine.arguments.dropFirst().first ?? "2"
    guard let minimumPhysicalOutputs = Int(minimumArgument), minimumPhysicalOutputs >= 0 else {
        throw HardwarePreflightError.invalidMinimum(minimumArgument)
    }
    let applicationSupportURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let currentJournalURL = applicationSupportURL
        .appendingPathComponent("Auralis", isDirectory: true)
        .appendingPathComponent("aggregate-ownership.json")
    // Read-only legacy inspection prevents an old crash journal from being
    // mistaken for a clean starting state during the identity migration.
    let legacyJournalURL = applicationSupportURL
        .appendingPathComponent("EQMacRep", isDirectory: true)
        .appendingPathComponent("aggregate-ownership.json")
    let journalURLs = [currentJournalURL, legacyJournalURL]
    let devices = try outputDevices()
    let physical = devices.filter(\.isPhysical)
    let staleAggregates = devices.filter(\.isOwnedAggregate)
    let journalRecords = try journalURLs.map { url in
        (url: url, uids: try journalRecordUIDs(at: url))
    }
    let journalUIDs = journalRecords.flatMap { $0.uids }

    print("Auralis read-only hardware preflight")
    print("  OS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
#if arch(arm64)
    print("  architecture: arm64")
#elseif arch(x86_64)
    print("  architecture: x86_64")
#else
    print("  architecture: unknown")
#endif
    print("  output devices: \(devices.count); physical: \(physical.count); required: \(minimumPhysicalOutputs)")
    for device in devices.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
        let defaultMarker = device.isDefault ? ", default" : ""
        let physicalMarker = device.isPhysical ? "physical" : "non-physical"
        print(
            "    - \(device.name) [\(transportName(device.transport)), \(physicalMarker)\(defaultMarker), \(Int(device.sampleRate.rounded())) Hz]"
        )
    }
    print("  live owned aggregates: \(staleAggregates.count)")
    print("  ownership journal records: \(journalUIDs.count)")
    for journal in journalRecords where !journal.uids.isEmpty {
        print("    - \(journal.uids.count) at \(journal.url.path)")
    }

    var failures: [String] = []
    if physical.count < minimumPhysicalOutputs {
        failures.append("found \(physical.count) physical outputs; need at least \(minimumPhysicalOutputs)")
    }
    if !staleAggregates.isEmpty {
        failures.append("live owned aggregates remain: \(staleAggregates.map(\.name).joined(separator: ", "))")
    }
    if !journalUIDs.isEmpty {
        failures.append("ownership journal is not empty: \(journalUIDs.joined(separator: ", "))")
    }

    guard failures.isEmpty else {
        for failure in failures { FileHandle.standardError.write(Data("error: \(failure)\n".utf8)) }
        exit(1)
    }
    print("PASS: clean starting state and physical-output prerequisite satisfied")
    print("NOTE: this preflight does not play audio, change routes, request permissions, or replace the hands-on matrix.")
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
