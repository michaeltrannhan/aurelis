import Foundation

enum AudioProfileContextPlanner {
    static func referencedOutputDeviceIDs(
        in appSettings: [AudioAppIdentity: AppAudioSettings],
        followDefaultOutputID: String?
    ) -> Set<String> {
        var result = Set<String>()
        for settings in appSettings.values {
            switch settings.route.normalized {
            case .followDefault:
                if let followDefaultOutputID {
                    result.insert(followDefaultOutputID)
                }
            case let .selectedDevice(deviceID):
                result.insert(deviceID)
            case let .multiOutput(deviceIDs):
                result.formUnion(deviceIDs)
            }
        }
        return result
    }

    static func setActiveProfiles(
        globalID: UUID?,
        localID: UUID?,
        in settings: inout PersistedSettings
    ) {
        settings.activeGlobalProfileID = globalID
        settings.activeLocalProfileID = localID
        settings.activeProfileID = localID ?? globalID
        settings.profileHasOverrides = false
    }

    /// Keeps one autosaved context per connected output and fills new app identities neutrally.
    static func ensureAutomaticDeviceContexts(
        in settings: inout PersistedSettings,
        devices: [AudioDeviceSnapshot]
    ) {
        let neutralSettings = AudioProfile.flatAppSettings(
            from: settings.appSettings,
            customization: settings.customization
        )

        for index in settings.profiles.indices where !settings.profiles[index].scope.isGlobal {
            for (identity, neutral) in neutralSettings
            where settings.profiles[index].appSettings[identity] == nil {
                settings.profiles[index].appSettings[identity] = neutral
            }
            settings.profiles[index].activatesAutomatically = true
        }

        var configuredIDs = Set(settings.profiles.compactMap(\.scope.outputDeviceID))
        for device in devices where configuredIDs.insert(device.id).inserted {
            let capturedDevice = settings.deviceSettings[device.id].map { [device.id: $0] } ?? [:]
            settings.profiles.append(AudioProfile(
                name: device.name,
                scope: .outputDevice(device.id),
                activatesAutomatically: true,
                appSettings: neutralSettings,
                deviceSettings: capturedDevice,
                preferredOutputDeviceID: device.id
            ))
        }
    }

    static func upsertOutputConfiguration(
        _ configuration: AudioProfile,
        for outputID: String,
        currentOutputID: String?,
        in settings: inout PersistedSettings
    ) {
        let globalID = settings.activeGlobalProfileID
        convertOtherOutputConfigurationsToPresets(
            for: outputID,
            except: configuration.id,
            in: &settings
        )
        if let index = settings.profiles.firstIndex(where: { $0.id == configuration.id }) {
            settings.profiles[index] = configuration.normalized
        } else {
            settings.profiles.append(configuration.normalized)
        }

        let retainedLocalID = settings.activeLocalProfileID.flatMap { activeID in
            settings.profiles.first {
                $0.id == activeID && $0.scope.outputDeviceID == currentOutputID
            }?.id
        }
        setActiveProfiles(
            globalID: globalID,
            localID: currentOutputID == outputID ? configuration.id : retainedLocalID,
            in: &settings
        )
    }

    /// Writes live mixer state through to the active physical-output context.
    static func updateActiveDeviceContext(
        in settings: inout PersistedSettings,
        currentOutputID: String?,
        changedDeviceID: String? = nil,
        updatedAt: Date = Date()
    ) {
        var contextIDs = Set<String>()
        if let changedDeviceID { contextIDs.insert(changedDeviceID) }
        if let currentOutputID { contextIDs.insert(currentOutputID) }
        guard !contextIDs.isEmpty else { return }

        for index in settings.profiles.indices {
            guard let contextOutputID = settings.profiles[index].scope.outputDeviceID,
                  contextIDs.contains(contextOutputID) else { continue }
            let isCurrentContext = contextOutputID == currentOutputID
            if isCurrentContext {
                settings.profiles[index].appSettings = settings.appSettings
            }

            var capturedIDs = referencedOutputDeviceIDs(
                in: settings.profiles[index].appSettings,
                followDefaultOutputID: contextOutputID
            )
            capturedIDs.insert(contextOutputID)
            settings.profiles[index].deviceSettings = settings.deviceSettings.filter {
                capturedIDs.contains($0.key)
            }
            settings.profiles[index].updatedAt = updatedAt

            if isCurrentContext {
                settings.activeGlobalProfileID = nil
                settings.activeLocalProfileID = settings.profiles[index].id
                settings.activeProfileID = settings.profiles[index].id
            }
        }
        settings.profileHasOverrides = false
    }

    private static func convertOtherOutputConfigurationsToPresets(
        for outputID: String,
        except retainedID: UUID,
        in settings: inout PersistedSettings
    ) {
        for index in settings.profiles.indices
        where settings.profiles[index].id != retainedID
            && settings.profiles[index].scope.outputDeviceID == outputID {
            settings.profiles[index].scope = .global
            settings.profiles[index].activatesAutomatically = false
            settings.profiles[index].deviceSettings = [:]
            settings.profiles[index].preferredOutputDeviceID = nil
        }
    }
}
