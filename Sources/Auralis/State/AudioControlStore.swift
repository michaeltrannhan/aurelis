import Combine
import Foundation

private enum AudioControlStoreError: LocalizedError {
    case appUnavailable(String)
    case outputVolumeUnsupported(String)
    case outputMuteUnsupported(String)
    case outputDeviceUnavailable(String)
    case profileUnavailable
    case profileNameRequired
    case shuttingDown

    var errorDescription: String? {
        switch self {
        case let .appUnavailable(identity): "The audio app \(identity) is unavailable."
        case let .outputVolumeUnsupported(device): "\(device) does not expose a settable output volume."
        case let .outputMuteUnsupported(device): "\(device) does not expose a settable mute control."
        case let .outputDeviceUnavailable(device): "The output device \(device) is unavailable."
        case .profileUnavailable: "The selected audio profile is unavailable."
        case .profileNameRequired: "Enter a name for the audio profile."
        case .shuttingDown: "The audio engine is shutting down."
        }
    }
}

private enum SettingsEngineReceipt: Sendable {
    case none
    case backendSwitch(AudioBackendSwitchToken)
}

private enum AppSettingMutationKind: String {
    case volume
    case volumeAndMute
    case mute
    case boost
    case eq
    case route

    var issueDomain: AudioIssueDomain {
        self == .route ? .tap : .backend
    }

    var issueName: String {
        self == .volumeAndMute ? "volume" : rawValue
    }

    func commands(
        for identity: AudioAppIdentity,
        settings: AppAudioSettings
    ) -> [AudioBackendCommand] {
        switch self {
        case .volume: [.setVolume(identity, settings.volume)]
        case .volumeAndMute: [
            .setVolume(identity, settings.volume),
            .setMuted(identity, settings.isMuted),
        ]
        case .mute: [.setMuted(identity, settings.isMuted)]
        case .boost: [.setBoost(identity, settings.boost)]
        case .eq: [.setEQ(identity, settings.eq)]
        case .route: [.setRoute(identity, settings.route.normalized)]
        }
    }
}

enum AudioContextSwitchState: Equatable, Sendable {
    case idle
    case detecting
    case applied(deviceID: String, deviceName: String)
    case failed(String)
}

@MainActor
final class AudioControlStore: ObservableObject, AudioControlCommanding {
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
    @Published private(set) var mixerPhase: MixerPhase = .starting
    @Published private(set) var healthSnapshot: AudioHealthSnapshot = .starting
    @Published private(set) var storePhase: StorePhase = .booting
    @Published private(set) var issues: [AudioIssue] = []
    @Published private(set) var permissionState: AudioCapturePermissionState = .unknown
    @Published private(set) var deviceVolumeStates: [String: OutputVolumeState] = [:]
    @Published private(set) var contextSwitchState: AudioContextSwitchState = .idle
    let commandCoordinator = ControlCommandCoordinator()
    let channels = ChannelModelDirectory()
    private var healthInputs = AudioHealthInputs(isBootstrapping: true)
    private var coordinatorCancellable: AnyCancellable?

    /// Live meter levels live on their own object so the ~10 Hz stream does not
    /// invalidate views bound to this store. See `AppLevelStore`.
    let appLevels = AppLevelStore()

    private var bootstrapTask: Task<Void, Never>?
    private var topologyObservationTask: Task<Void, Never>?
    private var outputObservationTask: Task<Void, Never>?
    private var levelObservationTask: Task<Void, Never>?
    private var topologyReconciliationTask: Task<Void, Never>?
    private var intentTasks: [UUID: Task<Void, Never>] = [:]
    private var editSessions: [AudioEditSessionKey: PersistedSettings] = [:]
    private var activeEditKeys: [EditLookup: AudioEditSessionKey] = [:]
    private var editTasks: [AudioEditSessionKey: Task<Void, Never>] = [:]
    private var outputEQEditSessions: [OutputEQEditSessionKey: PersistedSettings] = [:]
    private var activeOutputEQEditKeys: [OutputEQEditLookup: OutputEQEditSessionKey] = [:]
    private var outputEQEditTasks: [OutputEQEditSessionKey: Task<Void, Never>] = [:]
    private var shutdownTask: Task<AudioShutdownReport, Never>?
    private var completedShutdownReport: AudioShutdownReport?
    private var lastObservedDefaultOutputDeviceID: String?
    private var lastAvailableOutputDeviceIDs: Set<String> = []
    private(set) var topologyRefreshCount = 0

    private struct EditLookup: Hashable {
        let app: AudioAppIdentity
        let control: AudioEditControl
    }

    private struct DeviceSettingsApplication: Sendable {
        let deviceUID: String
        let volume: Double?
        let isMuted: Bool?
        let eq: EQCurve
    }

    private struct OutputEQEditLookup: Hashable {
        let deviceUID: String
        let band: Int
    }

    private struct OutputEQEditSessionKey: Hashable {
        let deviceUID: String
        let band: Int
        let gestureToken: UUID
    }

    private struct TopologySignature: Equatable {
        let revision: TopologyRevision

        init(_ snapshot: AudioBackendSnapshot) {
            revision = TopologyRevision(
                defaultOutputUID: snapshot.devices.first(where: \.isDefault)?.id,
                availableOutputUIDs: Set(snapshot.devices.map(\.id))
            )
        }

        init(_ revision: TopologyRevision) {
            self.revision = revision
        }
    }

    var statusMessage: String { operationState.message }

    var activeGlobalProfile: AudioProfile? {
        settings.profiles.first { $0.id == settings.activeGlobalProfileID }
    }

    var activeLocalProfile: AudioProfile? {
        settings.profiles.first { $0.id == settings.activeLocalProfileID }
    }

    var activeProfile: AudioProfile? {
        activeLocalProfile ?? activeGlobalProfile
    }

    var currentOutput: AudioDeviceSnapshot? {
        devices.first(where: \.isDefault)
    }

    var currentDeviceContext: AudioProfile? {
        currentOutput.flatMap { outputConfiguration(for: $0.id) }
    }

    func outputConfiguration(for deviceID: String) -> AudioProfile? {
        settings.profiles.first {
            $0.scope.outputDeviceID == deviceID
        }
    }

    var activeEditSessionKeys: Set<AudioEditSessionKey> {
        Set(editSessions.keys)
    }

    var activeOutputEQEditSessionCount: Int {
        outputEQEditSessions.count
    }

    init(
        settingsStore: SettingsStore = SettingsStore(),
        backend: sending (any AudioBackend)? = nil,
        backendFactory: @escaping @Sendable (BackendMode) -> any AudioBackend = { AudioBackendFactory.makeBackend(mode: $0) },
        permissionClient: any AudioCapturePermissionClient = SystemAudioCapturePermissionClient()
    ) {
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
        commandCoordinator.attach(store: self)
        coordinatorCancellable = commandCoordinator.$actionStates.sink { [weak self] states in
            self?.channels.apply(actionStates: states)
        }
        rebuildDisplayRows()
        publishHealth()
        bootstrapTask = Task { [weak self] in
            await self?.performBootstrap()
        }
    }

    // MARK: - Control commanding

    func submit(_ command: ControlCommand) -> ControlReceipt {
        guard storePhase == .running || storePhase == .booting,
              completedShutdownReport == nil else {
            return .rejected(
                target: command.target,
                mutation: command.mutation,
                source: command.source,
                failure: UserFacingFailure(
                    title: "Unavailable",
                    message: "Auralis is shutting down."
                )
            )
        }
        return commandCoordinator.submit(command)
    }

    func result(for receiptID: UUID) async -> ControlResult {
        await commandCoordinator.result(for: receiptID)
    }

    func executeProjectedControl(_ command: ControlCommand) async -> ControlResult {
        do {
            let projected = try project(command)
            return await executeControl(command, projected: projected)
        } catch {
            return .rejected(UserFacingFailure.from(error))
        }
    }

    func recheckPermissionsOnActivation() {
        refreshPermissionState()
        // Accessibility is only requested when media keys are enabled in Controls.
        // Rechecking trust state is safe and does not prompt.
    }

    func waitUntilReady() async {
        let task = bootstrapTask
        await task?.value
    }

    func waitForPendingPersistence() async {
        await persistence.waitForScheduledWork()
    }

    private func performBootstrap() async {
        defer {
            healthInputs.isBootstrapping = false
            if storePhase == .booting { storePhase = .running }
            publishHealth()
            bootstrapTask = nil
        }
        storePhase = .booting
        healthInputs.isBootstrapping = true
        publishHealth()
        InternalDiagnostics.record("persistence", "bootstrap.begin")
        do {
            let result = try await persistence.loadWithRecovery()
            settings = result.settings
            await engine.selectInitialMode(result.settings.customization.backendMode)
            if let notice = result.recoveryNotice {
                healthInputs.persistenceState = .dirty
                healthInputs.persistenceMessage = notice.message
                reportIssue(
                    id: "settings-recovery",
                    domain: .persistence,
                    message: notice.message,
                    severity: .warning
                )
            } else {
                healthInputs.persistenceState = .clean
            }
            InternalDiagnostics.record(
                "persistence",
                "bootstrap.complete recovered=\(result.recoveryNotice != nil) apps=\(result.settings.appSettings.count)"
            )
        } catch let error as SettingsStoreError {
            if case .futureVersion = error {
                await persistence.blockWrites(because: error)
                settings = settingsStore.defaultSettings()
                let message = "This app cannot read the newer settings file. It was left unchanged; update Auralis before saving settings."
                healthInputs.persistenceState = .writeBlocked
                healthInputs.persistenceMessage = message
                reportIssue(id: "settings-version", domain: .persistence, message: message, severity: .error)
            } else {
                reportPersistenceFailure(error, id: "settings-load")
            }
        } catch {
            reportPersistenceFailure(error, id: "settings-load")
        }
        rebuildDisplayRows()
        publishHealth()
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
        healthInputs.isRefreshing = true
        healthInputs.discoveryFailed = false
        healthInputs.discoveryFailureMessage = nil
        publishHealth()
        let engineSnapshot: AudioEngineSnapshot
        do {
            engineSnapshot = try await engine.fetchSnapshot(
                settings: settings,
                permissionAllowsTaps: permissionState.allowsProcessTaps
            )
        } catch {
            let failure = UserFacingFailure.from(error, title: "Audio discovery failed")
            healthInputs.isRefreshing = false
            healthInputs.discoveryFailed = true
            healthInputs.discoveryFailureMessage = failure.message
            publishHealth()
            reportIssue(
                id: "refresh",
                domain: .backend,
                message: failure.message,
                severity: .error,
                recovery: .refreshAudio
            )
            throw error
        }

        let previousDefaultOutputID = lastObservedDefaultOutputDeviceID
        let previousOutputDeviceIDs = lastAvailableOutputDeviceIDs
        appSnapshots = Self.deduplicatedSnapshots(engineSnapshot.backend.apps)
            .sorted { lhs, rhs in
                StableDisplayOrder.precedes(
                    lhsName: lhs.displayName,
                    lhsID: lhs.identity.rawValue,
                    rhsName: rhs.displayName,
                    rhsID: rhs.identity.rawValue
                )
            }
        devices = engineSnapshot.backend.devices
        deviceVolumeStates = engineSnapshot.output.devices
        let currentDefaultOutputID = devices.first(where: \.isDefault)?.id
        let currentOutputDeviceIDs = Set(devices.map(\.id))
        let beforeDiscoveryMerge = settings
        for app in appSnapshots { ensureSettings(for: app, in: &settings) }
        AudioProfileContextPlanner.ensureAutomaticDeviceContexts(in: &settings, devices: devices)
        mergeAppDisplayOrder()

        var persistenceIssue: String?
        var profileStateSynchronized = true
        var refreshStateWasCommitted = false
        let defaultOutputChanged = previousDefaultOutputID != currentDefaultOutputID
        let defaultOutputReconnected = currentDefaultOutputID.map {
            currentOutputDeviceIDs.subtracting(previousOutputDeviceIDs).contains($0)
        } ?? false
        if let currentDefaultOutputID,
           defaultOutputChanged || defaultOutputReconnected {
            do {
                try await applyAutomaticProfilesUnlocked(for: currentDefaultOutputID)
                refreshStateWasCommitted = true
                dismissIssue(id: "profile-auto-activation")
            } catch {
                profileStateSynchronized = false
                reportIssue(
                    id: "profile-auto-activation",
                    domain: .backend,
                    message: "Couldn’t apply the profile for this output: \(error.localizedDescription)",
                    recovery: .retry
                )
            }
        }
        if profileStateSynchronized {
            lastObservedDefaultOutputDeviceID = currentDefaultOutputID
            lastAvailableOutputDeviceIDs = currentOutputDeviceIDs
        }
        if !refreshStateWasCommitted, settings != beforeDiscoveryMerge {
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

        healthInputs.isRefreshing = false
        healthInputs.visibleAppCount = displayRows.count
        healthInputs.statusMessage = engineSnapshot.statusMessage
        healthInputs.tapFaults = engineSnapshot.tapIssue.map { ["Tap setup error: \($0)"] } ?? []
        healthInputs.backendFaults = engineSnapshot.restoreIssue.map { ["Audio settings restore error: \($0)"] } ?? []
        if let persistenceIssue {
            healthInputs.persistenceState = .failed
            healthInputs.persistenceMessage = "Couldn’t save discovered audio state: \(persistenceIssue)"
        }
        rebuildDisplayRows()
        healthInputs.visibleAppCount = displayRows.count
        publishHealth()
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
                topologyReconciliationTask?.cancel()
                topologyReconciliationTask = Task { [weak self] in
                    await self?.reconcileStableTopology()
                }
            }
        }
        let outputEvents = engine.outputEvents
        outputObservationTask = Task { [weak self] in
            for await output in outputEvents {
                guard !Task.isCancelled, let self else { return }
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

    private func reconcileStableTopology() async {
        contextSwitchState = .detecting
        var previousSignature: TopologySignature?
        let maximumSamples = 14 // ~1 second at the confirmation interval.

        do {
            for sampleIndex in 0..<maximumSamples {
                try Task.checkCancellation()
                let revision = try await engine.topologyRevision()
                let signature = TopologySignature(revision)
                if signature == previousSignature { break }
                previousSignature = signature
                guard sampleIndex < maximumSamples - 1 else { break }
                try await Task.sleep(nanoseconds: 75_000_000)
            }
            try Task.checkCancellation()
            try await refresh()
            if let output = currentOutput {
                contextSwitchState = .applied(
                    deviceID: output.id,
                    deviceName: output.name
                )
            } else {
                contextSwitchState = .idle
            }
        } catch is CancellationError {
            return
        } catch {
            contextSwitchState = .failed(error.localizedDescription)
            reportIssue(
                id: "topology-reconciliation",
                domain: .backend,
                message: "Couldn’t refresh the current output: \(error.localizedDescription)",
                recovery: .retry
            )
        }
    }

    private func cancelObservationConsumers() {
        topologyReconciliationTask?.cancel()
        topologyReconciliationTask = nil
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
        healthInputs.permissionAllowsTaps = permissionState.allowsProcessTaps
        healthInputs.permissionDenied = !permissionState.allowsProcessTaps
        healthInputs.permissionMessage = permissionState.allowsProcessTaps ? nil : permissionState.summary
        if !permissionState.allowsProcessTaps {
            reportIssue(
                id: "audio-permission",
                domain: .permission,
                message: permissionState.summary,
                recovery: .requestAudioPermission
            )
        } else {
            dismissIssue(id: "audio-permission")
        }
        publishHealth()
    }

    func requestAudioCapturePermission() {
        permissionState = permissions.requestAudioCapture()
        healthInputs.permissionAllowsTaps = permissionState.allowsProcessTaps
        healthInputs.permissionDenied = !permissionState.allowsProcessTaps
        healthInputs.permissionMessage = permissionState.allowsProcessTaps ? nil : permissionState.summary
        healthInputs.statusMessage = permissionState.summary
        publishHealth()
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
                let failure = UserFacingFailure.from(error, title: "Tap sync failed")
                store.reportIssue(
                    id: "permission-tap-sync",
                    domain: .tap,
                    message: failure.message,
                    recovery: .refreshAudio
                )
            }
        }
        rebuildDisplayRows()
    }

    func openAudioCapturePrivacySettings() { permissions.openAudioPrivacySettings() }
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

    func setDeviceVolumeIntent(_ volume: Double, for deviceUID: String) {
        launchIntent { store in try? await store.setDeviceVolume(volume, for: deviceUID) }
    }

    func setDeviceMutedIntent(_ muted: Bool, for deviceUID: String) {
        launchIntent { store in try? await store.setDeviceMuted(muted, for: deviceUID) }
    }

    func setDefaultOutputDeviceIntent(_ deviceUID: String) {
        launchIntent { store in try? await store.setDefaultOutputDevice(deviceUID) }
    }

    func toggleDeviceMuteIntent(for deviceUID: String) {
        setDeviceMutedIntent(!(deviceVolumeStates[deviceUID]?.isMuted ?? false), for: deviceUID)
    }

    func setOutputEQGainIntent(_ gain: Double, band: Int, for deviceUID: String) {
        let lookup = OutputEQEditLookup(deviceUID: deviceUID, band: band)
        if let key = activeOutputEQEditKeys[lookup] {
            mutateLiveOutputEQ(deviceUID: deviceUID) {
                $0.setGain(gain, at: band)
            }
            scheduleOutputEQEditPreview(key)
        } else {
            launchIntent { store in
                try? await store.setOutputEQGain(gain, band: band, for: deviceUID)
            }
        }
    }

    @discardableResult
    func beginOutputEQEditing(band: Int, for deviceUID: String) -> UUID {
        let lookup = OutputEQEditLookup(deviceUID: deviceUID, band: band)
        if let existing = activeOutputEQEditKeys[lookup] {
            return existing.gestureToken
        }
        let key = OutputEQEditSessionKey(
            deviceUID: deviceUID,
            band: band,
            gestureToken: UUID()
        )
        outputEQEditSessions[key] = settings
        activeOutputEQEditKeys[lookup] = key
        return key.gestureToken
    }

    func endOutputEQEditing(band: Int, for deviceUID: String) {
        let lookup = OutputEQEditLookup(deviceUID: deviceUID, band: band)
        guard let key = activeOutputEQEditKeys[lookup] else { return }
        outputEQEditTasks[key]?.cancel()
        outputEQEditTasks[key] = nil
        launchIntent { store in
            try? await store.flushOutputEQEditSession(key, isFinal: true)
        }
    }

    func setOutputEQEditingIntent(_ editing: Bool, band: Int, for deviceUID: String) {
        if editing {
            beginOutputEQEditing(band: band, for: deviceUID)
        } else {
            endOutputEQEditing(band: band, for: deviceUID)
        }
    }

    func resetOutputEQIntent(for deviceUID: String) {
        launchIntent { store in
            try? await store.resetOutputEQ(for: deviceUID)
        }
    }

    func endContinuousOutputEQEdits(for deviceUID: String) {
        let lookups = activeOutputEQEditKeys.keys.filter {
            $0.deviceUID == deviceUID
        }
        for lookup in lookups {
            endOutputEQEditing(band: lookup.band, for: lookup.deviceUID)
        }
    }

    func setVolumeIntent(_ volume: Double, for identity: AudioAppIdentity) {
        let lookup = EditLookup(app: identity, control: .volume)
        if let key = activeEditKeys[lookup] {
            ensureSettings(for: identity, in: &settings)
            settings.appSettings[identity]?.setVolume(volume)
            AudioProfileContextPlanner.updateActiveDeviceContext(
                in: &settings,
                currentOutputID: currentOutput?.id
            )
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
            AudioProfileContextPlanner.updateActiveDeviceContext(
                in: &settings,
                currentOutputID: currentOutput?.id
            )
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

    func setEQEditingIntent(_ editing: Bool, band: Int, for identity: AudioAppIdentity) {
        if editing {
            beginEQEditing(band: band, for: identity)
        } else {
            endEQEditing(band: band, for: identity)
        }
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

    func createProfileIntent(named name: String, scope: AudioProfileScope) {
        launchIntent {
            _ = try? await $0.createProfile(
                named: name,
                scope: scope
            )
        }
    }

    func updateProfileIntent(_ profileID: UUID) {
        launchIntent { store in try? await store.updateProfile(profileID) }
    }

    func applyProfileIntent(_ profileID: UUID) {
        launchIntent { store in try? await store.applyProfile(profileID) }
    }

    func deleteProfileIntent(_ profileID: UUID) {
        launchIntent { store in try? await store.deleteProfile(profileID) }
    }

    func assignPresetToOutputIntent(
        profileID: UUID,
        deviceID: String,
        deviceName: String
    ) {
        launchIntent {
            _ = try? await $0.assignPreset(
                profileID,
                toOutput: deviceID,
                deviceName: deviceName
            )
        }
    }

    func removeOutputConfigurationIntent(deviceID: String) {
        launchIntent {
            try? await $0.removeOutputConfiguration(for: deviceID)
        }
    }

    // MARK: - Output mutations

    func setDeviceVolume(_ volume: Double, for deviceUID: String) async throws {
        await waitUntilReady()
        try await withMutationGate {
            let state = deviceVolumeStates[deviceUID] ?? OutputVolumeState()
            guard state.capabilities.canSetVolume else {
                throw AudioControlStoreError.outputVolumeUnsupported(state.deviceName ?? deviceUID)
            }
            let clamped = min(max(volume.isFinite ? volume : state.volume, 0), 1)
            guard let device = devices.first(where: { $0.id == deviceUID }) else {
                throw AudioControlStoreError.outputDeviceUnavailable(deviceUID)
            }
            var desired = settings
            desired.deviceSettings[deviceUID] = preservedDeviceSettings(
                deviceUID: deviceUID,
                displayName: device.name,
                volume: clamped,
                isMuted: state.isMuted
            )
            AudioProfileContextPlanner.updateActiveDeviceContext(
                in: &desired,
                currentOutputID: currentOutput?.id,
                changedDeviceID: deviceUID
            )
            try await performSettingsTransaction(
                previous: settings,
                desired: desired,
                issueID: "device-volume-\(deviceUID)",
                engineDomain: .backend,
                app: nil,
                engineWork: { [engine] in
                    try await engine.setOutputVolume(clamped, forUID: deviceUID)
                },
                finalize: { _ in },
                compensate: { [engine] _ in
                    try await engine.setOutputVolume(state.volume, forUID: deviceUID)
                }
            )
            deviceVolumeStates[deviceUID]?.volume = clamped
            rebuildDisplayRows()
            InternalDiagnostics.record(
                "audio",
                "device.volume id=\(deviceUID) applied=\(clamped)"
            )
        }
    }

    func setDeviceMuted(_ muted: Bool, for deviceUID: String) async throws {
        await waitUntilReady()
        try await withMutationGate {
            let state = deviceVolumeStates[deviceUID] ?? OutputVolumeState()
            guard state.capabilities.canSetMute else {
                throw AudioControlStoreError.outputMuteUnsupported(state.deviceName ?? deviceUID)
            }
            guard let device = devices.first(where: { $0.id == deviceUID }) else {
                throw AudioControlStoreError.outputDeviceUnavailable(deviceUID)
            }
            var desired = settings
            desired.deviceSettings[deviceUID] = preservedDeviceSettings(
                deviceUID: deviceUID,
                displayName: device.name,
                volume: state.volume,
                isMuted: muted
            )
            AudioProfileContextPlanner.updateActiveDeviceContext(
                in: &desired,
                currentOutputID: currentOutput?.id,
                changedDeviceID: deviceUID
            )
            try await performSettingsTransaction(
                previous: settings,
                desired: desired,
                issueID: "device-mute-\(deviceUID)",
                engineDomain: .backend,
                app: nil,
                engineWork: { [engine] in
                    try await engine.setOutputMuted(muted, forUID: deviceUID)
                },
                finalize: { _ in },
                compensate: { [engine] _ in
                    try await engine.setOutputMuted(state.isMuted, forUID: deviceUID)
                }
            )
            deviceVolumeStates[deviceUID]?.isMuted = muted
            rebuildDisplayRows()
            InternalDiagnostics.record(
                "audio",
                "device.mute id=\(deviceUID) applied=\(muted)"
            )
        }
    }

    func setDefaultOutputDevice(_ deviceUID: String) async throws {
        await waitUntilReady()
        try await withMutationGate {
            guard let device = devices.first(where: { $0.id == deviceUID }) else {
                throw AudioControlStoreError.outputDeviceUnavailable(deviceUID)
            }
            let previousDefault = devices.first(where: \.isDefault)?.id
            var desired = settings
            desired.preferredOutputDeviceID = deviceUID
            AudioProfileContextPlanner.setActiveProfiles(
                globalID: desired.activeGlobalProfileID,
                localID: nil,
                in: &desired
            )
            try await performSettingsTransaction(
                previous: settings,
                desired: desired,
                issueID: "default-output-\(deviceUID)",
                engineDomain: .backend,
                app: nil,
                engineWork: { [engine] in
                    try await engine.setDefaultOutputDevice(forUID: deviceUID)
                },
                finalize: { _ in },
                compensate: { [engine] _ in
                    if let previousDefault {
                        try await engine.setDefaultOutputDevice(forUID: previousDefault)
                    }
                }
            )
            devices = devices.map {
                AudioDeviceSnapshot(id: $0.id, name: $0.name, isDefault: $0.id == deviceUID)
            }
            try await applyAutomaticProfilesUnlocked(for: deviceUID)
            lastObservedDefaultOutputDeviceID = deviceUID
            lastAvailableOutputDeviceIDs = Set(devices.map(\.id))
            InternalDiagnostics.record(
                "audio",
                "device.default id=\(deviceUID) name=\(device.name)"
            )
        }
    }

    // MARK: - Profiles

    @discardableResult
    func createProfile(
        named name: String,
        scope: AudioProfileScope = .global
    ) async throws -> UUID {
        await waitUntilReady()
        if let outputID = scope.normalized.outputDeviceID {
            return try await saveOutputConfiguration(
                for: outputID,
                deviceName: name
            )
        }
        return try await withMutationGate {
            let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedName.isEmpty else {
                throw AudioControlStoreError.profileNameRequired
            }
            let profile = makeCurrentProfile(
                name: normalizedName,
                scope: scope
            )
            var desired = settings
            desired.profiles.append(profile)
            AudioProfileContextPlanner.setActiveProfiles(
                globalID: nil,
                localID: desired.activeLocalProfileID,
                in: &desired
            )
            try await commitSettings(
                desired,
                previous: settings,
                issueID: "profile-create-\(profile.id.uuidString)"
            )
            return profile.id
        }
    }

    /// Captures the current mixer state in the automatic context for one output.
    @discardableResult
    func saveOutputConfiguration(
        for deviceID: String,
        deviceName: String
    ) async throws -> UUID {
        await waitUntilReady()
        return try await withMutationGate {
            let normalizedID = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedID.isEmpty else {
                throw AudioControlStoreError.outputDeviceUnavailable(deviceID)
            }
            let normalizedName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            let existing = outputConfiguration(for: normalizedID)
            var configuration = makeCurrentProfile(
                name: normalizedName.isEmpty ? "Output Configuration" : normalizedName,
                id: existing?.id ?? UUID(),
                scope: .outputDevice(normalizedID)
            )
            configuration.createdAt = existing?.createdAt ?? configuration.createdAt

            var desired = settings
            AudioProfileContextPlanner.upsertOutputConfiguration(
                configuration,
                for: normalizedID,
                currentOutputID: currentOutput?.id,
                in: &desired
            )
            try await commitSettings(
                desired,
                previous: settings,
                issueID: "output-configuration-save-\(normalizedID)"
            )
            return configuration.id
        }
    }

    /// Copies a reusable Global preset into an output's dedicated
    /// configuration. Its per-app Process EQ and per-device Output EQ then follow that
    /// output automatically, while the output keeps its own hardware state.
    @discardableResult
    func assignPreset(
        _ profileID: UUID,
        toOutput deviceID: String,
        deviceName: String
    ) async throws -> UUID {
        await waitUntilReady()
        return try await withMutationGate {
            guard let preset = settings.profiles.first(where: {
                $0.id == profileID && $0.scope.isGlobal
            }) else {
                throw AudioControlStoreError.profileUnavailable
            }
            let normalizedID = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedID.isEmpty else {
                throw AudioControlStoreError.outputDeviceUnavailable(deviceID)
            }
            let existing = outputConfiguration(for: normalizedID)
            let capturedDevices = capturedDeviceSettings()
            var capturedDevice = capturedDevices[normalizedID]
                ?? existing?.deviceSettings[normalizedID]
            let normalizedDeviceName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedDeviceName.isEmpty {
                capturedDevice?.displayName = normalizedDeviceName
            }
            var copiedAppSettings = AudioProfile.flatAppSettings(
                from: settings.appSettings,
                customization: settings.customization
            )
            for (identity, appSettings) in preset.appSettings {
                copiedAppSettings[identity] = appSettings
            }
            var copiedDeviceSettings = preset.deviceSettings
            if var presetDevice = copiedDeviceSettings[normalizedID] {
                if !normalizedDeviceName.isEmpty {
                    presetDevice.displayName = normalizedDeviceName
                }
                copiedDeviceSettings[normalizedID] = presetDevice
            } else if let capturedDevice {
                copiedDeviceSettings[normalizedID] = capturedDevice
            }
            let routedDeviceIDs = AudioProfileContextPlanner.referencedOutputDeviceIDs(
                in: copiedAppSettings,
                followDefaultOutputID: normalizedID
            )
            for deviceID in routedDeviceIDs
            where copiedDeviceSettings[deviceID] == nil {
                copiedDeviceSettings[deviceID] = capturedDevices[deviceID]
            }
            var configuration = AudioProfile(
                id: existing?.id ?? UUID(),
                name: preset.name,
                scope: .outputDevice(normalizedID),
                activatesAutomatically: true,
                appSettings: copiedAppSettings,
                deviceSettings: copiedDeviceSettings,
                preferredOutputDeviceID: normalizedID
            )
            configuration.createdAt = existing?.createdAt ?? configuration.createdAt

            var desired = settings
            let currentOutputID = devices.first(where: \.isDefault)?.id
            AudioProfileContextPlanner.upsertOutputConfiguration(
                configuration,
                for: normalizedID,
                currentOutputID: currentOutputID,
                in: &desired
            )
            try await commitSettings(
                desired,
                previous: settings,
                issueID: "output-preset-assign-\(normalizedID)"
            )

            if currentOutputID == normalizedID {
                try await applyAutomaticProfilesUnlocked(for: normalizedID)
            }
            return configuration.id
        }
    }

    @discardableResult
    func assignPresetToCurrentOutput(_ profileID: UUID) async throws -> UUID {
        await waitUntilReady()
        guard let output = devices.first(where: \.isDefault) else {
            throw AudioControlStoreError.outputDeviceUnavailable("default output")
        }
        return try await assignPreset(
            profileID,
            toOutput: output.id,
            deviceName: output.name
        )
    }

    func removeOutputConfiguration(for deviceID: String) async throws {
        await waitUntilReady()
        try await withMutationGate {
            let configurationIDs = Set(settings.profiles.compactMap { profile in
                profile.scope.outputDeviceID == deviceID ? profile.id : nil
            })
            guard !configurationIDs.isEmpty else { return }
            var desired = settings
            desired.profiles.removeAll { configurationIDs.contains($0.id) }
            if let device = devices.first(where: { $0.id == deviceID }) {
                let hardware = deviceVolumeStates[deviceID]
                let remembered = desired.deviceSettings[deviceID]
                desired.deviceSettings[deviceID] = DeviceAudioSettings(
                    displayName: device.name,
                    volume: hardware?.volume ?? remembered?.volume ?? 1,
                    isMuted: hardware?.isMuted ?? remembered?.isMuted ?? false,
                    eq: EQCurve(range: desired.customization.eqGainRange)
                )
            } else {
                desired.deviceSettings.removeValue(forKey: deviceID)
            }
            let retainedLocalID = desired.activeLocalProfileID.flatMap {
                configurationIDs.contains($0) ? nil : $0
            }
            AudioProfileContextPlanner.setActiveProfiles(
                globalID: desired.activeGlobalProfileID,
                localID: retainedLocalID,
                in: &desired
            )
            // Connected outputs always own a context. Removing the current
            // context therefore means reset-to-neutral; disconnected outputs
            // are genuinely forgotten.
            AudioProfileContextPlanner.ensureAutomaticDeviceContexts(in: &desired, devices: devices)
            try await commitSettings(
                desired,
                previous: settings,
                issueID: "output-configuration-remove-\(deviceID)"
            )

            if devices.first(where: \.isDefault)?.id == deviceID {
                try await applyAutomaticProfilesUnlocked(for: deviceID)
            }
        }
    }

    func updateProfile(_ profileID: UUID) async throws {
        await waitUntilReady()
        try await withMutationGate {
            guard let index = settings.profiles.firstIndex(where: { $0.id == profileID }) else {
                throw AudioControlStoreError.profileUnavailable
            }
            let existing = settings.profiles[index]
            var updated = makeCurrentProfile(
                name: existing.name,
                id: existing.id,
                scope: existing.scope
            )
            updated.createdAt = existing.createdAt
            var desired = settings
            desired.profiles[index] = updated.normalized
            if updated.scope.isGlobal {
                AudioProfileContextPlanner.setActiveProfiles(
                    globalID: nil,
                    localID: desired.activeLocalProfileID,
                    in: &desired
                )
            } else {
                AudioProfileContextPlanner.setActiveProfiles(
                    globalID: desired.activeGlobalProfileID,
                    localID: profileID,
                    in: &desired
                )
            }
            try await commitSettings(
                desired,
                previous: settings,
                issueID: "profile-update-\(profileID.uuidString)"
            )
        }
    }

    func deleteProfile(_ profileID: UUID) async throws {
        await waitUntilReady()
        try await withMutationGate {
            guard settings.profiles.contains(where: { $0.id == profileID }) else {
                throw AudioControlStoreError.profileUnavailable
            }
            var desired = settings
            desired.profiles.removeAll { $0.id == profileID }
            if desired.activeGlobalProfileID == profileID {
                desired.activeGlobalProfileID = nil
            }
            if desired.activeLocalProfileID == profileID {
                desired.activeLocalProfileID = nil
            }
            AudioProfileContextPlanner.setActiveProfiles(
                globalID: desired.activeGlobalProfileID,
                localID: desired.activeLocalProfileID,
                in: &desired
            )
            try await commitSettings(
                desired,
                previous: settings,
                issueID: "profile-delete-\(profileID.uuidString)"
            )
        }
    }

    func applyProfile(_ profileID: UUID) async throws {
        await waitUntilReady()
        guard let profile = settings.profiles.first(where: { $0.id == profileID }) else {
            throw AudioControlStoreError.profileUnavailable
        }
        if profile.scope.isGlobal {
            guard let output = currentOutput else {
                throw AudioControlStoreError.outputDeviceUnavailable("default output")
            }
            _ = try await assignPreset(
                profileID,
                toOutput: output.id,
                deviceName: output.name
            )
            return
        }
        try await withMutationGate {
            try await applyProfileLayersUnlocked(
                globalProfileID: nil,
                localProfileID: profile.id,
                selectLocalOutput: true,
                observedOutputDeviceID: profile.scope.outputDeviceID,
                reason: "manual-\(profileID.uuidString)"
            )
        }
    }

    func revertProfileChanges() async throws {
        await waitUntilReady()
        try await withMutationGate {
            guard settings.profileHasOverrides else { return }
            let currentOutputID = devices.first(where: \.isDefault)?.id
            let localID = activeLocalProfile.flatMap {
                $0.scope.outputDeviceID == currentOutputID ? $0.id : nil
            } ?? automaticLocalProfile(for: currentOutputID)?.id
            try await applyProfileLayersUnlocked(
                globalProfileID: settings.activeGlobalProfileID,
                localProfileID: localID,
                selectLocalOutput: false,
                observedOutputDeviceID: currentOutputID,
                reason: "revert-overrides"
            )
        }
    }

    private func applyAutomaticProfilesUnlocked(for outputDeviceID: String) async throws {
        let localID = automaticLocalProfile(for: outputDeviceID)?.id
        do {
            try await applyProfileLayersUnlocked(
                // Presets are copied into a device context, never retained as
                // a live layer shared by multiple physical outputs.
                globalProfileID: nil,
                localProfileID: localID,
                selectLocalOutput: false,
                observedOutputDeviceID: outputDeviceID,
                reason: "output-\(outputDeviceID)"
            )
        } catch {
            // A refresh is the recovery action for automatic profile failures.
            // Leave the topology unsynchronized so an unchanged output is
            // retried instead of being mistaken for an already-applied state.
            lastObservedDefaultOutputDeviceID = nil
            lastAvailableOutputDeviceIDs = []
            throw error
        }
    }

    private func applyProfileLayersUnlocked(
        globalProfileID: UUID?,
        localProfileID: UUID?,
        selectLocalOutput: Bool,
        observedOutputDeviceID: String?,
        reason: String
    ) async throws {
        let globalProfile = settings.profiles.first {
            $0.id == globalProfileID && $0.scope.isGlobal
        }
        let localProfile = settings.profiles.first {
            $0.id == localProfileID && !$0.scope.isGlobal
        }
        let profiles = [globalProfile, localProfile].compactMap { $0 }
        let previous = settings
        var desired = previous
        var effectiveAppSettings = profiles.isEmpty
            ? [:]
            : AudioProfile.flatAppSettings(
                from: settings.appSettings,
                customization: settings.customization
            )
        var effectiveDeviceSettings: [String: DeviceAudioSettings] = [:]
        for profile in profiles {
            for (identity, appSettings) in profile.appSettings {
                effectiveAppSettings[identity] = appSettings.normalized
            }
            for (deviceUID, deviceSettings) in profile.deviceSettings {
                effectiveDeviceSettings[deviceUID] = deviceSettings.normalized
            }
        }
        for (identity, appSettings) in effectiveAppSettings {
            desired.appSettings[identity] = appSettings
        }
        for (deviceUID, deviceSettings) in effectiveDeviceSettings {
            desired.deviceSettings[deviceUID] = deviceSettings
        }
        if let observedOutputDeviceID {
            desired.preferredOutputDeviceID = observedOutputDeviceID
        }
        AudioProfileContextPlanner.setActiveProfiles(
            globalID: globalProfile?.id,
            localID: localProfile?.id,
            in: &desired
        )

        let activeAppIDs = Set(appSnapshots.map(\.identity))
        let changedAppIDs = effectiveAppSettings.keys.filter { identity in
            activeAppIDs.contains(identity)
                && previous.appSettings[identity] != effectiveAppSettings[identity]
        }
        let desiredAppCommands = changedAppIDs
            .compactMap { identity in effectiveAppSettings[identity].map { (identity, $0) } }
            .flatMap { Self.profileCommands(for: $0.0, settings: $0.1) }
        let previousAppCommands = changedAppIDs
            .compactMap { identity in previous.appSettings[identity].map { (identity, $0) } }
            .flatMap { Self.profileCommands(for: $0.0, settings: $0.1) }
        let desiredDeviceApplications = makeDeviceApplications(from: effectiveDeviceSettings)
        let previousDeviceApplications = makeCurrentDeviceApplications(
            for: Set(effectiveDeviceSettings.keys)
        )
        let availableDeviceIDs = Set(devices.map(\.id))
        let localOutputID = localProfile?.scope.outputDeviceID
        let desiredDefault = selectLocalOutput
            ? localOutputID.flatMap { availableDeviceIDs.contains($0) ? $0 : nil }
            : nil
        let previousDefault = devices.first(where: \.isDefault)?.id

        try await performSettingsTransaction(
            previous: settings,
            desired: desired,
            issueID: "profile-apply-\(reason)",
            engineDomain: .backend,
            app: nil,
            engineWork: { [engine] in
                if let desiredDefault {
                    try await engine.setDefaultOutputDevice(forUID: desiredDefault)
                }
                for application in desiredDeviceApplications {
                    if let volume = application.volume {
                        try await engine.setOutputVolume(volume, forUID: application.deviceUID)
                    }
                    if let isMuted = application.isMuted {
                        try await engine.setOutputMuted(isMuted, forUID: application.deviceUID)
                    }
                    try await engine.apply(.setOutputEQ(application.deviceUID, application.eq))
                }
                try await engine.apply(desiredAppCommands)
            },
            finalize: { _ in },
            compensate: { [engine] _ in
                if let previousDefault, desiredDefault != nil {
                    try await engine.setDefaultOutputDevice(forUID: previousDefault)
                }
                for application in previousDeviceApplications {
                    if let volume = application.volume {
                        try await engine.setOutputVolume(volume, forUID: application.deviceUID)
                    }
                    if let isMuted = application.isMuted {
                        try await engine.setOutputMuted(isMuted, forUID: application.deviceUID)
                    }
                    try await engine.apply(.setOutputEQ(application.deviceUID, application.eq))
                }
                try await engine.apply(previousAppCommands)
            }
        )

        for application in desiredDeviceApplications {
            if let volume = application.volume {
                deviceVolumeStates[application.deviceUID]?.volume = volume
            }
            if let isMuted = application.isMuted {
                deviceVolumeStates[application.deviceUID]?.isMuted = isMuted
            }
        }
        if let desiredDefault {
            devices = devices.map {
                AudioDeviceSnapshot(id: $0.id, name: $0.name, isDefault: $0.id == desiredDefault)
            }
            lastObservedDefaultOutputDeviceID = desiredDefault
        }
        rebuildDisplayRows()
        InternalDiagnostics.record(
            "audio",
            "profiles.applied global=\(globalProfile?.id.uuidString ?? "none") "
                + "local=\(localProfile?.id.uuidString ?? "none") reason=\(reason)"
        )
    }

    private func automaticLocalProfile(for outputDeviceID: String?) -> AudioProfile? {
        guard let outputDeviceID else { return nil }
        return outputConfiguration(for: outputDeviceID)
    }

    private func makeCurrentProfile(
        name: String,
        id: UUID = UUID(),
        scope: AudioProfileScope
    ) -> AudioProfile {
        let normalizedScope = scope.normalized
        let fallbackOutputID = normalizedScope.outputDeviceID ?? currentOutput?.id
        var capturedIDs = AudioProfileContextPlanner.referencedOutputDeviceIDs(
            in: settings.appSettings,
            followDefaultOutputID: fallbackOutputID
        )
        if let outputID = normalizedScope.outputDeviceID {
            capturedIDs.insert(outputID)
        }
        let allCapturedDevices = capturedDeviceSettings()
        let capturedDevices = allCapturedDevices.filter {
            capturedIDs.contains($0.key)
        }
        return AudioProfile(
            id: id,
            name: name,
            scope: normalizedScope,
            activatesAutomatically: !normalizedScope.isGlobal,
            appSettings: settings.appSettings,
            deviceSettings: capturedDevices,
            preferredOutputDeviceID: normalizedScope.outputDeviceID,
            updatedAt: Date()
        )
    }

    private func capturedDeviceSettings() -> [String: DeviceAudioSettings] {
        var captured = settings.deviceSettings
        for device in devices {
            guard let state = deviceVolumeStates[device.id] else { continue }
            captured[device.id] = preservedDeviceSettings(
                deviceUID: device.id,
                displayName: device.name,
                volume: state.volume,
                isMuted: state.isMuted
            )
        }
        return captured
    }

    private func preservedDeviceSettings(
        deviceUID: String,
        displayName: String,
        volume: Double,
        isMuted: Bool,
        eq: EQCurve? = nil
    ) -> DeviceAudioSettings {
        DeviceAudioSettings(
            displayName: displayName,
            volume: volume,
            isMuted: isMuted,
            eq: eq
                ?? settings.deviceSettings[deviceUID]?.eq
                ?? EQCurve(range: settings.customization.eqGainRange)
        )
    }

    private func makeDeviceApplications(
        from desired: [String: DeviceAudioSettings]
    ) -> [DeviceSettingsApplication] {
        desired.compactMap { deviceUID, settings in
            guard devices.contains(where: { $0.id == deviceUID }) else { return nil }
            let state = deviceVolumeStates[deviceUID]
            return DeviceSettingsApplication(
                deviceUID: deviceUID,
                volume: state?.capabilities.canSetVolume == true ? settings.volume : nil,
                isMuted: state?.capabilities.canSetMute == true ? settings.isMuted : nil,
                eq: settings.eq
            )
        }
    }

    private func makeCurrentDeviceApplications(
        for deviceUIDs: Set<String>
    ) -> [DeviceSettingsApplication] {
        deviceUIDs.compactMap { deviceUID in
            guard devices.contains(where: { $0.id == deviceUID }) else { return nil }
            let state = deviceVolumeStates[deviceUID]
            return DeviceSettingsApplication(
                deviceUID: deviceUID,
                volume: state?.capabilities.canSetVolume == true ? state?.volume : nil,
                isMuted: state?.capabilities.canSetMute == true ? state?.isMuted : nil,
                eq: settings.deviceSettings[deviceUID]?.eq
                    ?? EQCurve(range: settings.customization.eqGainRange)
            )
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
            try await commitSettings(
                desired,
                previous: settings,
                issueID: "pin-\(identity.rawValue)",
                app: identity
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
            try await performIgnoredSetTransaction(
                previous: previous,
                desired: desired,
                issueID: "ignore-\(identity.rawValue)",
                app: identity,
                tearDownIdentity: identity
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
        app: AudioAppIdentity?,
        tearDownIdentity: AudioAppIdentity? = nil
    ) async throws {
        let active = Set(appSnapshots.map(\.identity))
        let allowsTaps = permissionState.allowsProcessTaps
        try await performSettingsTransaction(
            previous: settings,
            desired: desired,
            issueID: issueID,
            engineDomain: .tap,
            app: app,
            engineWork: { [engine] in
                if let tearDownIdentity {
                    try await engine.tearDownTap(for: tearDownIdentity)
                }
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
        try await mutateAppSetting(identity, kind: .volume) { $0.setVolume(volume) }
    }

    func setMuted(_ muted: Bool, for identity: AudioAppIdentity) async throws {
        try await mutateAppSetting(identity, kind: .mute) { $0.isMuted = muted }
    }

    func setBoost(_ boost: BoostLevel, for identity: AudioAppIdentity) async throws {
        try await mutateAppSetting(identity, kind: .boost) { $0.boost = boost }
    }

    func setEQGain(_ gain: Double, band: Int, for identity: AudioAppIdentity) async throws {
        try await mutateAppSetting(identity, kind: .eq) { $0.eq.setGain(gain, at: band) }
    }

    func setEQ(_ curve: EQCurve, for identity: AudioAppIdentity) async throws {
        try await mutateAppSetting(identity, kind: .eq) { settings in
            for (band, gain) in curve.gains.enumerated() {
                settings.eq.setGain(gain, at: band)
            }
        }
    }

    func resetEQ(for identity: AudioAppIdentity) async throws {
        try await mutateAppSetting(identity, kind: .eq) { $0.eq.reset() }
    }

    func setOutputEQGain(
        _ gain: Double,
        band: Int,
        for deviceUID: String
    ) async throws {
        try await mutateOutputEQ(deviceUID: deviceUID) {
            $0.setGain(gain, at: band)
        }
    }

    func setOutputEQ(_ curve: EQCurve, for deviceUID: String) async throws {
        try await mutateOutputEQ(deviceUID: deviceUID) { outputEQ in
            for (band, gain) in curve.gains.enumerated() {
                outputEQ.setGain(gain, at: band)
            }
        }
    }

    func resetOutputEQ(for deviceUID: String) async throws {
        try await mutateOutputEQ(deviceUID: deviceUID) { $0.reset() }
    }

    private func mutateOutputEQ(
        deviceUID: String,
        mutation: (inout EQCurve) -> Void
    ) async throws {
        await waitUntilReady()
        try await withMutationGate {
            guard let device = devices.first(where: { $0.id == deviceUID }) else {
                throw AudioControlStoreError.outputDeviceUnavailable(deviceUID)
            }
            let previous = settings
            var desired = previous
            let state = deviceVolumeStates[deviceUID]
                ?? OutputVolumeState(deviceName: device.name)
            let baselineCurve = previous.deviceSettings[deviceUID]?.eq
                ?? EQCurve(range: previous.customization.eqGainRange)
            var curve = baselineCurve
            mutation(&curve)
            curve.applyRange(desired.customization.eqGainRange)
            desired.deviceSettings[deviceUID] = preservedDeviceSettings(
                deviceUID: deviceUID,
                displayName: device.name,
                volume: desired.deviceSettings[deviceUID]?.volume ?? state.volume,
                isMuted: desired.deviceSettings[deviceUID]?.isMuted ?? state.isMuted,
                eq: curve
            )
            AudioProfileContextPlanner.updateActiveDeviceContext(
                in: &desired,
                currentOutputID: currentOutput?.id,
                changedDeviceID: deviceUID
            )
            try await performSettingsTransaction(
                previous: previous,
                desired: desired,
                issueID: "output-eq-\(deviceUID)",
                engineDomain: .backend,
                app: nil,
                engineWork: { [engine] in
                    try await engine.apply(.setOutputEQ(deviceUID, curve))
                },
                finalize: { _ in },
                compensate: { [engine] _ in
                    try await engine.apply(.setOutputEQ(deviceUID, baselineCurve))
                }
            )
        }
    }

    private func mutateLiveOutputEQ(
        deviceUID: String,
        mutation: (inout EQCurve) -> Void
    ) {
        guard let device = devices.first(where: { $0.id == deviceUID }) else { return }
        let state = deviceVolumeStates[deviceUID]
            ?? OutputVolumeState(deviceName: device.name)
        var curve = settings.deviceSettings[deviceUID]?.eq
            ?? EQCurve(range: settings.customization.eqGainRange)
        mutation(&curve)
        settings.deviceSettings[deviceUID] = preservedDeviceSettings(
            deviceUID: deviceUID,
            displayName: device.name,
            volume: settings.deviceSettings[deviceUID]?.volume ?? state.volume,
            isMuted: settings.deviceSettings[deviceUID]?.isMuted ?? state.isMuted,
            eq: curve
        )
        AudioProfileContextPlanner.updateActiveDeviceContext(
            in: &settings,
            currentOutputID: currentOutput?.id,
            changedDeviceID: deviceUID
        )
        rebuildDisplayRows()
    }

    func setRoute(_ route: DeviceRoute, for identity: AudioAppIdentity) async throws {
        try await mutateAppSetting(identity, kind: .route) { $0.route = route.normalized }
    }

    func setAllActiveAppsMuted(_ muted: Bool) async throws {
        try await mutateAllActiveApps(issueID: "all-apps-mute") { settings in
            settings.isMuted = muted
        }
    }

    func setAllActiveAppsVolume(_ volume: Double) async throws {
        let clamped = min(max(volume.isFinite ? volume : 1, 0), 1)
        try await mutateAllActiveApps(issueID: "all-apps-volume") { settings in
            settings.setVolume(clamped)
        }
    }

    private func mutateAllActiveApps(
        issueID: String,
        mutation: (inout AppAudioSettings) -> Void
    ) async throws {
        await waitUntilReady()
        try await withMutationGate {
            let activeIDs = Set(appSnapshots.filter(\.isActive).map(\.identity))
            guard !activeIDs.isEmpty else { return }
            let previous = settings
            var desired = previous
            for identity in activeIDs {
                ensureSettings(for: identity, in: &desired)
                guard var appSettings = desired.appSettings[identity] else { continue }
                mutation(&appSettings)
                desired.appSettings[identity] = appSettings.normalized
            }
            AudioProfileContextPlanner.updateActiveDeviceContext(
                in: &desired,
                currentOutputID: currentOutput?.id
            )
            let desiredCommands = activeIDs.compactMap { identity in
                desired.appSettings[identity].map { (identity, $0) }
            }.flatMap { Self.profileCommands(for: $0.0, settings: $0.1) }
            let previousCommands = activeIDs.compactMap { identity in
                previous.appSettings[identity].map { (identity, $0) }
            }.flatMap { Self.profileCommands(for: $0.0, settings: $0.1) }
            try await performSettingsTransaction(
                previous: previous,
                desired: desired,
                issueID: issueID,
                engineDomain: .backend,
                app: nil,
                engineWork: { [engine] in try await engine.apply(desiredCommands) },
                finalize: { _ in },
                compensate: { [engine] _ in try await engine.apply(previousCommands) }
            )
        }
    }

    private func mutateAppSetting(
        _ identity: AudioAppIdentity,
        kind: AppSettingMutationKind,
        mutation: (inout AppAudioSettings) -> Void
    ) async throws {
        await waitUntilReady()
        try await withMutationGate {
            let previous = settings
            var desired = previous
            ensureSettings(for: identity, in: &desired)
            guard var desiredApp = desired.appSettings[identity] else {
                throw AudioControlStoreError.appUnavailable(identity.rawValue)
            }
            let previousApp = previous.appSettings[identity] ?? desiredApp
            mutation(&desiredApp)
            desiredApp = desiredApp.normalized
            desired.appSettings[identity] = desiredApp
            AudioProfileContextPlanner.updateActiveDeviceContext(
                in: &desired,
                currentOutputID: currentOutput?.id
            )
            let commands = kind.commands(for: identity, settings: desiredApp)
            let compensation = kind.commands(for: identity, settings: previousApp)
            try await performSettingsTransaction(
                previous: settings,
                desired: desired,
                issueID: "\(kind.issueName)-\(identity.rawValue)",
                engineDomain: kind.issueDomain,
                app: identity,
                engineWork: { [engine] in try await engine.apply(commands) },
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
            try await commitSettings(
                desired,
                previous: settings,
                issueID: "app-order",
                app: identity
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
                for deviceUID in desired.deviceSettings.keys {
                    desired.deviceSettings[deviceUID]?.eq.applyRange(normalized.eqGainRange)
                }
                for profileIndex in desired.profiles.indices {
                    for identity in desired.profiles[profileIndex].appSettings.keys {
                        desired.profiles[profileIndex].appSettings[identity]?.eq.applyRange(
                            normalized.eqGainRange
                        )
                    }
                    for deviceUID in desired.profiles[profileIndex].deviceSettings.keys {
                        desired.profiles[profileIndex].deviceSettings[deviceUID]?.eq.applyRange(
                            normalized.eqGainRange
                        )
                    }
                }
            }
            let desiredEQ = rangeChanged
                ? desired.appSettings.compactMap { identity, value in AudioBackendCommand.setEQ(identity, value.eq) }
                    + desired.deviceSettings.map { uid, value in
                        AudioBackendCommand.setOutputEQ(uid, value.eq)
                    }
                : []
            let previousEQ = rangeChanged
                ? previous.appSettings.compactMap { identity, value in AudioBackendCommand.setEQ(identity, value.eq) }
                    + previous.deviceSettings.map { uid, value in
                        AudioBackendCommand.setOutputEQ(uid, value.eq)
                    }
                : []

            try await performSettingsTransaction(
                previous: settings,
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
                previous: settings,
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
            try await commitSettings(desired, previous: settings, issueID: "onboarding")
        }
    }

    private func commitSettings(
        _ desired: PersistedSettings,
        previous baseline: PersistedSettings,
        issueID: String,
        app: AudioAppIdentity? = nil
    ) async throws {
        try await performSettingsTransaction(
            previous: baseline,
            desired: desired,
            issueID: issueID,
            engineDomain: .backend,
            app: app,
            engineWork: { () },
            finalize: { _ in },
            compensate: { _ in }
        )
    }

    private func performSettingsTransaction<Receipt: Sendable>(
        previous: PersistedSettings,
        desired: PersistedSettings,
        issueID: String,
        engineDomain: AudioIssueDomain,
        app: AudioAppIdentity?,
        engineWork: @escaping () async throws -> Receipt,
        finalize: @escaping (Receipt) async throws -> Void,
        compensate: @escaping (Receipt?) async throws -> Void
    ) async throws {
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
        debounceNanoseconds: UInt64 = 33_333_333
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
                        previous: baseline,
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
                } catch {
                    try? await engine.apply(compensation)
                    settings = baseline
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

    private func scheduleOutputEQEditPreview(
        _ key: OutputEQEditSessionKey,
        debounceNanoseconds: UInt64 = 33_333_333
    ) {
        outputEQEditTasks[key]?.cancel()
        outputEQEditTasks[key] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: debounceNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            try? await flushOutputEQEditSession(key, isFinal: false)
        }
    }

    private func flushOutputEQEditSession(
        _ key: OutputEQEditSessionKey,
        isFinal: Bool
    ) async throws {
        await waitUntilReady()
        try await withMutationGate {
            guard let baseline = outputEQEditSessions[key] else { return }
            let currentEQ = settings.deviceSettings[key.deviceUID]?.eq
                ?? EQCurve(range: settings.customization.eqGainRange)
            let baselineEQ = baseline.deviceSettings[key.deviceUID]?.eq
                ?? EQCurve(range: baseline.customization.eqGainRange)
            let desiredCommand = AudioBackendCommand.setOutputEQ(
                key.deviceUID,
                currentEQ
            )
            let compensation = AudioBackendCommand.setOutputEQ(
                key.deviceUID,
                baselineEQ
            )

            if isFinal {
                do {
                    try await performSettingsTransaction(
                        previous: baseline,
                        desired: settings,
                        issueID: "edit-output-eq-\(key.deviceUID)-\(key.gestureToken.uuidString)",
                        engineDomain: .backend,
                        app: nil,
                        engineWork: { [engine] in
                            try await engine.apply(desiredCommand)
                        },
                        finalize: { _ in },
                        compensate: { [engine] _ in
                            try await engine.apply(compensation)
                        }
                    )
                } catch {
                    removeOutputEQEditSession(key)
                    throw error
                }
                removeOutputEQEditSession(key)
            } else {
                do {
                    try await engine.apply(desiredCommand)
                } catch {
                    try? await engine.apply(compensation)
                    settings = baseline
                    rebuildDisplayRows()
                    removeOutputEQEditSession(key)
                    reportMutationFailure(
                        error,
                        id: "edit-output-eq-\(key.deviceUID)",
                        domain: .backend,
                        device: key.deviceUID
                    )
                    throw error
                }
            }
        }
    }

    private func removeOutputEQEditSession(_ key: OutputEQEditSessionKey) {
        outputEQEditTasks[key]?.cancel()
        outputEQEditTasks[key] = nil
        outputEQEditSessions[key] = nil
        activeOutputEQEditKeys[
            OutputEQEditLookup(deviceUID: key.deviceUID, band: key.band)
        ] = nil
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
        // Synchronously enter shutting-down before rejecting new commands.
        storePhase = .shuttingDown
        await mutationGate.cancelAll()

        // Intent/edit tasks first after external controls/widget (caller order).
        for task in intentTasks.values { task.cancel() }
        await waitForPendingOperations()

        var editErrors: [String] = []
        let keys = Array(editSessions.keys)
        for key in keys {
            editTasks[key]?.cancel()
            do { try await flushEditSession(key, isFinal: true) }
            catch { editErrors.append(error.localizedDescription) }
        }
        let outputEQKeys = Array(outputEQEditSessions.keys)
        for key in outputEQKeys {
            outputEQEditTasks[key]?.cancel()
            do {
                try await flushOutputEQEditSession(key, isFinal: true)
            } catch {
                editErrors.append(error.localizedDescription)
            }
        }
        // Stop the main-actor consumers now; let engine.shutdown() stop and
        // report its owned HAL/output/meter observations as one operation.
        cancelObservationConsumers()

        let persistenceError: String?
        do {
            try await persistence.flush()
            persistenceError = nil
            if healthInputs.persistenceState != .writeBlocked {
                healthInputs.persistenceState = .clean
            }
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
                recovery: .refreshAudio
            )
        }
        storePhase = .stopped
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
            return StableDisplayOrder.precedes(
                lhsName: lhs.displayName,
                lhsID: lhs.identity.rawValue,
                rhsName: rhs.displayName,
                rhsID: rhs.identity.rawValue
            )
        }
        channels.reconcile(
            rows: displayRows,
            devices: devices,
            volumes: deviceVolumeStates,
            deviceSettings: settings.deviceSettings
        )
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

    private static func profileCommands(
        for identity: AudioAppIdentity,
        settings: AppAudioSettings
    ) -> [AudioBackendCommand] {
        [
            .setRoute(identity, settings.route.normalized),
            .setVolume(identity, settings.volume),
            .setMuted(identity, settings.isMuted),
            .setBoost(identity, settings.boost),
            .setEQ(identity, settings.eq)
        ]
    }

    // MARK: - Coordination helpers and issues

    private func withMutationGate<Value>(_ operation: () async throws -> Value) async throws -> Value {
        try await mutationGate.acquire()
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
        guard storePhase != .shuttingDown, storePhase != .stopped, completedShutdownReport == nil else { return }
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
        let failure = UserFacingFailure.from(error, title: "Couldn’t apply change")
        let message = "Couldn’t apply change: \(failure.message)"
        healthInputs.backendFaults = [message]
        publishHealth()
        reportIssue(
            id: id,
            domain: domain,
            message: message,
            severity: .error,
            app: app,
            device: device,
            recovery: .tryControlAgain
        )
    }

    private func reportPersistenceFailure(
        _ error: Error,
        id: String,
        app: AudioAppIdentity? = nil
    ) {
        let failure = UserFacingFailure.from(error, title: "Couldn’t save settings")
        let message = "Couldn’t save settings: \(failure.message)"
        healthInputs.persistenceState = .failed
        healthInputs.persistenceMessage = message
        publishHealth()
        reportIssue(
            id: id,
            domain: .persistence,
            message: message,
            severity: .error,
            app: app,
            recovery: .refreshAudio
        )
    }

    private func publishHealth() {
        healthInputs.visibleAppCount = displayRows.count
        healthInputs.permissionAllowsTaps = permissionState.allowsProcessTaps
        let reduced = AudioHealthReducer.reduce(healthInputs)
        healthSnapshot = reduced
        mixerPhase = reduced.phase
        // Operation state is a view projection; health inputs remain authoritative.
        operationState = reduced.operationState
        // Merge reducer issues with ad-hoc operational issues (keep non-overlapping ids).
        let reducedIDs = Set(reduced.issues.map(\.id))
        let retained = issues.filter { !reducedIDs.contains($0.id) && !Self.healthManagedIssueIDs.contains($0.id) }
        issues = reduced.issues + retained
    }

    private static let healthManagedIssueIDs: Set<String> = [
        "audio-permission",
        "refresh",
        "settings-persistence",
        "widget-fault",
    ]

    private func project(_ command: ControlCommand) throws -> ControlProjectedState {
        let committed = try ControlProjection.committed(
            for: command.target,
            displayRows: displayRows,
            settings: settings,
            devices: devices,
            deviceVolumeStates: deviceVolumeStates
        )
        return try ControlProjection.applying(
            command.mutation,
            to: committed,
            target: command.target
        )
    }

    private func executeControl(
        _ command: ControlCommand,
        projected: ControlProjectedState
    ) async -> ControlResult {
        do {
            switch (command.target, command.mutation) {
            case let (.app(identity), .adjustVolume):
                guard let volume = projected.volume,
                      let muted = projected.isMuted else {
                    return .rejected(UserFacingFailure(title: "Unavailable", message: "Volume is unavailable."))
                }
                try await mutateAppSetting(identity, kind: .volumeAndMute) {
                    $0.setVolume(volume)
                    $0.isMuted = muted
                }
            case let (.app(identity), .setVolume):
                guard let volume = projected.volume else {
                    return .rejected(UserFacingFailure(title: "Unavailable", message: "Volume is unavailable."))
                }
                try await setVolume(volume, for: identity)
            case let (.app(identity), .toggleMute), let (.app(identity), .setMuted):
                guard let muted = projected.isMuted else {
                    return .rejected(UserFacingFailure(title: "Unavailable", message: "Mute is unavailable."))
                }
                try await setMuted(muted, for: identity)
            case let (.app(identity), .setBoost(boost)):
                try await setBoost(boost, for: identity)
            case let (.app(identity), .setEQ(eq)):
                try await setEQ(eq, for: identity)
            case let (.app(identity), .setEQBand(band, gain)):
                try await setEQGain(gain, band: band, for: identity)
            case let (.app(identity), .setRoute(route)):
                try await setRoute(route, for: identity)
            case let (.outputDevice(deviceID), .adjustVolume), let (.outputDevice(deviceID), .setVolume):
                guard let volume = projected.volume else {
                    return .rejected(UserFacingFailure(title: "Unavailable", message: "Output volume is unavailable."))
                }
                try await setDeviceVolume(volume, for: deviceID)
            case let (.outputDevice(deviceID), .toggleMute), let (.outputDevice(deviceID), .setMuted):
                guard let muted = projected.isMuted else {
                    return .rejected(UserFacingFailure(title: "Unavailable", message: "Output mute is unavailable."))
                }
                try await setDeviceMuted(muted, for: deviceID)
            case let (.outputDevice(deviceID), .setEQ(eq)):
                try await setOutputEQ(eq, for: deviceID)
            case let (.outputDevice(deviceID), .setEQBand(band, gain)):
                try await setOutputEQGain(gain, band: band, for: deviceID)
            case (.activeApps, .setMuted(let muted)):
                try await setAllActiveAppsMuted(muted)
            case (.activeApps, .setVolume(let volume)):
                try await setAllActiveAppsVolume(volume)
            default:
                return .rejected(
                    UserFacingFailure(
                        title: "Unsupported",
                        message: "Try that control again from the mixer."
                    )
                )
            }
            return .applied(projected)
        } catch {
            return .rejected(UserFacingFailure.from(error))
        }
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
