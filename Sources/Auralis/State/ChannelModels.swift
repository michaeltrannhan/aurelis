import Combine
import Foundation

/// Stable per-app channel model. List membership/order publishes separately so
/// changing one app invalidates only that channel and its inspector.
@MainActor
final class AppChannelModel: ObservableObject, Identifiable {
    let id: AudioAppIdentity
    @Published private(set) var displayName: String
    @Published private(set) var isActive: Bool
    @Published private(set) var isPinned: Bool
    @Published private(set) var settings: AppAudioSettings
    @Published private(set) var actionState: ControlActionState = .idle
    @Published private(set) var projectedVolume: Double?
    @Published private(set) var projectedMuted: Bool?

    init(row: DisplayableAppRow) {
        id = row.identity
        displayName = row.displayName
        isActive = row.isActive
        isPinned = row.isPinned
        settings = row.settings
    }

    func apply(row: DisplayableAppRow) {
        if displayName != row.displayName { displayName = row.displayName }
        if isActive != row.isActive { isActive = row.isActive }
        if isPinned != row.isPinned { isPinned = row.isPinned }
        if settings != row.settings { settings = row.settings }
    }

    func apply(actionState: ControlActionState) {
        self.actionState = actionState
        switch actionState {
        case let .pending(projected), let .applied(projected):
            projectedVolume = projected.volume
            projectedMuted = projected.isMuted
        case .idle, .failed:
            projectedVolume = nil
            projectedMuted = nil
        }
    }

    var visibleVolume: Double { projectedVolume ?? settings.volume }
    var visibleMuted: Bool { projectedMuted ?? settings.isMuted }
}

@MainActor
final class OutputChannelModel: ObservableObject, Identifiable {
    let id: String
    @Published private(set) var name: String
    @Published private(set) var isDefault: Bool
    @Published private(set) var volume: Double?
    @Published private(set) var isMuted: Bool?
    @Published private(set) var capabilities: OutputControlCapabilities
    @Published private(set) var eq: EQCurve
    @Published private(set) var actionState: ControlActionState = .idle
    @Published private(set) var projectedVolume: Double?
    @Published private(set) var projectedMuted: Bool?
    @Published private(set) var projectedEQ: EQCurve?

    init(
        device: AudioDeviceSnapshot,
        state: OutputVolumeState?,
        settings: DeviceAudioSettings?
    ) {
        id = device.id
        name = device.name
        isDefault = device.isDefault
        volume = state?.volume
        isMuted = state?.isMuted
        capabilities = state?.capabilities ?? .unavailable
        eq = settings?.eq ?? EQCurve()
    }

    func apply(
        device: AudioDeviceSnapshot,
        state: OutputVolumeState?,
        settings: DeviceAudioSettings?
    ) {
        if name != device.name { name = device.name }
        if isDefault != device.isDefault { isDefault = device.isDefault }
        if volume != state?.volume { volume = state?.volume }
        if isMuted != state?.isMuted { isMuted = state?.isMuted }
        let nextCapabilities = state?.capabilities ?? .unavailable
        if capabilities != nextCapabilities { capabilities = nextCapabilities }
        let nextEQ = settings?.eq ?? EQCurve()
        if eq != nextEQ { eq = nextEQ }
    }

    func apply(actionState: ControlActionState) {
        self.actionState = actionState
        switch actionState {
        case let .pending(projected), let .applied(projected):
            projectedVolume = projected.volume
            projectedMuted = projected.isMuted
            projectedEQ = projected.eq
        case .idle, .failed:
            projectedVolume = nil
            projectedMuted = nil
            projectedEQ = nil
        }
    }

    var visibleVolume: Double { projectedVolume ?? volume ?? 1 }
    var visibleMuted: Bool { projectedMuted ?? isMuted ?? false }
    var visibleEQ: EQCurve { projectedEQ ?? eq }
}

/// Owns channel identity maps and publishes membership/order separately from
/// per-channel mutations.
@MainActor
final class ChannelModelDirectory: ObservableObject {
    @Published private(set) var appOrder: [AudioAppIdentity] = []
    @Published private(set) var outputOrder: [String] = []

    private(set) var apps: [AudioAppIdentity: AppChannelModel] = [:]
    private(set) var outputs: [String: OutputChannelModel] = [:]

    func appModel(for identity: AudioAppIdentity) -> AppChannelModel? {
        apps[identity]
    }

    func outputModel(for deviceID: String) -> OutputChannelModel? {
        outputs[deviceID]
    }

    func reconcile(
        rows: [DisplayableAppRow],
        devices: [AudioDeviceSnapshot],
        volumes: [String: OutputVolumeState],
        deviceSettings: [String: DeviceAudioSettings]
    ) {
        let rowIDs = rows.map(\.identity)
        if appOrder != rowIDs { appOrder = rowIDs }

        var nextApps: [AudioAppIdentity: AppChannelModel] = [:]
        for row in rows {
            if let existing = apps[row.identity] {
                existing.apply(row: row)
                nextApps[row.identity] = existing
            } else {
                nextApps[row.identity] = AppChannelModel(row: row)
            }
        }
        apps = nextApps

        let deviceIDs = devices.map(\.id)
        if outputOrder != deviceIDs { outputOrder = deviceIDs }

        var nextOutputs: [String: OutputChannelModel] = [:]
        for device in devices {
            if let existing = outputs[device.id] {
                existing.apply(
                    device: device,
                    state: volumes[device.id],
                    settings: deviceSettings[device.id]
                )
                nextOutputs[device.id] = existing
            } else {
                nextOutputs[device.id] = OutputChannelModel(
                    device: device,
                    state: volumes[device.id],
                    settings: deviceSettings[device.id]
                )
            }
        }
        outputs = nextOutputs
    }

    func apply(actionStates: [ControlTarget: ControlActionState]) {
        for (target, state) in actionStates {
            switch target {
            case let .app(identity):
                apps[identity]?.apply(actionState: state)
            case let .outputDevice(deviceID):
                outputs[deviceID]?.apply(actionState: state)
            case .activeApps:
                break
            }
        }
    }
}
