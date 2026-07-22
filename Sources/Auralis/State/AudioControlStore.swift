import Combine
import Foundation

private enum AudioControlStoreError: LocalizedError {
    case appUnavailable(String)
    case outputVolumeUnsupported(String)
    case outputMuteUnsupported(String)
    case shuttingDown

    var errorDescription: String? {
        switch self {
        case let .appUnavailable(identity): "The audio app \(identity) is unavailable."
        case let .outputVolumeUnsupported(device): "\(device) does not expose a settable output volume."
        case let .outputMuteUnsupported(device): "\(device) does not expose a settable mute control."
        case .shuttingDown: "The audio engine is shutting down."
        }
    }
}

private enum SettingsEngineReceipt: Sendable {
    case none
    case backendSwitch(AudioBackendSwitchToken)
}

@MainActor
final class AudioControlStore: ObservableObject {
    let settingsStore: SettingsStore
    private let persistence: SettingsPersistenceActor
    private let engine: AudioEngineActor
    private let permissions: AudioPermissionCoordinator
    private let mutationGate = AudioMutationGate()

    @Published var settings: PersistedSettings
    @Published private(set) var appSnapshots: [AudioAppSnapshot] = []
    @Published private(set) var devices: [AudioDeviceSnapshot] = []
    @Published private(set) var displayRows: [DisplayableAppRow] = []
    @Published private(set) var operationState: AudioOperationState = .idle
    @Published private(set) var issues: [AudioIssue] = []
    @Published private(set) var permissionState: AudioCapturePermissionState = .unknown
    @Published private(set) var outputVolumeState: OutputVolumeState = .init()
    @Published private(set) var deviceVolumeStates: [String: OutputVolumeState] = [:]

    /// Live meter levels live on their own object so the ~10 Hz stream does not
    /// invalidate views bound to this store. See [[AppLevelStore]].
    let appLevels = AppLevelStore()

    private var bootstrapTask: Task<Void, Never>?
    private var topologyObservationTask: Task<Void, Never>?
    private var outputObservationTask: Task<Void, Never>?
    private var levelObservationTask: Task<Void, Never>?
    private var intentTasks: [UUID: Task<Void, Never>] = [:]
    private var editSessions: [AudioEditSessionKey: PersistedSettings] = [:]
    private var activeEditKeys: [EditLookup: AudioEditSessionKey] = [:]
    private var editTasks: [AudioEditSessionKey: Task<Void, Never>] = [:]
    private var shutdownTask: Task<AudioShutdownReport, Never>?
    private var completedShutdownReport: AudioShutdownReport?
    private(set) var topologyRefreshCount = 0

    private struct EditLookup: Hashable {
        let app: AudioAppIdentity
        let control: AudioEditControl
    }

    var statusMessage: String { operationState.message }

    var permissionRequirements: [PermissionRequirement] {
        permissions.requirements
    }

    var activeEditSessionKeys: Set<AudioEditSessionKey> {
        Set(editSessions.keys)
    }

    init(
        settingsStore: SettingsStore = SettingsStore(),
        backend: sending (any AudioBackend)? = nil,
        backendFactory: @escaping @Sendable (BackendMode) -> any AudioBackend = { AudioBackendFactory.makeBackend(mode: $0) },
        permissionClient: any AudioCapturePermissionClient = SystemAudioCapturePermissionClient()
    ) throws {
        let defaults = settingsStore.defaultSettings()
        self.settingsStore = settingsStore
        self.persistence = SettingsPersistenceActor(store: settingsStore)
        self.engine = AudioEngineActor(
            backend: backend,
            initialMode: defaults.customization.backendMode,
            backendFactory: backendFactory
        )
        self.permissions = AudioPermissionCoordinator(client: permissionClient)
        self.settings = defaults
        self.permissionState = permissions.state
        rebuildDisplayRows()
        bootstrapTask = Task { [weak self] in
            await self?.performBootstrap()
        }
    }

    func waitUntilReady() async {
        let task = bootstrapTask
        await task?.value
    }

    func waitForPendingPersistence() async {
        await persistence.waitForScheduledWork()
    }

    private func performBootstrap() async {
        defer { bootstrapTask = nil }
        InternalDiagnostics.record("persistence", "bootstrap.begin")
        do {
            let result = try await persistence.loadWithRecovery()
            settings = result.settings
            await engine.selectInitialMode(result.settings.customization.backendMode)
            if let notice = result.recoveryNotice {
                reportIssue(
                    id: "settings-recovery",
                    domain: .persistence,
                    message: notice.message,
                    severity: .warning
                )
                operationState = .degraded(notice.message)
            }
            InternalDiagnostics.record(
                "persistence",
                "bootstrap.complete recovered=\(result.recoveryNotice != nil) apps=\(result.settings.appSettings.count)"
            )
        } catch let error as SettingsStoreError {
            if case .futureVersion = error {
                await persistence.blockWrites(because: error)
                settings = settingsStore.defaultSettings()
                let message = "This app cannot read the newer settings file at \(settingsStore.settingsURL.path). It was left unchanged; update Auralis before saving settings."
                reportIssue(id: "settings-version", domain: .persistence, message: message, severity: .error)
                operationState = .degraded(message)
            } else {
                reportPersistenceFailure(error, id: "settings-load")
            }
        } catch {
            reportPersistenceFailure(error, id: "settings-load")
        }
        rebuildDisplayRows()
    }

    // MARK: - Engine refresh and observation

    func refresh() async throws {
        await waitUntilReady()
        try await withMutationGate {
            try await refreshUnlocked()
        }
    }

    private func refreshUnlocked() async throws {
        guard completedShutdownReport == nil else { throw AudioControlStoreError.shuttingDown }
        InternalDiagnostics.record(
            "audio",
            "refresh.begin permissionAllowsTaps=\(permissionState.allowsProcessTaps)"
        )
        operationState = .refreshing
        let engineSnapshot: AudioEngineSnapshot
        do {
            engineSnapshot = try await engine.fetchSnapshot(
                settings: settings,
                permissionAllowsTaps: permissionState.allowsProcessTaps
            )
        } catch {
            let message = "Backend error: \(error.localizedDescription)"
            operationState = .failed(message)
            reportIssue(id: "refresh", domain: .backend, message: message, severity: .error, recovery: .retry)
            throw error
        }

        appSnapshots = Self.deduplicatedSnapshots(engineSnapshot.backend.apps)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        devices = engineSnapshot.backend.devices
        outputVolumeState = engineSnapshot.output.defaultOutput
        deviceVolumeStates = engineSnapshot.output.devices
        let beforeDiscoveryMerge = settings
        for app in appSnapshots { ensureSettings(for: app, in: &settings) }
        mergeAppDisplayOrder()

        var persistenceIssue: String?
        if settings != beforeDiscoveryMerge {
            do {
                _ = try await persistence.commit(settings)
                dismissIssue(id: "refresh-persistence")
            } catch {
                persistenceIssue = error.localizedDescription
                reportPersistenceFailure(error, id: "refresh-persistence")
            }
        }
        dismissIssue(id: "refresh")

        if let restoreIssue = engineSnapshot.restoreIssue {
            reportIssue(
                id: "backend-restore",
                domain: .backend,
                message: "Audio settings restore error: \(restoreIssue)",
                recovery: .retry
            )
        } else {
            dismissIssue(id: "backend-restore")
        }
        if let tapIssue = engineSnapshot.tapIssue {
            reportIssue(
                id: "tap-synchronization",
                domain: .tap,
                message: "Tap setup error: \(tapIssue)",
                recovery: .retry
            )
        } else {
            dismissIssue(id: "tap-synchronization")
        }

        if let persistenceIssue {
            operationState = .degraded("Couldn’t save discovered audio state: \(persistenceIssue)")
        } else if let tapIssue = engineSnapshot.tapIssue {
            operationState = .degraded("Tap setup error: \(tapIssue)")
        } else if let restoreIssue = engineSnapshot.restoreIssue {
            operationState = .degraded("Audio settings restore error: \(restoreIssue)")
        } else {
            operationState = .ready(engineSnapshot.statusMessage)
        }
        rebuildDisplayRows()
        InternalDiagnostics.record(
            "audio",
            "refresh.complete apps=\(appSnapshots.count) devices=\(devices.count) "
                + "active=\(appSnapshots.filter(\.isActive).count) "
                + "tapIssue=\(engineSnapshot.tapIssue ?? "none") "
                + "restoreIssue=\(engineSnapshot.restoreIssue ?? "none")"
        )
    }

    func startBackendObservation(
        debounceNanoseconds: UInt64 = 250_000_000,
        meterIntervalNanoseconds: UInt64 = 100_000_000
    ) async {
        await waitUntilReady()
        guard topologyObservationTask == nil,
              outputObservationTask == nil,
              levelObservationTask == nil else { return }

        let topologyEvents = engine.topologyEvents
        topologyObservationTask = Task { [weak self] in
            for await _ in topologyEvents {
                guard !Task.isCancelled, let self else { return }
                topologyRefreshCount += 1
                try? await refresh()
            }
        }
        let outputEvents = engine.outputEvents
        outputObservationTask = Task { [weak self] in
            for await output in outputEvents {
                guard !Task.isCancelled, let self else { return }
                outputVolumeState = output.defaultOutput
                deviceVolumeStates = output.devices
            }
        }
        let levelEvents = engine.levelEvents
        levelObservationTask = Task { [weak self] in
            for await levels in levelEvents {
                guard !Task.isCancelled, let self else { return }
                applyAppLevels(levels)
            }
        }
        await engine.startObservation(
            debounceNanoseconds: debounceNanoseconds,
            meterIntervalNanoseconds: meterIntervalNanoseconds
        )
    }

    func stopBackendObservation() async {
        cancelObservationConsumers()
        await engine.stopObservation()
    }

    private func cancelObservationConsumers() {
        topologyObservationTask?.cancel()
        topologyObservationTask = nil
        outputObservationTask?.cancel()
        outputObservationTask = nil
        levelObservationTask?.cancel()
        levelObservationTask = nil
    }

    private func applyAppLevels(_ levels: [AudioAppIdentity: Double]) {
        // Publish only to the dedicated level store. Writing meter values into
        // `appSnapshots`/`displayRows` would fire this store's objectWillChange
        // ~10x/sec and force a full-window SwiftUI relayout every tick.
        var clamped: [AudioAppIdentity: Double] = [:]
        clamped.reserveCapacity(levels.count)
        for snapshot in appSnapshots {
            clamped[snapshot.identity] = min(max(levels[snapshot.identity] ?? 0, 0), 1)
        }
        appLevels.apply(clamped)
    }

    // MARK: - Permission lifecycle

    func refreshPermissionState() {
        permissionState = permissions.refresh()
        InternalDiagnostics.record(
            "permission",
            "audioCapture state=\(String(describing: permissionState)) allowsTaps=\(permissionState.allowsProcessTaps)"
        )
        if !permissionState.allowsProcessTaps {
            operationState = .degraded(permissionState.summary)
            reportIssue(
                id: "audio-permission",
                domain: .permission,
                message: permissionState.summary,
                recovery: .requestAudioPermission
            )
        } else {
            dismissIssue(id: "audio-permission")
        }
    }

    func requestAudioCapturePermission() {
        permissionState = permissions.requestAudioCapture()
        operationState = permissionState.allowsProcessTaps
            ? .ready(permissionState.summary)
            : .degraded(permissionState.summary)
        launchIntent { store in
            do {
                try await store.withMutationGate {
                    try await store.engine.synchronizeTaps(
                        activeAppIDs: Set(store.appSnapshots.map(\.identity)),
                        ignoredAppIDs: store.settings.ignoredAppIDs,
                        permissionAllowsTaps: store.permissionState.allowsProcessTaps
                    )
                }
                store.dismissIssue(id: "permission-tap-sync")
            } catch {
                store.reportIssue(
                    id: "permission-tap-sync",
                    domain: .tap,
                    message: error.localizedDescription,
                    recovery: .retry
                )
            }
        }
        rebuildDisplayRows()
    }

    func openAudioCapturePrivacySettings() { permissions.openAudioPrivacySettings() }
    var needsRelaunchForPermission: Bool { permissionState.screenCapture == .pendingRestart }
    func relaunchForPermission() {
        launchIntent { store in
            do {
                try await store.permissions.relaunchApp()
                store.dismissIssue(id: "permission-relaunch")
            } catch {
                store.reportIssue(
                    id: "permission-relaunch",
                    domain: .permission,
                    message: "Couldn’t relaunch Auralis: \(error.localizedDescription)",
                    severity: .error,
                    recovery: .retry
                )
            }
        }
    }

    // MARK: - Intent entry points

    func refreshIntent() {
        launchIntent { store in try? await store.refresh() }
    }

    func setOutputVolumeIntent(_ volume: Double) {
        launchIntent { store in try? await store.setOutputVolume(volume) }
    }

    func setOutputMutedIntent(_ muted: Bool) {
        launchIntent { store in try? await store.setOutputMuted(muted) }
    }

    func toggleOutputMuteIntent() { setOutputMutedIntent(!outputVolumeState.isMuted) }

    func setDeviceVolumeIntent(_ volume: Double, for deviceUID: String) {
        launchIntent { store in try? await store.setDeviceVolume(volume, for: deviceUID) }
    }

    func setDeviceMutedIntent(_ muted: Bool, for deviceUID: String) {
        launchIntent { store in try? await store.setDeviceMuted(muted, for: deviceUID) }
    }

    func toggleDeviceMuteIntent(for deviceUID: String) {
        setDeviceMutedIntent(!(deviceVolumeStates[deviceUID]?.isMuted ?? false), for: deviceUID)
    }

    func setVolumeIntent(_ volume: Double, for identity: AudioAppIdentity) {
        let lookup = EditLookup(app: identity, control: .volume)
        if let key = activeEditKeys[lookup] {
            ensureSettings(for: identity, in: &settings)
            settings.appSettings[identity]?.setVolume(volume)
            rebuildDisplayRows()
            scheduleEditPreview(key)
        } else {
            launchIntent { store in try? await store.setVolume(volume, for: identity) }
        }
    }

    func setMutedIntent(_ muted: Bool, for identity: AudioAppIdentity) {
        launchIntent { store in try? await store.setMuted(muted, for: identity) }
    }

    func setBoostIntent(_ boost: BoostLevel, for identity: AudioAppIdentity) {
        launchIntent { store in try? await store.setBoost(boost, for: identity) }
    }

    func setEQGainIntent(_ gain: Double, band: Int, for identity: AudioAppIdentity) {
        let lookup = EditLookup(app: identity, control: .eqBand(band))
        if let key = activeEditKeys[lookup] {
            ensureSettings(for: identity, in: &settings)
            settings.appSettings[identity]?.eq.setGain(gain, at: band)
            rebuildDisplayRows()
            scheduleEditPreview(key)
        } else {
            launchIntent { store in try? await store.setEQGain(gain, band: band, for: identity) }
        }
    }

    @discardableResult
    func beginVolumeEditing(for identity: AudioAppIdentity) -> UUID {
        beginEdit(app: identity, control: .volume)
    }

    func endVolumeEditing(for identity: AudioAppIdentity) {
        endEdit(app: identity, control: .volume)
    }

    @discardableResult
    func beginEQEditing(band: Int, for identity: AudioAppIdentity) -> UUID {
        beginEdit(app: identity, control: .eqBand(band))
    }

    func endEQEditing(band: Int, for identity: AudioAppIdentity) {
        endEdit(app: identity, control: .eqBand(band))
    }

    func endContinuousEdits(for identity: AudioAppIdentity) {
        let lookups = activeEditKeys.keys.filter { $0.app == identity }
        for lookup in lookups { endEdit(app: lookup.app, control: lookup.control) }
    }

    func applyCustomizationIntent(_ customization: AppCustomization) {
        launchIntent { store in try? await store.applyCustomization(customization) }
    }

    func resetIntent() {
        launchIntent { store in try? await store.reset() }
    }

    func resetEQIntent(for identity: AudioAppIdentity) {
        launchIntent { store in try? await store.resetEQ(for: identity) }
    }

    func pinIntent(_ pinned: Bool, identity: AudioAppIdentity) {
        launchIntent { store in
            do {
                if pinned { try await store.pin(identity) }
                else { try await store.unpin(identity) }
            }
            catch { }
        }
    }

    func ignoreIntent(_ identity: AudioAppIdentity) {
        launchIntent { store in try? await store.ignore(identity) }
    }

    func unignoreIntent(_ identity: AudioAppIdentity) {
        launchIntent { store in try? await store.unignore(identity) }
    }

    func restoreAllIgnoredIntent() {
        launchIntent { store in try? await store.restoreAllIgnoredApps() }
    }

    // MARK: - Output mutations

    func setOutputVolume(_ volume: Double) async throws {
        await waitUntilReady()
        try await withMutationGate {
            guard outputVolumeState.capabilities.canSetVolume else {
                throw AudioControlStoreError.outputVolumeUnsupported(outputVolumeState.deviceName ?? "The default output")
            }
            let clamped = min(max(volume.isFinite ? volume : outputVolumeState.volume, 0), 1)
            do {
                try await engine.setOutputVolume(clamped)
                outputVolumeState.volume = clamped
                dismissIssue(id: "output-volume")
                InternalDiagnostics.record("audio", "output.volume applied=\(clamped)")
            } catch {
                reportMutationFailure(error, id: "output-volume", domain: .backend)
                throw error
            }
        }
    }

    func setOutputMuted(_ muted: Bool) async throws {
        await waitUntilReady()
        try await withMutationGate {
            guard outputVolumeState.capabilities.canSetMute else {
                throw AudioControlStoreError.outputMuteUnsupported(outputVolumeState.deviceName ?? "The default output")
            }
            do {
                try await engine.setOutputMuted(muted)
                outputVolumeState.isMuted = muted
                dismissIssue(id: "output-mute")
                InternalDiagnostics.record("audio", "output.mute applied=\(muted)")
            } catch {
                reportMutationFailure(error, id: "output-mute", domain: .backend)
                throw error
            }
        }
    }

    func setDeviceVolume(_ volume: Double, for deviceUID: String) async throws {
        await waitUntilReady()
        try await withMutationGate {
            let state = deviceVolumeStates[deviceUID] ?? OutputVolumeState()
            guard state.capabilities.canSetVolume else {
                throw AudioControlStoreError.outputVolumeUnsupported(state.deviceName ?? deviceUID)
            }
            let clamped = min(max(volume.isFinite ? volume : state.volume, 0), 1)
            do {
                try await engine.setOutputVolume(clamped, forUID: deviceUID)
                deviceVolumeStates[deviceUID]?.volume = clamped
                dismissIssue(id: "device-volume-\(deviceUID)")
                InternalDiagnostics.record(
                    "audio",
                    "device.volume id=\(deviceUID) applied=\(clamped)"
                )
            } catch {
                reportMutationFailure(error, id: "device-volume-\(deviceUID)", domain: .backend, device: deviceUID)
                throw error
            }
        }
    }

    func setDeviceMuted(_ muted: Bool, for deviceUID: String) async throws {
        await waitUntilReady()
        try await withMutationGate {
            let state = deviceVolumeStates[deviceUID] ?? OutputVolumeState()
            guard state.capabilities.canSetMute else {
                throw AudioControlStoreError.outputMuteUnsupported(state.deviceName ?? deviceUID)
            }
            do {
                try await engine.setOutputMuted(muted, forUID: deviceUID)
                deviceVolumeStates[deviceUID]?.isMuted = muted
                dismissIssue(id: "device-mute-\(deviceUID)")
                InternalDiagnostics.record(
                    "audio",
                    "device.mute id=\(deviceUID) applied=\(muted)"
                )
            } catch {
                reportMutationFailure(error, id: "device-mute-\(deviceUID)", domain: .backend, device: deviceUID)
                throw error
            }
        }
    }

    // MARK: - Durable settings transactions

    func pin(_ identity: AudioAppIdentity) async throws {
        try await updatePin(identity, pinned: true)
    }

    func unpin(_ identity: AudioAppIdentity) async throws {
        try await updatePin(identity, pinned: false)
    }

    private func updatePin(_ identity: AudioAppIdentity, pinned: Bool) async throws {
        await waitUntilReady()
        try await withMutationGate {
            let previous = settings
            var desired = previous
            if pinned { desired.pinnedAppIDs.insert(identity) }
            else { desired.pinnedAppIDs.remove(identity) }
            try await performSettingsTransaction(
                desired: desired,
                issueID: "pin-\(identity.rawValue)",
                engineDomain: .backend,
                app: identity,
                engineWork: { () },
                finalize: { _ in },
                compensate: { _ in }
            )
        }
    }

    func ignore(_ identity: AudioAppIdentity) async throws {
        await waitUntilReady()
        try await withMutationGate {
            let previous = settings
            var desired = previous
            desired.ignoredAppIDs.insert(identity)
            desired.pinnedAppIDs.remove(identity)
            let active = Set(appSnapshots.map(\.identity))
            let allowsTaps = permissionState.allowsProcessTaps
            try await performSettingsTransaction(
                desired: desired,
                issueID: "ignore-\(identity.rawValue)",
                engineDomain: .tap,
                app: identity,
                engineWork: { [engine] in
                    try await engine.tearDownTap(for: identity)
                    try await engine.synchronizeTaps(
                        activeAppIDs: active,
                        ignoredAppIDs: desired.ignoredAppIDs,
                        permissionAllowsTaps: allowsTaps
                    )
                },
                finalize: { _ in },
                compensate: { [engine] _ in
                    try await engine.synchronizeTaps(
                        activeAppIDs: active,
                        ignoredAppIDs: previous.ignoredAppIDs,
                        permissionAllowsTaps: allowsTaps
                    )
                }
            )
        }
    }

    func unignore(_ identity: AudioAppIdentity) async throws {
        await waitUntilReady()
        try await withMutationGate {
            let previous = settings
            var desired = previous
            desired.ignoredAppIDs.remove(identity)
            try await performIgnoredSetTransaction(previous: previous, desired: desired, issueID: "unignore-\(identity.rawValue)", app: identity)
        }
    }

    func restoreAllIgnoredApps() async throws {
        await waitUntilReady()
        try await withMutationGate {
            let previous = settings
            var desired = previous
            desired.ignoredAppIDs.removeAll()
            try await performIgnoredSetTransaction(previous: previous, desired: desired, issueID: "restore-all-ignored", app: nil)
        }
    }

    private func performIgnoredSetTransaction(
        previous: PersistedSettings,
        desired: PersistedSettings,
        issueID: String,
        app: AudioAppIdentity?
    ) async throws {
        let active = Set(appSnapshots.map(\.identity))
        let allowsTaps = permissionState.allowsProcessTaps
        try await performSettingsTransaction(
            desired: desired,
            issueID: issueID,
            engineDomain: .tap,
            app: app,
            engineWork: { [engine] in
                try await engine.synchronizeTaps(
                    activeAppIDs: active,
                    ignoredAppIDs: desired.ignoredAppIDs,
                    permissionAllowsTaps: allowsTaps
                )
            },
            finalize: { _ in },
            compensate: { [engine] _ in
                try await engine.synchronizeTaps(
                    activeAppIDs: active,
                    ignoredAppIDs: previous.ignoredAppIDs,
                    permissionAllowsTaps: allowsTaps
                )
            }
        )
    }

    func setVolume(_ volume: Double, for identity: AudioAppIdentity) async throws {
        try await mutateAppSetting(identity, issuePrefix: "volume") { $0.setVolume(volume) }
    }

    func setMuted(_ muted: Bool, for identity: AudioAppIdentity) async throws {
        try await mutateAppSetting(identity, issuePrefix: "mute") { $0.isMuted = muted }
    }

    func setBoost(_ boost: BoostLevel, for identity: AudioAppIdentity) async throws {
        try await mutateAppSetting(identity, issuePrefix: "boost") { $0.boost = boost }
    }

    func setEQGain(_ gain: Double, band: Int, for identity: AudioAppIdentity) async throws {
        try await mutateAppSetting(identity, issuePrefix: "eq") { $0.eq.setGain(gain, at: band) }
    }

    func resetEQ(for identity: AudioAppIdentity) async throws {
        try await mutateAppSetting(identity, issuePrefix: "eq") { $0.eq.reset() }
    }

    func setRoute(_ route: DeviceRoute, for identity: AudioAppIdentity) async throws {
        try await mutateAppSetting(identity, issuePrefix: "route") { $0.route = route.normalized }
    }

    private func mutateAppSetting(
        _ identity: AudioAppIdentity,
        issuePrefix: String,
        mutation: (inout AppAudioSettings) -> Void
    ) async throws {
        await waitUntilReady()
        try await withMutationGate {
            let previous = settings
            var desired = previous
            ensureSettings(for: identity, in: &desired)
            guard var desiredApp = desired.appSettings[identity],
                  let previousApp = desired.appSettings[identity] else {
                throw AudioControlStoreError.appUnavailable(identity.rawValue)
            }
            mutation(&desiredApp)
            desired.appSettings[identity] = desiredApp.normalized
            let command = Self.backendCommand(for: identity, settings: desiredApp, issuePrefix: issuePrefix)
            let compensation = Self.backendCommand(for: identity, settings: previous.appSettings[identity] ?? previousApp, issuePrefix: issuePrefix)
            try await performSettingsTransaction(
                desired: desired,
                issueID: "\(issuePrefix)-\(identity.rawValue)",
                engineDomain: issuePrefix == "route" ? .tap : .backend,
                app: identity,
                engineWork: { [engine] in try await engine.apply(command) },
                finalize: { _ in },
                compensate: { [engine] _ in try await engine.apply(compensation) }
            )
        }
    }

    func moveApp(_ identity: AudioAppIdentity, before target: AudioAppIdentity) async throws {
        await waitUntilReady()
        try await withMutationGate {
            var desired = settings
            var order = desired.appDisplayOrder
            if !order.contains(identity) { order.append(identity) }
            if !order.contains(target) { order.append(target) }
            order.removeAll { $0 == identity }
            if let index = order.firstIndex(of: target) { order.insert(identity, at: index) }
            else { order.append(identity) }
            desired.appDisplayOrder = order
            try await performSettingsTransaction(
                desired: desired,
                issueID: "app-order",
                engineDomain: .backend,
                app: identity,
                engineWork: { () },
                finalize: { _ in },
                compensate: { _ in }
            )
        }
    }

    func applyCustomization(_ customization: AppCustomization) async throws {
        await waitUntilReady()
        try await withMutationGate {
            let previous = settings
            var desired = previous
            let normalized = customization.normalized
            let backendChanged = previous.customization.backendMode != normalized.backendMode
            let rangeChanged = previous.customization.eqGainRange != normalized.eqGainRange
            desired.customization = normalized
            if rangeChanged {
                for identity in desired.appSettings.keys {
                    desired.appSettings[identity]?.eq.applyRange(normalized.eqGainRange)
                }
            }
            let desiredEQ = rangeChanged
                ? desired.appSettings.compactMap { identity, value in AudioBackendCommand.setEQ(identity, value.eq) }
                : []
            let previousEQ = rangeChanged
                ? previous.appSettings.compactMap { identity, value in AudioBackendCommand.setEQ(identity, value.eq) }
                : []

            try await performSettingsTransaction(
                desired: desired,
                issueID: "customization",
                engineDomain: backendChanged ? .backend : .tap,
                app: nil,
                engineWork: { [engine] () async throws -> SettingsEngineReceipt in
                    if backendChanged {
                        return SettingsEngineReceipt.backendSwitch(
                            try await engine.beginBackendSwitch(to: normalized.backendMode)
                        )
                    }
                    if !desiredEQ.isEmpty { try await engine.apply(desiredEQ) }
                    return SettingsEngineReceipt.none
                },
                finalize: { [engine] (receipt: SettingsEngineReceipt) in
                    if case let .backendSwitch(token) = receipt {
                        try await engine.commitBackendSwitch(token)
                    }
                },
                compensate: { [engine] (receipt: SettingsEngineReceipt?) in
                    if case let .backendSwitch(token)? = receipt {
                        try await engine.rollbackBackendSwitch(token)
                    } else if !previousEQ.isEmpty {
                        try await engine.apply(previousEQ)
                    }
                }
            )

            if backendChanged {
                appSnapshots = []
                devices = []
                displayRows = []
                try await refreshUnlocked()
            }
        }
    }

    func reset() async throws {
        await waitUntilReady()
        try await withMutationGate {
            let desired = settingsStore.defaultSettings()
            try await performSettingsTransaction(
                desired: desired,
                issueID: "reset",
                engineDomain: .backend,
                app: nil,
                engineWork: { [engine] in
                    try await engine.beginBackendSwitch(
                        to: desired.customization.backendMode,
                        forceRecreate: true
                    )
                },
                finalize: { [engine] token in try await engine.commitBackendSwitch(token) },
                compensate: { [engine] token in
                    if let token { try await engine.rollbackBackendSwitch(token) }
                }
            )
            appSnapshots = []
            devices = []
            displayRows = []
            try await refreshUnlocked()
        }
    }

    func completeOnboarding() async throws {
        await waitUntilReady()
        try await withMutationGate {
            var desired = settings
            desired.hasCompletedOnboarding = true
            try await performSettingsTransaction(
                desired: desired,
                issueID: "onboarding",
                engineDomain: .backend,
                app: nil,
                engineWork: { () },
                finalize: { _ in },
                compensate: { _ in }
            )
        }
    }

    private func performSettingsTransaction<Receipt: Sendable>(
        desired: PersistedSettings,
        issueID: String,
        engineDomain: AudioIssueDomain,
        app: AudioAppIdentity?,
        engineWork: @escaping () async throws -> Receipt,
        finalize: @escaping (Receipt) async throws -> Void,
        compensate: @escaping (Receipt?) async throws -> Void
    ) async throws {
        let previous = settings
        let transaction = AudioMutationTransaction(
            previousState: previous,
            desiredState: desired,
            issueID: issueID,
            engineIssueDomain: engineDomain,
            affectedApp: app,
            engineWork: engineWork,
            durableCommit: { [persistence] state in _ = try await persistence.commit(state) },
            finalizeEngineWork: finalize,
            compensation: compensate
        )
        try await execute(transaction)
    }

    private func execute<Receipt: Sendable>(_ transaction: AudioMutationTransaction<Receipt>) async throws {
        InternalDiagnostics.record(
            "operation",
            "transaction.begin id=\(transaction.issueID) app=\(transaction.affectedApp?.rawValue ?? "none")"
        )
        settings = transaction.desiredState
        rebuildDisplayRows()
        let receipt: Receipt
        do {
            receipt = try await transaction.engineWork()
        } catch {
            let engineError = error
            do { try await transaction.compensation(nil) }
            catch {
                reportIssue(
                    id: "\(transaction.issueID)-compensation",
                    domain: transaction.engineIssueDomain,
                    message: "Engine work failed and compensation also failed: \(engineError.localizedDescription) Compensation: \(error.localizedDescription)",
                    severity: .error,
                    app: transaction.affectedApp,
                    recovery: .retry
                )
            }
            settings = transaction.previousState
            rebuildDisplayRows()
            reportMutationFailure(
                engineError,
                id: transaction.issueID,
                domain: transaction.engineIssueDomain,
                app: transaction.affectedApp
            )
            throw engineError
        }

        do {
            try await transaction.durableCommit(transaction.desiredState)
        } catch {
            let persistenceError = error
            do {
                try await transaction.compensation(receipt)
                settings = transaction.previousState
                await persistence.schedule(transaction.previousState)
                rebuildDisplayRows()
            } catch {
                settings = transaction.desiredState
                await persistence.schedule(transaction.desiredState)
                rebuildDisplayRows()
                reportIssue(
                    id: "\(transaction.issueID)-compensation",
                    domain: transaction.engineIssueDomain,
                    message: "Couldn’t restore the previous audio state after persistence failed: \(error.localizedDescription)",
                    severity: .error,
                    app: transaction.affectedApp,
                    recovery: .retry
                )
            }
            reportPersistenceFailure(persistenceError, id: "\(transaction.issueID)-persistence", app: transaction.affectedApp)
            throw persistenceError
        }

        do {
            try await transaction.finalizeEngineWork(receipt)
        } catch {
            reportMutationFailure(
                error,
                id: "\(transaction.issueID)-finalize",
                domain: transaction.engineIssueDomain,
                app: transaction.affectedApp
            )
            throw error
        }
        dismissIssue(id: transaction.issueID)
        dismissIssue(id: "\(transaction.issueID)-persistence")
        dismissIssue(id: "\(transaction.issueID)-compensation")
        InternalDiagnostics.record("operation", "transaction.complete id=\(transaction.issueID)")
    }

    // MARK: - Edit sessions

    private func beginEdit(app: AudioAppIdentity, control: AudioEditControl) -> UUID {
        let lookup = EditLookup(app: app, control: control)
        if let existing = activeEditKeys[lookup] { return existing.gestureToken }
        let key = AudioEditSessionKey(app: app, control: control, gestureToken: UUID())
        editSessions[key] = settings
        activeEditKeys[lookup] = key
        return key.gestureToken
    }

    private func endEdit(app: AudioAppIdentity, control: AudioEditControl) {
        let lookup = EditLookup(app: app, control: control)
        guard let key = activeEditKeys[lookup] else { return }
        editTasks[key]?.cancel()
        editTasks[key] = nil
        launchIntent { store in try? await store.flushEditSession(key, isFinal: true) }
    }

    private func scheduleEditPreview(
        _ key: AudioEditSessionKey,
        debounceNanoseconds: UInt64 = 100_000_000
    ) {
        editTasks[key]?.cancel()
        editTasks[key] = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: debounceNanoseconds) }
            catch { return }
            guard !Task.isCancelled, let self else { return }
            try? await flushEditSession(key, isFinal: false)
        }
    }

    private func flushEditSession(_ key: AudioEditSessionKey, isFinal: Bool) async throws {
        await waitUntilReady()
        try await withMutationGate {
            guard let baseline = editSessions[key],
                  let currentApp = settings.appSettings[key.app],
                  let baselineApp = baseline.appSettings[key.app] else { return }
            let desiredCommand: AudioBackendCommand
            let compensation: AudioBackendCommand
            switch key.control {
            case .volume:
                desiredCommand = .setVolume(key.app, currentApp.volume)
                compensation = .setVolume(key.app, baselineApp.volume)
            case .eqBand:
                desiredCommand = .setEQ(key.app, currentApp.eq)
                compensation = .setEQ(key.app, baselineApp.eq)
            }

            if isFinal {
                do {
                    try await performSettingsTransaction(
                        desired: settings,
                        issueID: "edit-\(key.app.rawValue)-\(key.gestureToken.uuidString)",
                        engineDomain: .backend,
                        app: key.app,
                        engineWork: { [engine] in try await engine.apply(desiredCommand) },
                        finalize: { _ in },
                        compensate: { [engine] _ in try await engine.apply(compensation) }
                    )
                } catch {
                    removeEditSession(key)
                    throw error
                }
                removeEditSession(key)
            } else {
                do {
                    try await engine.apply(desiredCommand)
                    await persistence.schedule(settings)
                } catch {
                    try? await engine.apply(compensation)
                    settings = baseline
                    await persistence.schedule(baseline)
                    rebuildDisplayRows()
                    removeEditSession(key)
                    reportMutationFailure(error, id: "edit-\(key.app.rawValue)", domain: .backend, app: key.app)
                    throw error
                }
            }
        }
    }

    private func removeEditSession(_ key: AudioEditSessionKey) {
        editTasks[key]?.cancel()
        editTasks[key] = nil
        editSessions[key] = nil
        activeEditKeys[EditLookup(app: key.app, control: key.control)] = nil
    }

    // MARK: - Shutdown

    func shutdown() async -> AudioShutdownReport {
        if let completedShutdownReport { return completedShutdownReport }
        if let shutdownTask { return await shutdownTask.value }
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return AudioShutdownReport(
                    editSessionErrorDescriptions: [],
                    persistenceErrorDescription: nil,
                    engineReport: AudioEngineShutdownReport(
                        stoppedTopologyObservation: false,
                        stoppedOutputObservation: false,
                        stoppedMeterObservation: false,
                        teardownErrorDescription: nil
                    )
                )
            }
            return await performShutdown()
        }
        shutdownTask = task
        let report = await task.value
        completedShutdownReport = report
        return report
    }

    private func performShutdown() async -> AudioShutdownReport {
        var editErrors: [String] = []
        let keys = Array(editSessions.keys)
        for key in keys {
            editTasks[key]?.cancel()
            do { try await flushEditSession(key, isFinal: true) }
            catch { editErrors.append(error.localizedDescription) }
        }
        // Stop the main-actor consumers now; let engine.shutdown() stop and
        // report its owned HAL/output/meter observations as one operation.
        cancelObservationConsumers()

        let persistenceError: String?
        do {
            try await persistence.flush()
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
            reportPersistenceFailure(error, id: "shutdown-persistence")
        }

        // Always attempt engine teardown even when edit or persistence cleanup
        // failed. Tap teardown retains/journals unresolved Core Audio handles.
        let engineReport = await engine.shutdown()
        if let teardown = engineReport.teardownErrorDescription {
            reportIssue(
                id: "shutdown-taps",
                domain: .tap,
                message: "Audio shutdown left recoverable tap resources: \(teardown)",
                severity: .error,
                recovery: .retry
            )
        }
        return AudioShutdownReport(
            editSessionErrorDescriptions: editErrors,
            persistenceErrorDescription: persistenceError,
            engineReport: engineReport
        )
    }

    // MARK: - State derivation

    private func ensureSettings(for app: AudioAppSnapshot, in state: inout PersistedSettings) {
        if state.appSettings[app.identity] == nil {
            state.appSettings[app.identity] = AppAudioSettings(
                displayName: app.displayName,
                volume: state.customization.defaultNewAppVolume,
                eq: EQCurve(range: state.customization.eqGainRange)
            )
        } else {
            state.appSettings[app.identity]?.displayName = app.displayName
            if let route = state.appSettings[app.identity]?.route {
                state.appSettings[app.identity]?.route = route.normalized
            }
        }
    }

    private func ensureSettings(for identity: AudioAppIdentity, in state: inout PersistedSettings) {
        if state.appSettings[identity] != nil { return }
        let snapshot = appSnapshots.first { $0.identity == identity }
        state.appSettings[identity] = AppAudioSettings(
            displayName: snapshot?.displayName ?? identity.rawValue,
            volume: state.customization.defaultNewAppVolume,
            eq: EQCurve(range: state.customization.eqGainRange)
        )
    }

    private func mergeAppDisplayOrder() {
        var known: Set<AudioAppIdentity> = []
        var order = settings.appDisplayOrder.filter { $0.isPersistable && known.insert($0).inserted }
        var candidates = appSnapshots.map(\.identity)
        for pinned in settings.pinnedAppIDs where !candidates.contains(pinned) { candidates.append(pinned) }
        for id in candidates where id.isPersistable && known.insert(id).inserted { order.append(id) }
        settings.appDisplayOrder = order
    }

    private func rebuildDisplayRows() {
        let snapshotsByID = Dictionary(appSnapshots.map { ($0.identity, $0) }, uniquingKeysWith: Self.mergedSnapshot)
        var orderIndex: [AudioAppIdentity: Int] = [:]
        for (index, identity) in settings.appDisplayOrder.enumerated() where orderIndex[identity] == nil {
            orderIndex[identity] = index
        }
        var identities = Set(appSnapshots.map(\.identity))
        identities.formUnion(settings.pinnedAppIDs)
        displayRows = identities.compactMap { identity -> DisplayableAppRow? in
            guard !settings.ignoredAppIDs.contains(identity),
                  let appSettings = settings.appSettings[identity] else { return nil }
            let snapshot = snapshotsByID[identity]
            let active = snapshot?.isActive ?? false
            let pinned = settings.pinnedAppIDs.contains(identity)
            guard settings.customization.showInactiveApps || active || pinned else { return nil }
            return DisplayableAppRow(
                identity: identity,
                displayName: snapshot?.displayName ?? appSettings.displayName,
                isActive: active,
                isPinned: pinned,
                settings: appSettings
            )
        }.sorted { lhs, rhs in
            let lhsOrder = orderIndex[lhs.identity] ?? Int.max
            let rhsOrder = orderIndex[rhs.identity] ?? Int.max
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            if lhs.isActive != rhs.isActive { return lhs.isActive && !rhs.isActive }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private static func deduplicatedSnapshots(_ snapshots: [AudioAppSnapshot]) -> [AudioAppSnapshot] {
        var indices: [AudioAppIdentity: Int] = [:]
        var result: [AudioAppSnapshot] = []
        for snapshot in snapshots where snapshot.identity.isPersistable {
            if let index = indices[snapshot.identity] { result[index] = mergedSnapshot(result[index], snapshot) }
            else { indices[snapshot.identity] = result.count; result.append(snapshot) }
        }
        return result
    }

    private static func mergedSnapshot(_ first: AudioAppSnapshot, _ second: AudioAppSnapshot) -> AudioAppSnapshot {
        AudioAppSnapshot(
            identity: first.identity,
            displayName: first.displayName.isEmpty ? second.displayName : first.displayName,
            bundleIdentifier: first.bundleIdentifier ?? second.bundleIdentifier,
            isActive: first.isActive || second.isActive,
            level: max(first.level, second.level)
        )
    }

    private static func backendCommand(
        for identity: AudioAppIdentity,
        settings: AppAudioSettings,
        issuePrefix: String
    ) -> AudioBackendCommand {
        switch issuePrefix {
        case "volume": .setVolume(identity, settings.volume)
        case "mute": .setMuted(identity, settings.isMuted)
        case "boost": .setBoost(identity, settings.boost)
        case "eq": .setEQ(identity, settings.eq)
        case "route": .setRoute(identity, settings.route.normalized)
        default: .setVolume(identity, settings.volume)
        }
    }

    // MARK: - Coordination helpers and issues

    private func withMutationGate<Value>(_ operation: () async throws -> Value) async rethrows -> Value {
        await mutationGate.acquire()
        do {
            let value = try await operation()
            await mutationGate.release()
            return value
        } catch {
            await mutationGate.release()
            throw error
        }
    }

    private func launchIntent(_ operation: @escaping @MainActor (AudioControlStore) async -> Void) {
        guard completedShutdownReport == nil else { return }
        let id = UUID()
        intentTasks[id] = Task { [weak self] in
            guard let self else { return }
            await operation(self)
            intentTasks[id] = nil
        }
    }

    func waitForPendingOperations() async {
        while true {
            let tasks = Array(intentTasks.values)
            if tasks.isEmpty { return }
            for task in tasks { await task.value }
        }
    }

    func persistenceDiagnostics() async -> SettingsPersistenceDiagnostics {
        await persistence.diagnostics()
    }

    private func reportMutationFailure(
        _ error: Error,
        id: String,
        domain: AudioIssueDomain,
        app: AudioAppIdentity? = nil,
        device: String? = nil
    ) {
        let message = "Couldn’t apply change: \(error.localizedDescription)"
        operationState = .degraded(message)
        reportIssue(
            id: id,
            domain: domain,
            message: message,
            severity: .error,
            app: app,
            device: device,
            recovery: .retry
        )
    }

    private func reportPersistenceFailure(
        _ error: Error,
        id: String,
        app: AudioAppIdentity? = nil
    ) {
        let message = "Couldn’t save settings: \(error.localizedDescription)"
        operationState = .degraded(message)
        reportIssue(
            id: id,
            domain: .persistence,
            message: message,
            severity: .error,
            app: app,
            recovery: .retry
        )
    }

    private func reportIssue(
        id: String,
        domain: AudioIssueDomain,
        message: String,
        severity: AudioIssueSeverity = .warning,
        app: AudioAppIdentity? = nil,
        device: String? = nil,
        recovery: AudioRecoveryAction? = nil
    ) {
        let issue = AudioIssue(
            id: id,
            domain: domain,
            severity: severity,
            affectedApp: app,
            affectedDeviceID: device,
            message: message,
            recovery: recovery
        )
        let previous = issues.first { $0.id == id }
        issues.removeAll { $0.id == id }
        issues.append(issue)
        guard previous != issue else { return }
        let diagnostic = "issue id=\(id) domain=\(domain.rawValue) message=\(message)"
        switch severity {
        case .warning:
            InternalDiagnostics.warning("issue", diagnostic)
        case .error:
            InternalDiagnostics.error("issue", diagnostic)
        }
    }

    func dismissIssue(id: String) { issues.removeAll { $0.id == id } }

    func reportWidgetIPCConfigurationError(_ message: String?) {
        let id = "widget-ipc-configuration"
        guard let message else { dismissIssue(id: id); return }
        reportIssue(id: id, domain: .widget, message: message, severity: .error)
    }

    func reportExternalControlIssue(
        id: String,
        message: String?,
        severity: AudioIssueSeverity = .error,
        recovery: AudioRecoveryAction? = .retryExternalControls
    ) {
        guard let message else {
            dismissIssue(id: id)
            return
        }
        reportIssue(
            id: id,
            domain: .externalControl,
            message: message,
            severity: severity,
            recovery: recovery
        )
    }
}
