import AppIntents
import AuralisWidgetShared
import Foundation

private enum WidgetIntentError: LocalizedError {
    case hostUnavailable
    case commandNotPublished

    var errorDescription: String? {
        switch self {
        case .hostUnavailable:
            "Open Auralis before using widget controls."
        case .commandNotPublished:
            "Auralis could not publish the widget command. Try again."
        }
    }
}

private enum WidgetIntentCommandSender {
    static func enqueue(_ command: WidgetCommand) throws {
        guard WidgetSnapshotReader.read().isHostAvailable() else {
            WidgetDiagnostics.error(
                "intent.enqueue rejected=host-unavailable action=\(String(describing: command.action))"
            )
            throw WidgetIntentError.hostUnavailable
        }
        do {
            let published = try WidgetCommandQueue.enqueue(command)
            guard published else {
                WidgetDiagnostics.error(
                    "intent.enqueue rejected=duplicate-id action=\(String(describing: command.action))"
                )
                throw WidgetIntentError.commandNotPublished
            }
            WidgetDiagnostics.record(
                "intent.enqueue action=\(String(describing: command.action)) published=true"
            )
        } catch {
            WidgetDiagnostics.error(
                "intent.enqueue failed action=\(String(describing: command.action)) "
                    + "error=\(error.localizedDescription)"
            )
            throw error
        }
        // The host reloads timelines only after it has published the applied
        // snapshot and durable result acknowledgment.
    }
}

struct SetAppMutedIntent: AppIntent {
    static let title: LocalizedStringResource = "Set App Mute"
    static let description = IntentDescription("Mute or unmute an audio app from the widget.")
    static var isDiscoverable: Bool { false }

    @Parameter(title: "Application Identifier")
    var appID: String

    @Parameter(title: "Muted")
    var muted: Bool

    init() { self.appID = ""; self.muted = false }
    init(appID: String, muted: Bool) { self.appID = appID; self.muted = muted }

    func perform() async throws -> some IntentResult {
        guard let command = WidgetIntentCommandFactory.setAppMuted(appID: appID, muted: muted) else {
            return .result()
        }
        try WidgetIntentCommandSender.enqueue(command)
        return .result()
    }
}

struct SetOutputDeviceMutedIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Output Device Mute"
    static let description = IntentDescription("Mute or unmute a Mac output device from the widget.")
    static var isDiscoverable: Bool { false }

    @Parameter(title: "Output Device Identifier")
    var deviceID: String

    @Parameter(title: "Muted")
    var muted: Bool

    init() { self.deviceID = ""; self.muted = false }
    init(deviceID: String, muted: Bool) { self.deviceID = deviceID; self.muted = muted }

    func perform() async throws -> some IntentResult {
        guard let command = WidgetIntentCommandFactory.setOutputDeviceMuted(deviceID: deviceID, muted: muted) else {
            return .result()
        }
        try WidgetIntentCommandSender.enqueue(command)
        return .result()
    }
}

struct SetBoostAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Set App Boost"
    static let description = IntentDescription("Set an app's audio boost level from the widget.")
    static var isDiscoverable: Bool { false }

    @Parameter(title: "Application Identifier")
    var appID: String

    @Parameter(title: "Boost")
    var boost: Double

    init() { self.appID = ""; self.boost = 1 }
    init(appID: String, boost: Double) { self.appID = appID; self.boost = boost }

    func perform() async throws -> some IntentResult {
        guard let command = WidgetIntentCommandFactory.setAppBoost(appID: appID, boost: boost) else {
            return .result()
        }
        try WidgetIntentCommandSender.enqueue(command)
        return .result()
    }
}

struct SetAppVolumeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set App Volume"
    static let description = IntentDescription("Set an app's volume from the widget.")
    static var isDiscoverable: Bool { false }

    @Parameter(title: "Application Identifier")
    var appID: String

    @Parameter(title: "Volume")
    var volume: Double

    init() { self.appID = ""; self.volume = 1 }
    init(appID: String, volume: Double) { self.appID = appID; self.volume = volume }

    func perform() async throws -> some IntentResult {
        guard let command = WidgetIntentCommandFactory.setAppVolume(appID: appID, volume: volume) else {
            return .result()
        }
        try WidgetIntentCommandSender.enqueue(command)
        return .result()
    }
}

struct SetEQBandGainAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Set EQ Band Gain"
    static let description = IntentDescription("Set one 10-band EQ gain from the widget.")
    static var isDiscoverable: Bool { false }

    @Parameter(title: "Application Identifier")
    var appID: String

    @Parameter(title: "EQ Band")
    var band: Int

    @Parameter(title: "Gain")
    var gain: Double

    init() { self.appID = ""; self.band = 0; self.gain = 0 }
    init(appID: String, band: Int, gain: Double) {
        self.appID = appID; self.band = band; self.gain = gain
    }

    func perform() async throws -> some IntentResult {
        guard let command = WidgetIntentCommandFactory.setEQBandGain(
            appID: appID,
            band: band,
            gain: gain
        ) else { return .result() }
        try WidgetIntentCommandSender.enqueue(command)
        return .result()
    }
}

struct RefreshAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh Audio Apps"
    static let description = IntentDescription("Tell Auralis to rescan audio apps and devices.")

    init() {}

    func perform() async throws -> some IntentResult {
        try WidgetIntentCommandSender.enqueue(WidgetIntentCommandFactory.refresh())
        return .result()
    }
}
