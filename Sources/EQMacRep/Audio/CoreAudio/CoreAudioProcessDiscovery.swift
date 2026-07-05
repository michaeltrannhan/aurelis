import AppKit
import CoreAudio
import Foundation

final class CoreAudioProcessDiscovery {
    struct ProcessRecord: Equatable {
        var processObjectID: AudioObjectID
        var processID: pid_t
        var bundleIdentifier: String?
        var displayName: String?
        var executableName: String?
        var isRunning: Bool
    }

    func discoverProcesses() throws -> [AudioAppSnapshot] {
        let processObjects: [AudioObjectID] = try CoreAudioPropertyReader.array(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyProcessObjectList
        )
        let currentPID = ProcessInfo.processInfo.processIdentifier

        let records = processObjects.compactMap { makeProcessRecord(processObjectID: $0) }
        return Self.mapProcessRecords(records, currentProcessID: currentPID)
    }

    func discoverTapTargets() throws -> [CoreAudioTapTarget] {
        let processObjects: [AudioObjectID] = try CoreAudioPropertyReader.array(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyProcessObjectList
        )
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let records = processObjects.compactMap { makeProcessRecord(processObjectID: $0) }
        return Self.mapTapTargets(records: records, currentProcessID: currentPID)
    }

    static func mapProcessRecords(_ records: [ProcessRecord], currentProcessID: pid_t) -> [AudioAppSnapshot] {
        let snapshots = records.compactMap { record in
            mapProcessRecord(parentAdjustedRecord(for: record, in: records), currentProcessID: currentProcessID)
        }
        return coalescedSnapshots(snapshots)
    }

    static func mapTapTargets(records: [ProcessRecord], currentProcessID: pid_t) -> [CoreAudioTapTarget] {
        var targetsByIdentity: [AudioAppIdentity: CoreAudioTapTarget] = [:]

        for record in records {
            let adjustedRecord = parentAdjustedRecord(for: record, in: records)
            guard let snapshot = mapProcessRecord(adjustedRecord, currentProcessID: currentProcessID) else {
                continue
            }

            if var existing = targetsByIdentity[snapshot.identity] {
                existing.processObjectIDs.append(record.processObjectID)
                existing.processObjectIDs.sort()
                if shouldPreferDisplayName(snapshot.displayName, over: existing.displayName) {
                    existing.displayName = snapshot.displayName
                }
                targetsByIdentity[snapshot.identity] = existing
            } else {
                targetsByIdentity[snapshot.identity] = CoreAudioTapTarget(
                    identity: snapshot.identity,
                    displayName: snapshot.displayName,
                    processObjectIDs: [record.processObjectID]
                )
            }
        }

        return targetsByIdentity.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    static func mapProcessRecord(_ record: ProcessRecord, currentProcessID: pid_t) -> AudioAppSnapshot? {
        guard record.processID != currentProcessID, record.isRunning else { return nil }

        let displayName = normalized(record.displayName)
            ?? normalized(record.executableName)
            ?? normalized(record.bundleIdentifier)
            ?? "Process \(record.processID)"
        guard !isIgnoredSystemProcess(displayName: displayName, bundleIdentifier: record.bundleIdentifier) else {
            return nil
        }

        let bundleIdentifier = normalized(record.bundleIdentifier)
        return AudioAppSnapshot(
            identity: AudioAppIdentity(bundleID: bundleIdentifier, fallbackName: displayName),
            displayName: displayName,
            bundleIdentifier: bundleIdentifier,
            isActive: true,
            level: 0
        )
    }

    static func coalescedSnapshots(_ snapshots: [AudioAppSnapshot]) -> [AudioAppSnapshot] {
        var snapshotsByIdentity: [AudioAppIdentity: AudioAppSnapshot] = [:]

        for snapshot in snapshots {
            guard var existing = snapshotsByIdentity[snapshot.identity] else {
                snapshotsByIdentity[snapshot.identity] = snapshot
                continue
            }

            if shouldPreferDisplayName(snapshot.displayName, over: existing.displayName) {
                existing.displayName = snapshot.displayName
            }
            if existing.bundleIdentifier == nil {
                existing.bundleIdentifier = snapshot.bundleIdentifier
            }
            existing.isActive = existing.isActive || snapshot.isActive
            existing.level = max(existing.level, snapshot.level)
            snapshotsByIdentity[snapshot.identity] = existing
        }

        return snapshotsByIdentity.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private func makeProcessRecord(processObjectID: AudioObjectID) -> ProcessRecord? {
        guard let pid: pid_t = try? CoreAudioPropertyReader.scalar(
            objectID: processObjectID,
            selector: kAudioProcessPropertyPID
        ) else {
            return nil
        }

        let runningOutput = (try? CoreAudioPropertyReader.bool(
            objectID: processObjectID,
            selector: kAudioProcessPropertyIsRunningOutput
        ))
        let isRunning = runningOutput ?? ((try? CoreAudioPropertyReader.bool(
            objectID: processObjectID,
            selector: kAudioProcessPropertyIsRunning
        )) ?? false)

        let bundleIdentifier = try? CoreAudioPropertyReader.string(
            objectID: processObjectID,
            selector: kAudioProcessPropertyBundleID
        )
        let runningApplication = NSRunningApplication(processIdentifier: pid)
        let displayName = runningApplication?.localizedName ?? runningApplication?.bundleURL?.deletingPathExtension().lastPathComponent
        let executableName = runningApplication?.executableURL?.lastPathComponent

        return ProcessRecord(
            processObjectID: processObjectID,
            processID: pid,
            bundleIdentifier: normalized(bundleIdentifier) ?? normalized(runningApplication?.bundleIdentifier),
            displayName: displayName,
            executableName: executableName,
            isRunning: isRunning
        )
    }

    private static func isIgnoredSystemProcess(displayName: String, bundleIdentifier: String?) -> Bool {
        let name = displayName.lowercased()
        if ["coreaudiod", "audiocomponentregistrar", "runningboardd", "launchd", "kernel_task"].contains(name) {
            return true
        }

        guard let bundleIdentifier = normalized(bundleIdentifier)?.lowercased() else { return false }
        return [
            "com.apple.audio.audiocomponentregistrar",
            "com.apple.audio.coreaudiod"
        ].contains(bundleIdentifier)
    }

    private static func shouldPreferDisplayName(_ candidate: String, over existing: String) -> Bool {
        let candidateName = candidate.lowercased()
        let existingName = existing.lowercased()
        if existingName.contains("helper"), !candidateName.contains("helper") {
            return true
        }
        if existingName.contains("renderer"), !candidateName.contains("renderer") {
            return true
        }
        return candidate.count < existing.count
    }

    private static func parentAdjustedRecord(for record: ProcessRecord, in records: [ProcessRecord]) -> ProcessRecord {
        guard record.isRunning, isLikelyHelper(record), let parent = parentRecord(for: record, in: records) else {
            return record
        }

        var adjusted = record
        adjusted.bundleIdentifier = normalized(parent.bundleIdentifier) ?? adjusted.bundleIdentifier
        adjusted.displayName = normalized(parent.displayName) ?? adjusted.displayName
        adjusted.executableName = normalized(parent.executableName) ?? adjusted.executableName
        return adjusted
    }

    private static func parentRecord(for record: ProcessRecord, in records: [ProcessRecord]) -> ProcessRecord? {
        let childKeys = parentLookupKeys(for: record)
        guard !childKeys.isEmpty else { return nil }

        return records
            .filter { candidate in
                guard candidate.processObjectID != record.processObjectID || candidate.processID != record.processID else {
                    return false
                }
                return !parentLookupKeys(for: candidate).isDisjoint(with: childKeys)
            }
            .sorted { lhs, rhs in
                parentRecordScore(lhs) > parentRecordScore(rhs)
            }
            .first
    }

    private static func parentRecordScore(_ record: ProcessRecord) -> Int {
        var score = 0
        if normalized(record.bundleIdentifier) != nil { score += 4 }
        if normalized(record.displayName) != nil { score += 2 }
        if !isLikelyHelper(record) { score += 1 }
        return score
    }

    private static func isLikelyHelper(_ record: ProcessRecord) -> Bool {
        [record.bundleIdentifier, record.displayName, record.executableName]
            .compactMap(normalized)
            .map { $0.lowercased() }
            .contains { value in
                value.contains("helper")
                    || value.contains("renderer")
                    || value.contains("gpu process")
                    || value.hasSuffix(".gpu")
            }
    }

    private static func parentLookupKeys(for record: ProcessRecord) -> Set<String> {
        var keys = Set<String>()

        if let bundleIdentifier = normalized(record.bundleIdentifier)?.lowercased() {
            keys.insert(strippingHelperBundleSuffixes(from: bundleIdentifier))
        }
        if let displayName = normalized(record.displayName)?.lowercased() {
            keys.insert(strippingHelperNameSuffixes(from: displayName))
        }
        if let executableName = normalized(record.executableName)?.lowercased() {
            keys.insert(strippingHelperNameSuffixes(from: executableName))
        }

        return keys.filter { !$0.isEmpty }
    }

    private static func strippingHelperBundleSuffixes(from value: String) -> String {
        var stripped = value
        for suffix in [".helper", ".renderer", ".gpu", ".plugin"] where stripped.hasSuffix(suffix) {
            stripped.removeLast(suffix.count)
        }
        return stripped
    }

    private static func strippingHelperNameSuffixes(from value: String) -> String {
        var stripped = value
        for suffix in [" helper", " renderer", " gpu process", " gpu", " plugin"] where stripped.hasSuffix(suffix) {
            stripped.removeLast(suffix.count)
        }
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func normalized(_ value: String?) -> String? {
        Self.normalized(value)
    }
}
