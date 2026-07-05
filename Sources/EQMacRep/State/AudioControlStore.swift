import Combine
import Foundation

@MainActor
final class AudioControlStore: ObservableObject {
    let settingsStore: SettingsStore
    private let backend: any AudioBackend

    @Published var settings: PersistedSettings
    @Published private(set) var appSnapshots: [AudioAppSnapshot] = []
    @Published private(set) var devices: [AudioDeviceSnapshot] = []
    @Published private(set) var displayRows: [DisplayableAppRow] = []
    @Published private(set) var statusMessage: String = "Ready"

    init(settingsStore: SettingsStore = SettingsStore(), backend: any AudioBackend = MockAudioBackend()) throws {
        self.settingsStore = settingsStore
        self.backend = backend
        self.settings = try settingsStore.load()
        rebuildDisplayRows()
    }

    func refresh() throws {
        do {
            let snapshot = try backend.fetchSnapshot()
            appSnapshots = snapshot.apps.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            devices = snapshot.devices
            for app in appSnapshots {
                ensureSettings(for: app)
            }
            try persist()
            statusMessage = "Loaded \(appSnapshots.count) app\(appSnapshots.count == 1 ? "" : "s")"
        } catch {
            statusMessage = "Backend error: \(error.localizedDescription)"
            throw error
        }
        rebuildDisplayRows()
    }

    func pin(_ identity: AudioAppIdentity) throws {
        settings.pinnedAppIDs.insert(identity)
        try persistAndRebuild()
    }

    func unpin(_ identity: AudioAppIdentity) throws {
        settings.pinnedAppIDs.remove(identity)
        try persistAndRebuild()
    }

    func ignore(_ identity: AudioAppIdentity) throws {
        settings.ignoredAppIDs.insert(identity)
        settings.pinnedAppIDs.remove(identity)
        try persistAndRebuild()
    }

    func unignore(_ identity: AudioAppIdentity) throws {
        settings.ignoredAppIDs.remove(identity)
        try persistAndRebuild()
    }

    func setVolume(_ volume: Double, for identity: AudioAppIdentity) throws {
        ensureSettings(for: identity)
        settings.appSettings[identity]?.setVolume(volume)
        let applied = settings.appSettings[identity]?.volume ?? 1
        try backend.apply(.setVolume(identity, applied))
        try persistAndRebuild()
    }

    func setMuted(_ muted: Bool, for identity: AudioAppIdentity) throws {
        ensureSettings(for: identity)
        settings.appSettings[identity]?.isMuted = muted
        try backend.apply(.setMuted(identity, muted))
        try persistAndRebuild()
    }

    func setBoost(_ boost: BoostLevel, for identity: AudioAppIdentity) throws {
        ensureSettings(for: identity)
        settings.appSettings[identity]?.boost = boost
        try backend.apply(.setBoost(identity, boost))
        try persistAndRebuild()
    }

    func setEQGain(_ gain: Double, band: Int, for identity: AudioAppIdentity) throws {
        ensureSettings(for: identity)
        settings.appSettings[identity]?.eq.setGain(gain, at: band)
        if let eq = settings.appSettings[identity]?.eq {
            try backend.apply(.setEQ(identity, eq))
        }
        try persistAndRebuild()
    }

    func applyCustomization(_ customization: AppCustomization) throws {
        let previousRange = settings.customization.eqGainRange
        settings.customization = customization
        if previousRange != customization.eqGainRange {
            for identity in settings.appSettings.keys {
                settings.appSettings[identity]?.eq.applyRange(customization.eqGainRange)
            }
        }
        try persistAndRebuild()
    }

    func reset() throws {
        settings = PersistedSettings()
        try persistAndRebuild()
    }

    private func ensureSettings(for app: AudioAppSnapshot) {
        if settings.appSettings[app.identity] == nil {
            settings.appSettings[app.identity] = AppAudioSettings(
                displayName: app.displayName,
                volume: settings.customization.defaultNewAppVolume,
                eq: EQCurve(range: settings.customization.eqGainRange)
            )
        } else {
            settings.appSettings[app.identity]?.displayName = app.displayName
        }
    }

    private func ensureSettings(for identity: AudioAppIdentity) {
        if settings.appSettings[identity] != nil { return }
        let snapshot = appSnapshots.first { $0.identity == identity }
        settings.appSettings[identity] = AppAudioSettings(
            displayName: snapshot?.displayName ?? identity.rawValue,
            volume: settings.customization.defaultNewAppVolume,
            eq: EQCurve(range: settings.customization.eqGainRange)
        )
    }

    private func rebuildDisplayRows() {
        let snapshotsByID = Dictionary(uniqueKeysWithValues: appSnapshots.map { ($0.identity, $0) })
        var identities = Set(appSnapshots.map(\.identity))
        identities.formUnion(settings.pinnedAppIDs)

        displayRows = identities
            .compactMap { identity -> DisplayableAppRow? in
                guard !settings.ignoredAppIDs.contains(identity),
                      let appSettings = settings.appSettings[identity] else {
                    return nil
                }

                let snapshot = snapshotsByID[identity]
                let isActive = snapshot?.isActive ?? false
                let isPinned = settings.pinnedAppIDs.contains(identity)
                guard settings.customization.showInactiveApps || isActive || isPinned else {
                    return nil
                }

                return DisplayableAppRow(
                    identity: identity,
                    displayName: snapshot?.displayName ?? appSettings.displayName,
                    isActive: isActive,
                    isPinned: isPinned,
                    level: snapshot?.level ?? 0,
                    settings: appSettings
                )
            }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
                if lhs.isActive != rhs.isActive { return lhs.isActive && !rhs.isActive }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    private func persistAndRebuild() throws {
        try persist()
        rebuildDisplayRows()
    }

    private func persist() throws {
        try settingsStore.save(settings)
    }
}
