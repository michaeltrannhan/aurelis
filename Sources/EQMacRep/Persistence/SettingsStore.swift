import Foundation

struct PersistedSettings: Codable, Equatable {
    static let currentVersion = 1

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
