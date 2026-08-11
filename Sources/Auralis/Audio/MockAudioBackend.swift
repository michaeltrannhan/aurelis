import Foundation

final class MockAudioBackend: AudioBackend {
    var snapshot: AudioBackendSnapshot
    private(set) var commands: [AudioBackendCommand] = []
    var fetchError: Error?
    var applyError: Error?
    private(set) var selectedDefaultOutputDeviceID: String?
    /// Per-device UID volume/mute state for `AudioBackendOutputVolumeControlling`.
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

    func clearCommands() {
        commands.removeAll()
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

    func readOutputVolume(forUID uid: String) throws -> OutputVolumeState {
        OutputVolumeState(
            volume: perDeviceVolume[uid] ?? 0.75,
            isMuted: perDeviceMuted[uid] ?? false,
            deviceName: deviceName(forUID: uid),
            capabilities: .controllable
        )
    }

    func setOutputVolume(_ volume: Double, forUID uid: String) throws {
        perDeviceVolume[uid] = min(max(volume, 0), 1)
    }

    func setOutputMuted(_ muted: Bool, forUID uid: String) throws {
        perDeviceMuted[uid] = muted
    }

    func setDefaultOutputDevice(forUID uid: String) throws {
        guard snapshot.devices.contains(where: { $0.id == uid }) else {
            throw NSError(domain: "MockAudioBackend", code: 404)
        }
        selectedDefaultOutputDeviceID = uid
        snapshot.devices = snapshot.devices.map {
            AudioDeviceSnapshot(id: $0.id, name: $0.name, isDefault: $0.id == uid)
        }
    }

    func startObservingOutputVolume(_ onChange: @escaping @Sendable () -> Void) {
        // No-op for mock backends.
    }

    func stopObservingOutputVolume() {
        // No-op for mock backends.
    }
}
