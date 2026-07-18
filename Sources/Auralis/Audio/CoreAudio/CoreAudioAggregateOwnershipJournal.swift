import CoreAudio
import Foundation

enum CoreAudioAggregateOwnershipJournalError: Error, Equatable, LocalizedError {
    case invalidAggregateUID(String)
    case futureVersion(found: Int, supported: Int)
    case corruptJournalCouldNotBeQuarantined(String)

    var errorDescription: String? {
        switch self {
        case let .invalidAggregateUID(uid):
            "Invalid aggregate UID for ownership journal: \(uid)"
        case let .futureVersion(found, supported):
            "Aggregate journal version \(found) is newer than supported version \(supported)."
        case let .corruptJournalCouldNotBeQuarantined(reason):
            "Corrupt aggregate journal could not be preserved: \(reason)"
        }
    }
}

struct CoreAudioAggregateOwnershipRecord: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var aggregateUID: String
    var lastKnownDeviceID: AudioObjectID
    var createdAt: Date

    init(
        schemaVersion: Int = currentSchemaVersion,
        aggregateUID: String,
        lastKnownDeviceID: AudioObjectID,
        createdAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.aggregateUID = aggregateUID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.lastKnownDeviceID = lastKnownDeviceID
        self.createdAt = createdAt
    }

    var isValid: Bool {
        isValid(aggregateUIDPrefix: CoreAudioOrphanedAggregateCleanup.aggregateUIDPrefix)
    }

    func isValid(aggregateUIDPrefix: String) -> Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              aggregateUID.hasPrefix(aggregateUIDPrefix) else {
            return false
        }
        let suffix = String(aggregateUID.dropFirst(aggregateUIDPrefix.count))
        return UUID(uuidString: suffix) != nil
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case aggregateUID
        case lastKnownDeviceID
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: values.tolerant(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion,
            aggregateUID: values.tolerant(String.self, forKey: .aggregateUID) ?? "",
            lastKnownDeviceID: values.tolerant(AudioObjectID.self, forKey: .lastKnownDeviceID)
                ?? AudioObjectID(kAudioObjectUnknown),
            createdAt: values.tolerant(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        )
    }
}

protocol CoreAudioAggregateOwnershipJournaling: AnyObject, Sendable {
    var journalURL: URL { get }
    var aggregateUIDPrefix: String { get }
    func records() throws -> [CoreAudioAggregateOwnershipRecord]
    func recordAggregate(uid: String, deviceID: AudioObjectID) throws
    func removeAggregate(uid: String) throws
}

extension CoreAudioAggregateOwnershipJournaling {
    var aggregateUIDPrefix: String {
        CoreAudioOrphanedAggregateCleanup.aggregateUIDPrefix
    }
}

private struct CoreAudioAggregateOwnershipPayload: Codable {
    static let currentVersion = 1

    var version: Int
    var records: [CoreAudioAggregateOwnershipRecord]

    init(records: [CoreAudioAggregateOwnershipRecord]) {
        version = Self.currentVersion
        self.records = records
    }

    enum CodingKeys: String, CodingKey {
        case version
        case records
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = values.tolerant(Int.self, forKey: .version) ?? 1
        guard version <= Self.currentVersion else {
            throw CoreAudioAggregateOwnershipJournalError.futureVersion(
                found: version,
                supported: Self.currentVersion
            )
        }
        self.version = Self.currentVersion
        records = values.tolerant(
            TolerantArray<CoreAudioAggregateOwnershipRecord>.self,
            forKey: .records
        )?.values ?? []
    }
}

private actor CoreAudioAggregateOwnershipPersistenceActor {
    let journalURL: URL
    let aggregateUIDPrefix: String

    init(journalURL: URL, aggregateUIDPrefix: String) {
        self.journalURL = journalURL
        self.aggregateUIDPrefix = aggregateUIDPrefix
    }

    func records() throws -> [CoreAudioAggregateOwnershipRecord] {
        try loadRecords()
    }

    func recordAggregate(uid: String, deviceID: AudioObjectID) throws {
        let record = CoreAudioAggregateOwnershipRecord(
            aggregateUID: uid,
            lastKnownDeviceID: deviceID
        )
        guard record.isValid(aggregateUIDPrefix: aggregateUIDPrefix) else {
            throw CoreAudioAggregateOwnershipJournalError.invalidAggregateUID(uid)
        }
        var records = try loadRecords()
        records.removeAll { $0.aggregateUID == record.aggregateUID }
        records.append(record)
        try save(records)
    }

    func removeAggregate(uid: String) throws {
        var records = try loadRecords()
        let originalCount = records.count
        records.removeAll { $0.aggregateUID == uid }
        guard records.count != originalCount else { return }
        try save(records)
    }

    private func loadRecords() throws -> [CoreAudioAggregateOwnershipRecord] {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return [] }
        let data = try Data(contentsOf: journalURL)
        do {
            let payload = try JSONDecoder().decode(CoreAudioAggregateOwnershipPayload.self, from: data)
            var seen: Set<String> = []
            return payload.records.reversed().filter {
                $0.isValid(aggregateUIDPrefix: aggregateUIDPrefix)
                    && seen.insert($0.aggregateUID).inserted
            }.reversed()
        } catch let error as CoreAudioAggregateOwnershipJournalError {
            throw error
        } catch {
            try quarantineCorruptJournal()
            return []
        }
    }

    private func save(_ records: [CoreAudioAggregateOwnershipRecord]) throws {
        try FileManager.default.createDirectory(
            at: journalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(CoreAudioAggregateOwnershipPayload(records: records))
        try data.write(to: journalURL, options: .atomic)
    }

    private func quarantineCorruptJournal() throws {
        let quarantineURL = journalURL.deletingPathExtension().appendingPathExtension(
            "corrupt-\(UUID().uuidString).json"
        )
        do {
            try FileManager.default.moveItem(at: journalURL, to: quarantineURL)
        } catch {
            throw CoreAudioAggregateOwnershipJournalError.corruptJournalCouldNotBeQuarantined(
                error.localizedDescription
            )
        }
    }
}

private final class BlockingAggregateJournalResult<Value>: @unchecked Sendable {
    var result: Result<Value, Error>?
}

/// Synchronous lifecycle facade backed by an actor. Aggregate creation cannot
/// proceed until its ownership record is durably written, while the filesystem
/// work itself executes outside the caller's actor/executor.
final class CoreAudioAggregateOwnershipJournal: CoreAudioAggregateOwnershipJournaling, @unchecked Sendable {
    static let shared = CoreAudioAggregateOwnershipJournal()
    static let legacyShared = CoreAudioAggregateOwnershipJournal(
        journalURL: legacyJournalURL(),
        aggregateUIDPrefix: CoreAudioOrphanedAggregateCleanup.legacyAggregateUIDPrefix
    )

    let journalURL: URL
    let aggregateUIDPrefix: String
    private let persistence: CoreAudioAggregateOwnershipPersistenceActor

    init(
        journalURL: URL = CoreAudioAggregateOwnershipJournal.defaultJournalURL(),
        aggregateUIDPrefix: String = CoreAudioOrphanedAggregateCleanup.aggregateUIDPrefix
    ) {
        self.journalURL = journalURL
        self.aggregateUIDPrefix = aggregateUIDPrefix
        persistence = CoreAudioAggregateOwnershipPersistenceActor(
            journalURL: journalURL,
            aggregateUIDPrefix: aggregateUIDPrefix
        )
    }

    func records() throws -> [CoreAudioAggregateOwnershipRecord] {
        try Self.wait { [persistence] in try await persistence.records() }
    }

    func recordAggregate(uid: String, deviceID: AudioObjectID) throws {
        try Self.wait { [persistence] in
            try await persistence.recordAggregate(uid: uid, deviceID: deviceID)
        }
    }

    func removeAggregate(uid: String) throws {
        try Self.wait { [persistence] in
            try await persistence.removeAggregate(uid: uid)
        }
    }

    static func defaultJournalURL() -> URL {
        journalURL(applicationSupportDirectoryName: "Auralis")
    }

    static func legacyJournalURL() -> URL {
        journalURL(applicationSupportDirectoryName: "EQMacRep")
    }

    private static func journalURL(applicationSupportDirectoryName: String) -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("aggregate-ownership.json")
    }

    private static func wait<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) throws -> Value {
        let semaphore = DispatchSemaphore(value: 0)
        let box = BlockingAggregateJournalResult<Value>()
        Task.detached(priority: .userInitiated) {
            do {
                box.result = .success(try await operation())
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try box.result!.get()
    }
}
