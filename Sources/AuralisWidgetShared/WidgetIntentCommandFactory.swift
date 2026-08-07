import Foundation

/// Pure mapping shared by WidgetKit intents and the host test suite. Keeping
/// intent validation here makes every button produce the same versioned wire
/// command that the host validates and acknowledges.
public enum WidgetIntentCommandFactory {
    public static func setAppMuted(
        appID: String,
        muted: Bool,
        now: Date = Date()
    ) -> WidgetCommand? {
        appCommand(appID: appID, action: .setMuted(muted), now: now)
    }

    public static func setAppVolume(
        appID: String,
        volume: Double,
        now: Date = Date()
    ) -> WidgetCommand? {
        appCommand(appID: appID, action: .setVolume(volume), now: now)
    }

    public static func setAppBoost(
        appID: String,
        boost: Double,
        now: Date = Date()
    ) -> WidgetCommand? {
        appCommand(appID: appID, action: .setBoost(boost), now: now)
    }

    public static func setEQBandGain(
        appID: String,
        band: Int,
        gain: Double,
        now: Date = Date()
    ) -> WidgetCommand? {
        guard (0..<WidgetWireNormalization.bandCount).contains(band) else { return nil }
        return appCommand(
            appID: appID,
            action: .setEQBandGain(band: band, gain: gain),
            now: now
        )
    }

    public static func setOutputDeviceMuted(
        deviceID: String,
        muted: Bool,
        now: Date = Date()
    ) -> WidgetCommand? {
        guard !deviceID.isEmpty else { return nil }
        return validated(.outputDevice(identity: deviceID, muted: muted, createdAt: now), now: now)
    }

    public static func setOutputDeviceVolume(
        deviceID: String,
        volume: Double,
        now: Date = Date()
    ) -> WidgetCommand? {
        guard !deviceID.isEmpty else { return nil }
        return validated(
            .outputDeviceVolume(identity: deviceID, volume: volume, createdAt: now),
            now: now
        )
    }

    public static func selectOutputDevice(
        deviceID: String,
        now: Date = Date()
    ) -> WidgetCommand? {
        guard !deviceID.isEmpty else { return nil }
        return validated(.selectOutputDevice(identity: deviceID, createdAt: now), now: now)
    }

    public static func applyProfile(
        profileID: String,
        now: Date = Date()
    ) -> WidgetCommand? {
        guard UUID(uuidString: profileID) != nil else { return nil }
        return validated(.applyProfile(identity: profileID, createdAt: now), now: now)
    }

    public static func assignProfileToCurrentOutput(
        profileID: String,
        now: Date = Date()
    ) -> WidgetCommand? {
        guard UUID(uuidString: profileID) != nil else { return nil }
        return validated(
            .assignProfileToCurrentOutput(identity: profileID, createdAt: now),
            now: now
        )
    }

    public static func refresh(now: Date = Date()) -> WidgetCommand {
        .refresh(createdAt: now)
    }

    public static func setAllAppsMuted(
        _ muted: Bool,
        now: Date = Date()
    ) -> WidgetCommand {
        .setAllAppsMuted(muted: muted, createdAt: now)
    }

    public static func setAllAppsVolume(
        _ volume: Double,
        now: Date = Date()
    ) -> WidgetCommand? {
        validated(.setAllAppsVolume(volume: volume, createdAt: now), now: now)
    }

    public static func revertProfileChanges(now: Date = Date()) -> WidgetCommand {
        .revertProfileChanges(createdAt: now)
    }

    private static func appCommand(
        appID: String,
        action: WidgetCommandAction,
        now: Date
    ) -> WidgetCommand? {
        guard !appID.isEmpty else { return nil }
        return validated(.app(identity: appID, action: action, createdAt: now), now: now)
    }

    private static func validated(_ command: WidgetCommand, now: Date) -> WidgetCommand? {
        guard (try? command.validate(now: now)) != nil else { return nil }
        return command
    }
}
