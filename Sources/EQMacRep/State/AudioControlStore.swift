import Combine
import Foundation

@MainActor
final class AudioControlStore: ObservableObject {
    private enum ContinuousControl: Hashable {
        case volume(AudioAppIdentity)
        case eq(AudioAppIdentity)
    }
    let settingsStore: SettingsStore
    private let settingsRepository: AudioSettingsRepository
    private let session: AudioSessionCoordinator
    private let permissions: AudioPermissionCoordinator

    @Published var settings: PersistedSettings
    @Published private(set) var appSnapshots: [AudioAppSnapshot] = []
    @Published private(set) var devices: [AudioDeviceSnapshot] = []
    @Published private(set) var displayRows: [DisplayableAppRow] = []
    @Published private(set) var operationState: AudioOperationState = .idle
    @Published private(set) var issues: [AudioIssue] = []
    @Published private(set) var permissionState: AudioCapturePermissionState = .unknown
    private var activeContinuousControls: Set<ContinuousControl> = []
    private var continuousBaselines: [ContinuousControl: AppAudioSettings?] = [:]
    private var continuousTasks: [ContinuousControl: Task<Void, Never>] = [:]

    var statusMessage: String { operationState.message }

    var permissionRequirements: [PermissionRequirement] {
        permissions.requirements
    }

    init(
        settingsStore: SettingsStore = SettingsStore(),
        backend: (any AudioBackend)? = nil,
        backendFactory: @escaping (BackendMode) -> any AudioBackend = { AudioBackendFactory.makeBackend(mode: $0) },
        permissionClient: any AudioCapturePermissionClient = SystemAudioCapturePermissionClient()
    ) throws {
        let repository = AudioSettingsRepository(store: settingsStore)
        let loadedSettings = try repository.load()
        self.settingsStore = settingsStore
        self.settingsRepository = repository
        self.session = AudioSessionCoordinator(
            backend: backend ?? backendFactory(loadedSettings.customization.backendMode),
            backendFactory: backendFactory
        )
        self.permissions = AudioPermissionCoordinator(client: permissionClient)
        self.settings = loadedSettings
        self.permissionState = permissions.state
        rebuildDisplayRows()
    }

    func refresh() throws {
        operationState = .refreshing
        do {
            let snapshot = try session.fetchSnapshot()
            appSnapshots = snapshot.apps.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            devices = snapshot.devices
            for app in appSnapshots {
                ensureSettings(for: app)
            }
            mergeAppDisplayOrder()
            let tapError = synchronizeBackendTapsCapturingError()
            try persist()
            dismissIssue(id: "refresh")
            if let tapError {
                let message = "Tap setup error: \(tapError.localizedDescription)"
                operationState = .degraded(message)
                reportIssue(id: "tap-synchronization", message: message, recovery: .retry)
            } else if let message = session.statusMessage(appCount: appSnapshots.count, deviceCount: devices.count) {
                operationState = .ready(message)
                dismissIssue(id: "tap-synchronization")
            } else {
                operationState = .ready("Loaded \(appSnapshots.count) app\(appSnapshots.count == 1 ? "" : "s")")
                dismissIssue(id: "tap-synchronization")
            }
        } catch {
            let message = "Backend error: \(error.localizedDescription)"
            operationState = .failed(message)
            reportIssue(id: "refresh", message: message, severity: .error, recovery: .retry)
            throw error
        }
        rebuildDisplayRows()
        #if DEBUG
        let dump = "snapshots=\(appSnapshots.count) active=\(appSnapshots.filter(\.isActive).count) devices=\(devices.count) rows=\(displayRows.count) showInactive=\(settings.customization.showInactiveApps) ignored=\(settings.ignoredAppIDs.count) pinned=\(settings.pinnedAppIDs.count)\n"
        if let data = dump.data(using: .utf8) {
            let url = URL(fileURLWithPath: "/tmp/eqmacrep-diag.log")
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile(); handle.write(data); try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
        #endif
    }

    /// Begins observing backend update events (HAL listeners on the CoreAudio
    /// path) and refreshes after a debounce interval. Coalesces event bursts so a
    /// flurry of HAL notifications results in a single refresh.
    func startBackendObservation(debounceNanoseconds: UInt64 = 250_000_000) {
        session.startObservation(debounceNanoseconds: debounceNanoseconds) { [weak self] in
            self?.refreshIntent()
        }
    }

    func stopBackendObservation() {
        session.stopObservation()
    }

    func refreshPermissionState() {
        permissionState = permissions.refresh()
        if !permissionState.allowsProcessTaps {
            operationState = .degraded(permissionState.summary)
        }
    }

    func requestAudioCapturePermission() {
        permissionState = permissions.requestAudioCapture()
        operationState = permissionState.allowsProcessTaps ? .ready(permissionState.summary) : .degraded(permissionState.summary)
        do {
            try synchronizeBackendTaps()
        } catch {
            reportIssue(id: "permission-tap-sync", message: error.localizedDescription, recovery: .retry)
        }
        rebuildDisplayRows()
    }

    func openAudioCapturePrivacySettings() {
        permissions.openAudioPrivacySettings()
    }

    /// True once the user has answered the Screen Recording prompt but macOS still
    /// requires an app relaunch before the grant takes effect.
    var needsRelaunchForPermission: Bool {
        permissionState.screenCapture == .pendingRestart
    }

    func relaunchForPermission() {
        permissions.relaunchApp()
    }

    func refreshIntent() {
        do { try refresh() } catch { }
    }

    func setVolumeIntent(_ volume: Double, for identity: AudioAppIdentity) {
        let control = ContinuousControl.volume(identity)
        guard activeContinuousControls.contains(control) else {
            do { try setVolume(volume, for: identity) } catch { }
            return
        }
        ensureSettings(for: identity)
        settings.appSettings[identity]?.setVolume(volume)
        rebuildDisplayRows()
        scheduleContinuousApply(control)
    }

    func setMutedIntent(_ muted: Bool, for identity: AudioAppIdentity) {
        do { try setMuted(muted, for: identity) } catch { }
    }

    func setBoostIntent(_ boost: BoostLevel, for identity: AudioAppIdentity) {
        do { try setBoost(boost, for: identity) } catch { }
    }

    func setEQGainIntent(_ gain: Double, band: Int, for identity: AudioAppIdentity) {
        let control = ContinuousControl.eq(identity)
        guard activeContinuousControls.contains(control) else {
            do { try setEQGain(gain, band: band, for: identity) } catch { }
            return
        }
        ensureSettings(for: identity)
        settings.appSettings[identity]?.eq.setGain(gain, at: band)
        rebuildDisplayRows()
        scheduleContinuousApply(control)
    }

    func beginVolumeEditing(for identity: AudioAppIdentity) { beginContinuous(.volume(identity), identity: identity) }
    func endVolumeEditing(for identity: AudioAppIdentity) { endContinuous(.volume(identity)) }
    func beginEQEditing(band: Int, for identity: AudioAppIdentity) { beginContinuous(.eq(identity), identity: identity) }
    func endEQEditing(band: Int, for identity: AudioAppIdentity) { endContinuous(.eq(identity)) }

    func endContinuousEdits(for identity: AudioAppIdentity) {
        endContinuous(.volume(identity))
        endContinuous(.eq(identity))
    }

    func setRouteIntent(_ route: DeviceRoute, for identity: AudioAppIdentity) {
        do { try setRoute(route, for: identity) } catch { }
    }

    func applyCustomizationIntent(_ customization: AppCustomization) {
        do { try applyCustomization(customization) } catch { reportMutationFailure(error, id: "customization") }
    }

    func resetIntent() {
        do { try reset() } catch { reportMutationFailure(error, id: "reset") }
    }

    func completeOnboardingIntent() {
        settings.hasCompletedOnboarding = true
        do { try persistAndRebuild() }
        catch { reportMutationFailure(error, id: "onboarding") }
    }

    func resetEQIntent(for identity: AudioAppIdentity) {
        let previous = settings
        ensureSettings(for: identity)
        guard let baseline = settings.appSettings[identity] else { return }
        settings.appSettings[identity]?.eq.reset()
        guard let eq = settings.appSettings[identity]?.eq else { return }
        do {
            try applyPersistedMutation(
                .setEQ(identity, eq),
                compensatingWith: .setEQ(identity, baseline.eq),
                restoring: previous,
                issueID: "eq-\(identity.rawValue)",
                app: identity
            )
        } catch { }
    }

    func pinIntent(_ pinned: Bool, identity: AudioAppIdentity) {
        do { try pinned ? pin(identity) : unpin(identity) } catch { reportMutationFailure(error, id: "pin-\(identity.rawValue)") }
    }

    func ignoreIntent(_ identity: AudioAppIdentity) {
        do { try ignore(identity) } catch { reportMutationFailure(error, id: "ignore-\(identity.rawValue)") }
    }

    func unignoreIntent(_ identity: AudioAppIdentity) {
        do { try unignore(identity) } catch { reportMutationFailure(error, id: "unignore-\(identity.rawValue)") }
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
        try session.tearDownTap(for: identity)
        try synchronizeBackendTaps()
        try persistAndRebuild()
    }

    func unignore(_ identity: AudioAppIdentity) throws {
        settings.ignoredAppIDs.remove(identity)
        try synchronizeBackendTaps()
        try persistAndRebuild()
    }

    func setVolume(_ volume: Double, for identity: AudioAppIdentity) throws {
        let previous = settings
        ensureSettings(for: identity)
        guard let baseline = settings.appSettings[identity] else { return }
        settings.appSettings[identity]?.setVolume(volume)
        let applied = settings.appSettings[identity]?.volume ?? 1
        try applyPersistedMutation(
            .setVolume(identity, applied),
            compensatingWith: .setVolume(identity, baseline.volume),
            restoring: previous,
            issueID: "volume-\(identity.rawValue)",
            app: identity
        )
    }

    func setMuted(_ muted: Bool, for identity: AudioAppIdentity) throws {
        let previous = settings
        ensureSettings(for: identity)
        guard let baseline = settings.appSettings[identity] else { return }
        settings.appSettings[identity]?.isMuted = muted
        try applyPersistedMutation(
            .setMuted(identity, muted),
            compensatingWith: .setMuted(identity, baseline.isMuted),
            restoring: previous,
            issueID: "mute-\(identity.rawValue)",
            app: identity
        )
    }

    func setBoost(_ boost: BoostLevel, for identity: AudioAppIdentity) throws {
        let previous = settings
        ensureSettings(for: identity)
        guard let baseline = settings.appSettings[identity] else { return }
        settings.appSettings[identity]?.boost = boost
        try applyPersistedMutation(
            .setBoost(identity, boost),
            compensatingWith: .setBoost(identity, baseline.boost),
            restoring: previous,
            issueID: "boost-\(identity.rawValue)",
            app: identity
        )
    }

    func setEQGain(_ gain: Double, band: Int, for identity: AudioAppIdentity) throws {
        let previous = settings
        ensureSettings(for: identity)
        guard let baseline = settings.appSettings[identity] else { return }
        settings.appSettings[identity]?.eq.setGain(gain, at: band)
        guard let eq = settings.appSettings[identity]?.eq else { return }
        try applyPersistedMutation(
            .setEQ(identity, eq),
            compensatingWith: .setEQ(identity, baseline.eq),
            restoring: previous,
            issueID: "eq-\(identity.rawValue)",
            app: identity
        )
    }

    func setRoute(_ route: DeviceRoute, for identity: AudioAppIdentity) throws {
        let previous = settings
        ensureSettings(for: identity)
        guard let baseline = settings.appSettings[identity] else { return }
        settings.appSettings[identity]?.route = route
        try applyPersistedMutation(
            .setRoute(identity, route),
            compensatingWith: .setRoute(identity, baseline.route),
            restoring: previous,
            issueID: "route-\(identity.rawValue)",
            app: identity
        )
    }

    /// Moves `identity` directly before `target` in the persisted display order.
    func moveApp(_ identity: AudioAppIdentity, before target: AudioAppIdentity) throws {
        var order = settings.appDisplayOrder
        if !order.contains(identity) { order.append(identity) }
        if !order.contains(target) { order.append(target) }
        order.removeAll { $0 == identity }
        if let targetIndex = order.firstIndex(of: target) {
            order.insert(identity, at: targetIndex)
        } else {
            order.append(identity)
        }
        settings.appDisplayOrder = order
        try persistAndRebuild()
    }

    /// Appends any newly-discovered or pinned apps to the end of the display
    /// order, preserving the user's existing arrangement.
    private func mergeAppDisplayOrder() {
        var order = settings.appDisplayOrder
        let known = Set(order)
        var candidates = appSnapshots.map(\.identity)
        for pinned in settings.pinnedAppIDs where !candidates.contains(pinned) {
            candidates.append(pinned)
        }
        for id in candidates where !known.contains(id) {
            order.append(id)
        }
        settings.appDisplayOrder = order
    }

    func applyCustomization(_ customization: AppCustomization) throws {
        let previousSettings = settings
        let previousBackendMode = settings.customization.backendMode
        let previousRange = settings.customization.eqGainRange
        settings.customization = customization
        if previousRange != customization.eqGainRange {
            for identity in settings.appSettings.keys {
                settings.appSettings[identity]?.eq.applyRange(customization.eqGainRange)
            }
        }

        if previousBackendMode != customization.backendMode {
            let wasObserving = session.isObserving
            stopBackendObservation()
            defer { if wasObserving { startBackendObservation() } }
            do {
                try session.switchBackend(to: customization.backendMode)
            } catch {
                settings = previousSettings
                rebuildDisplayRows()
                throw error
            }
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
        let wasObserving = session.isObserving
        stopBackendObservation()
        defer { if wasObserving { startBackendObservation() } }
        let defaultSettings = PersistedSettings()
        try session.switchBackend(to: defaultSettings.customization.backendMode)
        settings = defaultSettings
        appSnapshots = []
        devices = []
        displayRows = []
        try persist()
        try refresh()
    }

    func shutdown() {
        for control in Array(activeContinuousControls) { endContinuous(control) }
        stopBackendObservation()
        try? settingsRepository.flush()
        try? session.shutdown()
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
        let orderIndex = Dictionary(uniqueKeysWithValues: settings.appDisplayOrder.enumerated().map { ($1, $0) })
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
                // Persisted display order wins; identities not yet ordered fall
                // back to pinned-first, active-first, then name.
                let lhsOrder = orderIndex[lhs.identity] ?? Int.max
                let rhsOrder = orderIndex[rhs.identity] ?? Int.max
                if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
                if lhs.isActive != rhs.isActive { return lhs.isActive && !rhs.isActive }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    private func persistAndRebuild() throws {
        try persist()
        rebuildDisplayRows()
    }

    /// Applies a backend command and persists its matching UI state as one
    /// logical transaction. If saving fails after the backend accepted the
    /// command, restore the previous backend value before rolling UI state back.
    private func applyPersistedMutation(
        _ command: AudioBackendCommand,
        compensatingWith compensation: AudioBackendCommand,
        restoring previousSettings: PersistedSettings,
        issueID: String,
        app: AudioAppIdentity
    ) throws {
        do {
            try session.apply(command)
        } catch {
            settings = previousSettings
            rebuildDisplayRows()
            reportMutationFailure(error, id: issueID, app: app)
            throw error
        }

        do {
            try persistAndRebuild()
        } catch {
            let persistenceError = error
            do {
                try session.apply(compensation)
            } catch {
                // The new value is still the best representation of backend
                // state. Keep it visible and queue another persistence attempt.
                settingsRepository.scheduleSave(settings)
                rebuildDisplayRows()
                let message = "Couldn’t save settings or restore the previous audio value: \(persistenceError.localizedDescription) Restore error: \(error.localizedDescription)"
                operationState = .degraded(message)
                reportIssue(id: issueID, message: message, severity: .error, app: app, recovery: .retry)
                throw persistenceError
            }

            settings = previousSettings
            rebuildDisplayRows()
            reportMutationFailure(persistenceError, id: issueID, app: app)
            throw persistenceError
        }
    }

    private func synchronizeBackendTaps() throws {
        try session.synchronizeTaps(
            activeAppIDs: Set(appSnapshots.map(\.identity)),
            ignoredAppIDs: settings.ignoredAppIDs,
            permissionAllowsTaps: permissionState.allowsProcessTaps
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
        try settingsRepository.saveNow(settings)
    }

    private func beginContinuous(_ control: ContinuousControl, identity: AudioAppIdentity) {
        guard activeContinuousControls.insert(control).inserted else { return }
        continuousBaselines[control] = settings.appSettings[identity]
    }

    private func scheduleContinuousApply(_ control: ContinuousControl, debounceNanoseconds: UInt64 = 100_000_000) {
        continuousTasks[control]?.cancel()
        continuousTasks[control] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled else { return }
            self?.flushContinuous(control, isFinal: false)
        }
    }

    private func endContinuous(_ control: ContinuousControl) {
        guard activeContinuousControls.contains(control) || continuousTasks[control] != nil else { return }
        continuousTasks[control]?.cancel()
        continuousTasks[control] = nil
        flushContinuous(control, isFinal: true)
    }

    private func flushContinuous(_ control: ContinuousControl, isFinal: Bool) {
        let identity: AudioAppIdentity
        let command: AudioBackendCommand
        switch control {
        case let .volume(appID):
            identity = appID
            guard let volume = settings.appSettings[appID]?.volume else { return }
            command = .setVolume(appID, volume)
        case let .eq(appID):
            identity = appID
            guard let eq = settings.appSettings[appID]?.eq else { return }
            command = .setEQ(appID, eq)
        }

        do {
            try session.apply(command)
        } catch {
            let baseline = continuousBaselines[control] ?? nil
            if let baseline {
                settings.appSettings[identity] = baseline
                let compensation: AudioBackendCommand = switch control {
                case .volume: .setVolume(identity, baseline.volume)
                case .eq: .setEQ(identity, baseline.eq)
                }
                try? session.apply(compensation)
            } else {
                settings.appSettings.removeValue(forKey: identity)
            }
            do { try settingsRepository.saveNow(settings) }
            catch { settingsRepository.scheduleSave(settings) }
            activeContinuousControls.remove(control)
            continuousBaselines[control] = nil
            continuousTasks[control]?.cancel()
            continuousTasks[control] = nil
            rebuildDisplayRows()
            reportMutationFailure(error, id: "continuous-\(identity.rawValue)", app: identity)
            return
        }

        if isFinal {
            activeContinuousControls.remove(control)
            continuousBaselines[control] = nil
            continuousTasks[control] = nil
            do {
                try settingsRepository.saveNow(settings)
            } catch {
                // Audio already accepted the final value. Keep UI state aligned
                // with audio and retain a pending copy for shutdown/retry.
                settingsRepository.scheduleSave(settings)
                let message = "Couldn’t save settings: \(error.localizedDescription)"
                operationState = .degraded(message)
                reportIssue(id: "persistence", message: message, severity: .error, recovery: .retry)
            }
        } else {
            settingsRepository.scheduleSave(settings)
        }
    }

    private func reportMutationFailure(_ error: Error, id: String, app: AudioAppIdentity? = nil) {
        let message = "Couldn’t apply change: \(error.localizedDescription)"
        operationState = .degraded(message)
        reportIssue(id: id, message: message, severity: .error, app: app, recovery: .retry)
    }

    private func reportIssue(
        id: String,
        message: String,
        severity: AudioIssueSeverity = .warning,
        app: AudioAppIdentity? = nil,
        recovery: AudioRecoveryAction? = nil
    ) {
        issues.removeAll { $0.id == id }
        issues.append(AudioIssue(id: id, severity: severity, affectedApp: app, affectedDeviceID: nil, message: message, recovery: recovery))
    }

    func dismissIssue(id: String) {
        issues.removeAll { $0.id == id }
    }
}
