import Foundation
import AuralisWidgetShared

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

private struct SettingsFileHeader: Decodable {
    let version: Int?
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

private struct TolerantDeviceSettings: Decodable {
    var values: [String: DeviceAudioSettings]

    init(from decoder: Decoder) throws {
        let object = try decoder.container(keyedBy: DynamicCodingKey.self)
        var decoded: [String: DeviceAudioSettings] = [:]
        for key in object.allKeys {
            let identity = key.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !identity.isEmpty,
                  let settings = try? object.decode(DeviceAudioSettings.self, forKey: key) else {
                continue
            }
            decoded[identity] = settings
        }
        values = decoded
    }
}

struct PersistedSettings: Codable, Equatable, Sendable {
    static let currentVersion = 8

    var version: Int
    var customization: AppCustomization
    var appSettings: [AudioAppIdentity: AppAudioSettings]
    var deviceSettings: [String: DeviceAudioSettings]
    var preferredOutputDeviceID: String?
    var profiles: [AudioProfile]
    var activeGlobalProfileID: UUID?
    var activeLocalProfileID: UUID?
    /// Version-4 compatibility mirror. New code should use the scoped IDs.
    var activeProfileID: UUID?
    var profileHasOverrides: Bool
    var pinnedAppIDs: Set<AudioAppIdentity>
    var ignoredAppIDs: Set<AudioAppIdentity>
    var appDisplayOrder: [AudioAppIdentity]
    var hasCompletedOnboarding: Bool

    init(
        customization: AppCustomization = AppCustomization(),
        appSettings: [AudioAppIdentity: AppAudioSettings] = [:],
        deviceSettings: [String: DeviceAudioSettings] = [:],
        preferredOutputDeviceID: String? = nil,
        profiles: [AudioProfile] = [],
        activeGlobalProfileID: UUID? = nil,
        activeLocalProfileID: UUID? = nil,
        activeProfileID: UUID? = nil,
        profileHasOverrides: Bool = false,
        migrateLegacyFallback: Bool = false,
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
        self.deviceSettings = Dictionary(
            uniqueKeysWithValues: deviceSettings.compactMap { key, value in
                let identity = key.trimmingCharacters(in: .whitespacesAndNewlines)
                return identity.isEmpty ? nil : (identity, value.normalized)
            }
        )
        let preferred = preferredOutputDeviceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.preferredOutputDeviceID = preferred?.isEmpty == false ? preferred : nil
        var seenProfileIDs = Set<UUID>()
        let normalizedProfiles = profiles
            .map(\.normalized)
            .filter { seenProfileIDs.insert($0.id).inserted }
        let legacyProfile = normalizedProfiles.first { $0.id == activeProfileID }
        let localCandidate = activeLocalProfileID
            ?? (legacyProfile?.scope.isGlobal == false ? activeProfileID : nil)
        self.profiles = Self.simplifiedProfiles(
            normalizedProfiles,
            preferredLocalProfileID: localCandidate
        )
        var globalCandidate = normalizedProfiles.contains {
            $0.id == activeGlobalProfileID && $0.scope.isGlobal
        } ? activeGlobalProfileID : nil
        if globalCandidate == nil, legacyProfile?.scope.isGlobal == true {
            globalCandidate = activeProfileID
        }
        if migrateLegacyFallback,
           globalCandidate == nil,
           self.profiles.contains(where: { !$0.scope.isGlobal }) {
            let fallback = AudioProfile(
                name: "Global Default",
                scope: .global,
                appSettings: AudioProfile.flatAppSettings(
                    from: self.appSettings,
                    customization: self.customization
                ),
                deviceSettings: [:],
                preferredOutputDeviceID: nil
            )
            self.profiles.append(fallback)
            globalCandidate = fallback.id
        }
        self.activeGlobalProfileID = self.profiles.contains {
            $0.id == globalCandidate && $0.scope.isGlobal
        } ? globalCandidate : nil
        self.activeLocalProfileID = self.profiles.contains {
            $0.id == localCandidate && !$0.scope.isGlobal
        } ? localCandidate : nil
        self.activeProfileID = self.activeLocalProfileID ?? self.activeGlobalProfileID
        self.profileHasOverrides = profileHasOverrides && self.activeProfileID != nil
        self.pinnedAppIDs = Set(pinnedAppIDs.filter(\.isPersistable))
        self.ignoredAppIDs = Set(ignoredAppIDs.filter(\.isPersistable))
        self.appDisplayOrder = Self.deduplicated(appDisplayOrder.filter(\.isPersistable))
        self.hasCompletedOnboarding = hasCompletedOnboarding
    }

    var globalProfilesForDisplay: [AudioProfile] {
        profiles
            .filter(\.scope.isGlobal)
            .sorted { lhs, rhs in
                let lhsIsActive = lhs.id == activeGlobalProfileID
                let rhsIsActive = rhs.id == activeGlobalProfileID
                if lhsIsActive != rhsIsActive { return lhsIsActive }
                return StableDisplayOrder.precedes(
                    lhsName: lhs.name,
                    lhsID: lhs.id.uuidString,
                    rhsName: rhs.name,
                    rhsID: rhs.id.uuidString
                )
            }
    }

    /// Version 8 treats output-scoped records as automatically saved device
    /// contexts. Global records are detached, copyable preset templates.
    var deviceContextsForDisplay: [AudioProfile] {
        profiles
            .filter { !$0.scope.isGlobal }
            .sorted {
                StableDisplayOrder.precedes(
                    lhsName: $0.name,
                    lhsID: $0.scope.outputDeviceID ?? $0.id.uuidString,
                    rhsName: $1.name,
                    rhsID: $1.scope.outputDeviceID ?? $1.id.uuidString
                )
            }
    }

    enum CodingKeys: String, CodingKey {
        case version
        case customization
        case appSettings
        case deviceSettings
        case preferredOutputDeviceID
        case profiles
        case activeGlobalProfileID
        case activeLocalProfileID
        case activeProfileID
        case profileHasOverrides
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
            deviceSettings: values.tolerant(TolerantDeviceSettings.self, forKey: .deviceSettings)?.values ?? [:],
            preferredOutputDeviceID: values.tolerant(String.self, forKey: .preferredOutputDeviceID),
            profiles: values.tolerant(TolerantArray<AudioProfile>.self, forKey: .profiles)?.values ?? [],
            activeGlobalProfileID: values.tolerant(UUID.self, forKey: .activeGlobalProfileID),
            activeLocalProfileID: values.tolerant(UUID.self, forKey: .activeLocalProfileID),
            activeProfileID: values.tolerant(UUID.self, forKey: .activeProfileID),
            profileHasOverrides: values.tolerant(Bool.self, forKey: .profileHasOverrides) ?? false,
            migrateLegacyFallback: decodedVersion < 8,
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

    /// Version 7 exposes one dedicated configuration per output. If an older
    /// settings file contains alternate output presets, keep their app
    /// snapshots as Global presets instead of deleting user data.
    private static func simplifiedProfiles(
        _ profiles: [AudioProfile],
        preferredLocalProfileID: UUID?
    ) -> [AudioProfile] {
        let grouped = Dictionary(
            grouping: profiles.filter { !$0.scope.isGlobal },
            by: { $0.scope.outputDeviceID ?? "" }
        )
        var selectedByOutput: [String: UUID] = [:]
        for (outputID, candidates) in grouped where !outputID.isEmpty {
            let selected = candidates.first { $0.id == preferredLocalProfileID }
                ?? candidates.filter(\.activatesAutomatically).max { $0.updatedAt < $1.updatedAt }
                ?? candidates.max { $0.updatedAt < $1.updatedAt }
            selectedByOutput[outputID] = selected?.id
        }

        return profiles.map { profile in
            guard let outputID = profile.scope.outputDeviceID else { return profile }
            if selectedByOutput[outputID] == profile.id {
                var configuration = profile
                configuration.activatesAutomatically = true
                return configuration.normalized
            }

            var globalPreset = profile
            globalPreset.scope = .global
            globalPreset.activatesAutomatically = false
            globalPreset.deviceSettings = [:]
            globalPreset.preferredOutputDeviceID = nil
            return globalPreset.normalized
        }
    }
}

struct SettingsStore: Sendable {
    let settingsURL: URL
    /// When set, all loaded and saved settings use this backend. Production
    /// launches use this to prevent a persisted debug-only mock selection from
    /// becoming the hidden runtime backend.
    let enforcedBackendMode: BackendMode?

    init(enforcedBackendMode: BackendMode? = nil) {
        settingsURL = Self.defaultSettingsURL()
        self.enforcedBackendMode = enforcedBackendMode
    }

    init(
        settingsURL: URL,
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

        return try loadWithRecovery(from: settingsURL)
    }

    private func loadWithRecovery(
        from sourceURL: URL
    ) throws -> SettingsLoadResult {
        let data = try Data(contentsOf: sourceURL)
        let storedVersion = (
            try? JSONDecoder().decode(SettingsFileHeader.self, from: data).version
        ) ?? 1
        let decoded: PersistedSettings
        do {
            decoded = try JSONDecoder().decode(PersistedSettings.self, from: data)
        } catch let error as SettingsStoreError {
            throw error
        } catch {
            let quarantineURL = try quarantineCorruptSettings(at: sourceURL)
            return SettingsLoadResult(
                settings: enforcingBackendMode(in: PersistedSettings()),
                recoveryNotice: SettingsRecoveryNotice(
                    originalURL: sourceURL,
                    quarantineURL: quarantineURL,
                    message: "Settings were unreadable and preserved at \(quarantineURL.path). Defaults were loaded."
                )
            )
        }

        let normalized = enforcingBackendMode(in: decoded)
        if storedVersion < PersistedSettings.currentVersion || normalized != decoded {
            // Runtime safety does not depend on this best-effort repair:
            // `load` already returns the normalized value and `save` also
            // enforces it. A later successful save will repair the file.
            try? save(normalized)
        }
        return SettingsLoadResult(settings: normalized, recoveryNotice: nil)
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
            deviceSettings: settings.deviceSettings,
            preferredOutputDeviceID: settings.preferredOutputDeviceID,
            profiles: settings.profiles,
            activeGlobalProfileID: settings.activeGlobalProfileID,
            activeLocalProfileID: settings.activeLocalProfileID,
            activeProfileID: settings.activeProfileID,
            profileHasOverrides: settings.profileHasOverrides,
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
            .appendingPathComponent("Auralis", isDirectory: true)
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

    private func quarantineCorruptSettings(at sourceURL: URL) throws -> URL {
        let directory = sourceURL.deletingLastPathComponent()
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let pathExtension = sourceURL.pathExtension
        let suffix = pathExtension.isEmpty ? "" : ".\(pathExtension)"
        let quarantineURL = directory.appendingPathComponent(
            "\(baseName).corrupt-\(UUID().uuidString)\(suffix)"
        )
        do {
            try FileManager.default.moveItem(at: sourceURL, to: quarantineURL)
            return quarantineURL
        } catch {
            throw SettingsStoreError.corruptFileCouldNotBeQuarantined(error.localizedDescription)
        }
    }
}
