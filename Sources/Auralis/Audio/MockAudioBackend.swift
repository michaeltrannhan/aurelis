import Foundation

final class MockAudioBackend: AudioBackend {
    var snapshot: AudioBackendSnapshot
    private(set) var commands: [AudioBackendCommand] = []
    var fetchError: Error?
    var applyError: Error?
    var outputVolume: Double = 0.75
    var outputMuted: Bool = false
    /// Per-device UID volume/mute state for `AudioBackendOutputVolumeControlling`.
    /// Entries not present here fall back to the default `outputVolume`/`outputMuted`.
    var perDeviceVolume: [String: Double] = [:]
    var perDeviceMuted: [String: Bool] = [:]

    init(
        apps: [AudioAppSnapshot] = MockAudioBackend.defaultApps,
        devices: [AudioDeviceSnapshot] = MockAudioBackend.defaultDevices
    ) {
        self.snapshot = AudioBackendSnapshot(apps: apps, devices: devices)
    }

    func fetchSnapshot() throws -> AudioBackendSnapshot {
        if let fetchError { throw fetchError }
        return snapshot
    }

    func apply(_ command: AudioBackendCommand) throws {
        if let applyError { throw applyError }
        commands.append(command)
    }

    static let defaultApps: [AudioAppSnapshot] = [
        AudioAppSnapshot(
            identity: AudioAppIdentity(rawValue: "com.apple.Music"),
            displayName: "Music",
            bundleIdentifier: "com.apple.Music",
            isActive: true,
            level: 0.7
        ),
        AudioAppSnapshot(
            identity: AudioAppIdentity(rawValue: "com.apple.Safari"),
            displayName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            isActive: true,
            level: 0.35
        ),
        AudioAppSnapshot(
            identity: AudioAppIdentity(rawValue: "com.example.Editor"),
            displayName: "Editor",
            bundleIdentifier: "com.example.Editor",
            isActive: false,
            level: 0
        )
    ]

    static let defaultDevices: [AudioDeviceSnapshot] = [
        AudioDeviceSnapshot(id: "default-output", name: "MacBook Speakers", isDefault: true),
        AudioDeviceSnapshot(id: "studio-display", name: "Studio Display")
    ]
}

extension MockAudioBackend: AudioBackendOutputVolumeControlling {
    private func deviceName(forUID uid: String) -> String? {
        snapshot.devices.first(where: { $0.id == uid })?.name
    }

    func readOutputVolume() throws -> OutputVolumeState {
        OutputVolumeState(
            volume: outputVolume,
            isMuted: outputMuted,
            deviceName: "MacBook Speakers",
            capabilities: .controllable
        )
    }

    func readOutputVolume(forUID uid: String) throws -> OutputVolumeState {
        OutputVolumeState(
            volume: perDeviceVolume[uid] ?? outputVolume,
            isMuted: perDeviceMuted[uid] ?? outputMuted,
            deviceName: deviceName(forUID: uid),
            capabilities: .controllable
        )
    }

    func setOutputVolume(_ volume: Double) throws {
        outputVolume = min(max(volume, 0), 1)
    }

    func setOutputVolume(_ volume: Double, forUID uid: String) throws {
        perDeviceVolume[uid] = min(max(volume, 0), 1)
    }

    func setOutputMuted(_ muted: Bool) throws {
        outputMuted = muted
    }

    func setOutputMuted(_ muted: Bool, forUID uid: String) throws {
        perDeviceMuted[uid] = muted
    }

    func startObservingOutputVolume(_ onChange: @escaping @Sendable () -> Void) {
        // No-op for mock backends.
    }

    func stopObservingOutputVolume() {
        // No-op for mock backends.
    }
}
