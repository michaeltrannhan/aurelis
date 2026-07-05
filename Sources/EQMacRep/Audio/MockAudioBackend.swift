import Foundation

final class MockAudioBackend: AudioBackend {
    var snapshot: AudioBackendSnapshot
    private(set) var commands: [AudioBackendCommand] = []
    var fetchError: Error?
    var applyError: Error?

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
