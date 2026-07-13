import Foundation

struct PersistedSettings: Codable, Equatable {
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
        self.version = version
        self.customization = customization
        self.appSettings = appSettings
        self.pinnedAppIDs = pinnedAppIDs
        self.ignoredAppIDs = ignoredAppIDs
        self.appDisplayOrder = appDisplayOrder
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
        let decodedVersion = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        var decodedCustomization = try values.decodeIfPresent(AppCustomization.self, forKey: .customization) ?? AppCustomization()

        if decodedVersion < 2, decodedCustomization.backendMode == .mock {
            decodedCustomization.backendMode = .coreAudioDiscovery
        }

        version = Self.currentVersion
        customization = decodedCustomization
        appSettings = try values.decodeIfPresent([AudioAppIdentity: AppAudioSettings].self, forKey: .appSettings) ?? [:]
        pinnedAppIDs = try values.decodeIfPresent(Set<AudioAppIdentity>.self, forKey: .pinnedAppIDs) ?? []
        ignoredAppIDs = try values.decodeIfPresent(Set<AudioAppIdentity>.self, forKey: .ignoredAppIDs) ?? []
        appDisplayOrder = try values.decodeIfPresent([AudioAppIdentity].self, forKey: .appDisplayOrder) ?? []
        hasCompletedOnboarding = try values.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
    }
}

struct SettingsStore {
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
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return enforcingBackendMode(in: PersistedSettings())
        }

        do {
            let data = try Data(contentsOf: settingsURL)
            let decoded = try JSONDecoder().decode(PersistedSettings.self, from: data)
            let normalized = enforcingBackendMode(in: decoded)
            if normalized != decoded {
                // Runtime safety does not depend on this best-effort migration:
                // `load` already returns the normalized value and `save` also
                // enforces it. A later successful save will repair the file.
                try? save(normalized)
            }
            return normalized
        } catch {
            return enforcingBackendMode(in: PersistedSettings())
        }
    }

    func save(_ settings: PersistedSettings) throws {
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(enforcingBackendMode(in: settings))
        try data.write(to: settingsURL, options: [.atomic])
    }

    func reset() throws {
        try save(PersistedSettings())
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
}
