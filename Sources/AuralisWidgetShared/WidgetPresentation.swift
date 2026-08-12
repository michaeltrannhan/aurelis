import Foundation

/// Deterministic rendering/accessibility inputs consumed by the WidgetKit
/// views. This keeps host-lease, row selection, and spoken control semantics
/// testable without launching the system widget gallery.
public struct WidgetMixerPresentation: Equatable, Sendable {
    public let controlsEnabled: Bool
    public let statusText: String
    public let defaultDevice: WidgetSnapshot.DeviceSummary?
    public let devices: [WidgetSnapshot.DeviceSummary]
    public let apps: [WidgetSnapshot.AppSummary]
    public let globalProfiles: [WidgetSnapshot.ProfileSummary]
    public let localProfiles: [WidgetSnapshot.ProfileSummary]
    public let activeGlobalProfile: WidgetSnapshot.ProfileSummary?
    public let activeLocalProfile: WidgetSnapshot.ProfileSummary?
    public let profileHasOverrides: Bool
    public let hasActiveApps: Bool
    public let activeCountText: String

    public init(
        snapshot: WidgetSnapshot,
        date: Date,
        maximumAppCount: Int
    ) {
        controlsEnabled = snapshot.isHostAvailable(at: date)
        statusText = controlsEnabled ? snapshot.statusMessage : "Open Auralis to use controls"
        let selectedDevice = snapshot.devices.first(where: \.isDefault) ?? snapshot.devices.first
        defaultDevice = selectedDevice
        devices = snapshot.devices
        apps = Array(snapshot.apps.prefix(max(maximumAppCount, 0)))
        globalProfiles = snapshot.profiles.filter { $0.scope == .global }
        localProfiles = snapshot.profiles.filter {
            $0.scope == .outputDevice && $0.outputDeviceID == selectedDevice?.id
        }
        activeGlobalProfile = globalProfiles.first { $0.id == snapshot.activeGlobalProfileID }
        activeLocalProfile = localProfiles.first { $0.id == snapshot.activeLocalProfileID }
        // Device contexts autosave, so the widget has no unsaved override state.
        profileHasOverrides = false
        hasActiveApps = snapshot.activeAppCount > 0
        activeCountText = "\(snapshot.activeAppCount) active"
    }

    public static func muteLabel(name: String, isMuted: Bool) -> String {
        "\(isMuted ? "Unmute" : "Mute") \(name)"
    }

    public static func appValue(_ app: WidgetSnapshot.AppSummary) -> String {
        let percent = Int((app.volume * 100).rounded())
        let mute = app.isMuted ? "muted" : "unmuted"
        return "\(percent) percent volume, \(mute), \(Int(app.boost)) times boost, \(app.routeLabel)"
    }

    public static func volumeLabel(name: String, direction: Int) -> String {
        "\(direction < 0 ? "Decrease" : "Increase") \(name) volume"
    }

    public static func boostLabel(name: String) -> String {
        "Cycle \(name) boost"
    }

    public func isPresetActive(_ preset: WidgetSnapshot.ProfileSummary) -> Bool {
        if let activeLocalProfile {
            return activeLocalProfile.matchingGlobalPresetID == preset.id
        }
        return activeGlobalProfile?.id == preset.id
    }

    public static func outputValue(_ device: WidgetSnapshot.DeviceSummary) -> String {
        let percent = Int((device.volume * 100).rounded())
        return "\(percent) percent volume, \(device.isMuted ? "muted" : "unmuted")"
    }

    public static func eqBandLabel(
        appName: String,
        frequency: String,
        direction: Int
    ) -> String {
        "\(direction < 0 ? "Decrease" : "Increase") \(appName) \(frequency) hertz gain"
    }
}
