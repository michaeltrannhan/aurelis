import Foundation

struct PersistedSettings: Codable, Equatable {
    static let currentVersion = 2

    var version: Int
    var customization: AppCustomization
    var appSettings: [AudioAppIdentity: AppAudioSettings]
    var pinnedAppIDs: Set<AudioAppIdentity>
    var ignoredAppIDs: Set<AudioAppIdentity>

    init(
        version: Int = currentVersion,
        customization: AppCustomization = AppCustomization(),
        appSettings: [AudioAppIdentity: AppAudioSettings] = [:],
        pinnedAppIDs: Set<AudioAppIdentity> = [],
        ignoredAppIDs: Set<AudioAppIdentity> = []
    ) {
        self.version = version
        self.customization = customization
        self.appSettings = appSettings
        self.pinnedAppIDs = pinnedAppIDs
        self.ignoredAppIDs = ignoredAppIDs
    }

    enum CodingKeys: String, CodingKey {
        case version
        case customization
        case appSettings
        case pinnedAppIDs
        case ignoredAppIDs
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
    }
}

struct SettingsStore {
    let settingsURL: URL

    init(settingsURL: URL = SettingsStore.defaultSettingsURL()) {
        self.settingsURL = settingsURL
    }

    func load() throws -> PersistedSettings {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return PersistedSettings()
        }

        do {
            let data = try Data(contentsOf: settingsURL)
            return try JSONDecoder().decode(PersistedSettings.self, from: data)
        } catch {
            return PersistedSettings()
        }
    }

    func save(_ settings: PersistedSettings) throws {
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
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
}
