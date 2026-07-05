import Combine
import Foundation

@MainActor
final class AudioControlStore: ObservableObject {
    let settingsStore: SettingsStore
    private var backend: any AudioBackend
    private let backendFactory: (BackendMode) -> any AudioBackend

    @Published var settings: PersistedSettings
    @Published private(set) var appSnapshots: [AudioAppSnapshot] = []
    @Published private(set) var devices: [AudioDeviceSnapshot] = []
    @Published private(set) var displayRows: [DisplayableAppRow] = []
    @Published private(set) var statusMessage: String = "Ready"

    init(
        settingsStore: SettingsStore = SettingsStore(),
        backend: (any AudioBackend)? = nil,
        backendFactory: @escaping (BackendMode) -> any AudioBackend = { AudioBackendFactory.makeBackend(mode: $0) }
    ) throws {
        let loadedSettings = try settingsStore.load()
        self.settingsStore = settingsStore
        self.backendFactory = backendFactory
        self.backend = backend ?? backendFactory(loadedSettings.customization.backendMode)
        self.settings = loadedSettings
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
            let tapError = synchronizeBackendTapsCapturingError()
            try persist()
            if let tapError {
                statusMessage = "Tap setup error: \(tapError.localizedDescription)"
            } else if let statusProvider = backend as? AudioBackendStatusProviding {
                statusMessage = statusProvider.statusMessage(appCount: appSnapshots.count, deviceCount: devices.count)
            } else {
                statusMessage = "Loaded \(appSnapshots.count) app\(appSnapshots.count == 1 ? "" : "s")"
            }
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
        if let tapBackend = backend as? AudioBackendTapSynchronizing {
            try tapBackend.tearDownTap(for: identity)
        }
        try synchronizeBackendTaps()
        try persistAndRebuild()
    }

    func unignore(_ identity: AudioAppIdentity) throws {
        settings.ignoredAppIDs.remove(identity)
        try synchronizeBackendTaps()
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
        let previousBackendMode = settings.customization.backendMode
        let previousRange = settings.customization.eqGainRange
        settings.customization = customization
        if previousRange != customization.eqGainRange {
            for identity in settings.appSettings.keys {
                settings.appSettings[identity]?.eq.applyRange(customization.eqGainRange)
            }
        }

        if previousBackendMode != customization.backendMode {
            try (backend as? AudioBackendTapSynchronizing)?.tearDownAllTaps()
            backend = backendFactory(customization.backendMode)
            appSnapshots = []
            devices = []
            displayRows = []
            try persist()
            try refresh()
            return
        }

        try persistAndRebuild()
    }

    func reset() throws {
        try (backend as? AudioBackendTapSynchronizing)?.tearDownAllTaps()
        settings = PersistedSettings()
        backend = backendFactory(settings.customization.backendMode)
        appSnapshots = []
        devices = []
        displayRows = []
        try persist()
        try refresh()
    }

    func shutdown() {
        try? (backend as? AudioBackendTapSynchronizing)?.tearDownAllTaps()
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

    private func synchronizeBackendTaps() throws {
        guard let tapBackend = backend as? AudioBackendTapSynchronizing else { return }
        try tapBackend.synchronizeTaps(
            activeAppIDs: Set(appSnapshots.map(\.identity)),
            ignoredAppIDs: settings.ignoredAppIDs
        )
    }

    private func synchronizeBackendTapsCapturingError() -> Error? {
        do {
            try synchronizeBackendTaps()
            return nil
        } catch {
            return error
        }
    }

    private func persist() throws {
        try settingsStore.save(settings)
    }
}
