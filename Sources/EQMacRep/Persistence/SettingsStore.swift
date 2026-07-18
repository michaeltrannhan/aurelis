import Foundation

enum SettingsStoreError: Error, Equatable, LocalizedError {
    case futureVersion(found: Int, supported: Int)
    case corruptFileCouldNotBeQuarantined(String)

    var errorDescription: String? {
        switch self {
        case let .futureVersion(found, supported):
            return "Settings version \(found) is newer than supported version \(supported)."
        case let .corruptFileCouldNotBeQuarantined(reason):
            return "Corrupt settings could not be preserved: \(reason)"
        }
    }
}

struct SettingsRecoveryNotice: Equatable, Sendable {
    let originalURL: URL
    let quarantineURL: URL
    let message: String
}

struct SettingsLoadResult: Equatable, Sendable {
    let settings: PersistedSettings
    let recoveryNotice: SettingsRecoveryNotice?
}

private struct TolerantAppSettings: Decodable {
    var values: [AudioAppIdentity: AppAudioSettings]

    init(from decoder: Decoder) throws {
        if let object = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            var decoded: [AudioAppIdentity: AppAudioSettings] = [:]
            for key in object.allKeys {
                let identity = AudioAppIdentity(rawValue: key.stringValue)
                guard identity.isPersistable,
                      let settings = try? object.decode(AppAudioSettings.self, forKey: key) else {
                    continue
                }
                decoded[identity] = settings
            }
            values = decoded
            return
        }

        var array = try decoder.unkeyedContainer()
        var decoded: [AudioAppIdentity: AppAudioSettings] = [:]
        while !array.isAtEnd {
            let identityIndex = array.currentIndex
            guard let identity = try? array.decode(AudioAppIdentity.self) else {
                if array.currentIndex == identityIndex {
                    _ = try? array.decode(DiscardedJSONValue.self)
                }
                if !array.isAtEnd { _ = try? array.decode(DiscardedJSONValue.self) }
                continue
            }

            guard !array.isAtEnd else { break }
            let settingsIndex = array.currentIndex
            if let settings = try? array.decode(AppAudioSettings.self), identity.isPersistable {
                decoded[identity] = settings
            } else if array.currentIndex == settingsIndex {
                _ = try? array.decode(DiscardedJSONValue.self)
            }
        }
        values = decoded
    }
}

struct PersistedSettings: Codable, Equatable, Sendable {
    static let currentVersion = 3

    var version: Int
    var customization: AppCustomization
    var appSettings: [AudioAppIdentity: AppAudioSettings]
    var pinnedAppIDs: Set<AudioAppIdentity>
    var ignoredAppIDs: Set<AudioAppIdentity>
    var appDisplayOrder: [AudioAppIdentity]
    var hasCompletedOnboarding: Bool

    init(
        version: Int = currentVersion,
        customization: AppCustomization = AppCustomization(),
        appSettings: [AudioAppIdentity: AppAudioSettings] = [:],
        pinnedAppIDs: Set<AudioAppIdentity> = [],
        ignoredAppIDs: Set<AudioAppIdentity> = [],
        appDisplayOrder: [AudioAppIdentity] = [],
        hasCompletedOnboarding: Bool = false
    ) {
        self.version = Self.currentVersion
        self.customization = customization.normalized
        self.appSettings = Dictionary(
            uniqueKeysWithValues: appSettings
                .filter { $0.key.isPersistable }
                .map { ($0.key, $0.value.normalized) }
        )
        self.pinnedAppIDs = Set(pinnedAppIDs.filter(\.isPersistable))
        self.ignoredAppIDs = Set(ignoredAppIDs.filter(\.isPersistable))
        self.appDisplayOrder = Self.deduplicated(appDisplayOrder.filter(\.isPersistable))
        self.hasCompletedOnboarding = hasCompletedOnboarding
    }

    enum CodingKeys: String, CodingKey {
        case version
        case customization
        case appSettings
        case pinnedAppIDs
        case ignoredAppIDs
        case appDisplayOrder
        case hasCompletedOnboarding
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = values.tolerant(Int.self, forKey: .version) ?? 1
        guard decodedVersion <= Self.currentVersion else {
            throw SettingsStoreError.futureVersion(found: decodedVersion, supported: Self.currentVersion)
        }
        var decodedCustomization = values.tolerant(AppCustomization.self, forKey: .customization) ?? AppCustomization()

        if decodedVersion < 2, decodedCustomization.backendMode == .mock {
            decodedCustomization.backendMode = .coreAudioDiscovery
        }

        self.init(
            customization: decodedCustomization,
            appSettings: values.tolerant(TolerantAppSettings.self, forKey: .appSettings)?.values ?? [:],
            pinnedAppIDs: Set(values.tolerant(TolerantArray<AudioAppIdentity>.self, forKey: .pinnedAppIDs)?.values ?? []),
            ignoredAppIDs: Set(values.tolerant(TolerantArray<AudioAppIdentity>.self, forKey: .ignoredAppIDs)?.values ?? []),
            appDisplayOrder: values.tolerant(TolerantArray<AudioAppIdentity>.self, forKey: .appDisplayOrder)?.values ?? [],
            hasCompletedOnboarding: values.tolerant(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        )
    }

    private static func deduplicated(_ identities: [AudioAppIdentity]) -> [AudioAppIdentity] {
        var seen: Set<AudioAppIdentity> = []
        return identities.filter { seen.insert($0).inserted }
    }
}

struct SettingsStore: Sendable {
    let settingsURL: URL
    /// When set, all loaded and saved settings use this backend. Production
    /// launches use this to prevent a persisted debug-only mock selection from
    /// becoming the hidden runtime backend.
    let enforcedBackendMode: BackendMode?

    init(
        settingsURL: URL = SettingsStore.defaultSettingsURL(),
        enforcedBackendMode: BackendMode? = nil
    ) {
        self.settingsURL = settingsURL
        self.enforcedBackendMode = enforcedBackendMode
    }

    func load() throws -> PersistedSettings {
        try loadWithRecovery().settings
    }

    func loadWithRecovery() throws -> SettingsLoadResult {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return SettingsLoadResult(
                settings: enforcingBackendMode(in: PersistedSettings()),
                recoveryNotice: nil
            )
        }

        let data = try Data(contentsOf: settingsURL)
        do {
            let decoded = try JSONDecoder().decode(PersistedSettings.self, from: data)
            let normalized = enforcingBackendMode(in: decoded)
            if normalized != decoded {
                // Runtime safety does not depend on this best-effort migration:
                // `load` already returns the normalized value and `save` also
                // enforces it. A later successful save will repair the file.
                try? save(normalized)
            }
            return SettingsLoadResult(settings: normalized, recoveryNotice: nil)
        } catch let error as SettingsStoreError {
            throw error
        } catch {
            let quarantineURL = try quarantineCorruptSettings()
            return SettingsLoadResult(
                settings: enforcingBackendMode(in: PersistedSettings()),
                recoveryNotice: SettingsRecoveryNotice(
                    originalURL: settingsURL,
                    quarantineURL: quarantineURL,
                    message: "Settings were unreadable and preserved at \(quarantineURL.path). Defaults were loaded."
                )
            )
        }
    }

    func save(_ settings: PersistedSettings) throws {
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let canonical = PersistedSettings(
            customization: settings.customization,
            appSettings: settings.appSettings,
            pinnedAppIDs: settings.pinnedAppIDs,
            ignoredAppIDs: settings.ignoredAppIDs,
            appDisplayOrder: settings.appDisplayOrder,
            hasCompletedOnboarding: settings.hasCompletedOnboarding
        )
        let data = try encoder.encode(enforcingBackendMode(in: canonical))
        try data.write(to: settingsURL, options: [.atomic])
    }

    func reset() throws {
        try save(PersistedSettings())
    }

    func defaultSettings() -> PersistedSettings {
        enforcingBackendMode(in: PersistedSettings())
    }

    static func defaultSettingsURL() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EQMacRep", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    private func enforcingBackendMode(in settings: PersistedSettings) -> PersistedSettings {
        guard let enforcedBackendMode,
              settings.customization.backendMode != enforcedBackendMode else {
            return settings
        }
        var settings = settings
        settings.customization.backendMode = enforcedBackendMode
        return settings
    }

    private func quarantineCorruptSettings() throws -> URL {
        let directory = settingsURL.deletingLastPathComponent()
        let baseName = settingsURL.deletingPathExtension().lastPathComponent
        let pathExtension = settingsURL.pathExtension
        let suffix = pathExtension.isEmpty ? "" : ".\(pathExtension)"
        let quarantineURL = directory.appendingPathComponent(
            "\(baseName).corrupt-\(UUID().uuidString)\(suffix)"
        )
        do {
            try FileManager.default.moveItem(at: settingsURL, to: quarantineURL)
            return quarantineURL
        } catch {
            throw SettingsStoreError.corruptFileCouldNotBeQuarantined(error.localizedDescription)
        }
    }
}
