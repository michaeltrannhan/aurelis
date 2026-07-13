import CoreAudio
import Foundation

/// Reads and controls hardware volume and mute state for any output device by
/// UID, plus the system default output device. Used by
/// `CoreAudioDiscoveryBackend` to back the top-level device volume list.
/// Observes the default output device, its volume scalar, and its mute flag so
/// external changes (hardware keys, system preferences, other apps) refresh
/// the UI.
final class CoreAudioOutputVolumeController: @unchecked Sendable {
    private let queue = DispatchQueue(label: "EQMacRep.CoreAudioOutputVolumeController", qos: .utility)
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    private var volumeListener: AudioObjectPropertyListenerBlock?
    private var muteListener: AudioObjectPropertyListenerBlock?
    private var observedDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var onChange: (@Sendable () -> Void)?

    func readOutputVolume() throws -> OutputVolumeState {
        let deviceID = try defaultOutputDeviceID()
        return try readOutputVolume(forDeviceID: deviceID)
    }

    func readOutputVolume(forUID uid: String) throws -> OutputVolumeState {
        let deviceID = try deviceObjectID(forUID: uid)
        return try readOutputVolume(forDeviceID: deviceID)
    }

    func setOutputVolume(_ volume: Double) throws {
        let deviceID = try defaultOutputDeviceID()
        try setVolumeScalar(volume, for: deviceID)
    }

    func setOutputVolume(_ volume: Double, forUID uid: String) throws {
        let deviceID = try deviceObjectID(forUID: uid)
        try setVolumeScalar(volume, for: deviceID)
    }

    func setOutputMuted(_ muted: Bool) throws {
        let deviceID = try defaultOutputDeviceID()
        try setMute(muted, for: deviceID)
    }

    func setOutputMuted(_ muted: Bool, forUID uid: String) throws {
        let deviceID = try deviceObjectID(forUID: uid)
        try setMute(muted, for: deviceID)
    }

    func startObserving(_ onChange: @escaping @Sendable () -> Void) {
        guard self.onChange == nil else { return }
        self.onChange = onChange
        installDefaultDeviceListener()
        installPropertyListeners(for: try? defaultOutputDeviceID())
    }

    func stopObserving() {
        removePropertyListeners()
        removeDefaultDeviceListener()
        onChange = nil
    }

    // MARK: - Per-device reads

    private func readOutputVolume(forDeviceID deviceID: AudioObjectID) throws -> OutputVolumeState {
        let volume = (try? readVolumeScalar(for: deviceID)) ?? 1
        let isMuted = (try? readMute(for: deviceID)) ?? false
        let deviceName = try? readName(for: deviceID)
        return OutputVolumeState(volume: volume, isMuted: isMuted, deviceName: deviceName)
    }

    // MARK: - Default device

    private static func defaultOutputDeviceAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func defaultOutputDeviceID() throws -> AudioObjectID {
        var address = Self.defaultOutputDeviceAddress()
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else {
            throw CoreAudioDiscoveryError.propertyReadFailed(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                selector: kAudioHardwarePropertyDefaultOutputDevice,
                status: status
            )
        }
        return deviceID
    }

    private func deviceObjectID(forUID uid: String) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier = uid as CFString
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &qualifier) { qualifierPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                qualifierPointer,
                &size,
                &objectID
            )
        }
        guard status == noErr, objectID != AudioObjectID(kAudioObjectUnknown) else {
            throw CoreAudioDiscoveryError.propertyReadFailed(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                selector: kAudioHardwarePropertyTranslateUIDToDevice,
                status: status
            )
        }
        return objectID
    }

    // MARK: - Volume / mute / name reads

    private static func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func nameAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func readVolumeScalar(for deviceID: AudioObjectID) throws -> Double {
        var address = Self.volumeAddress()
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == noErr else {
            throw CoreAudioDiscoveryError.propertyReadFailed(
                objectID: deviceID,
                selector: kAudioDevicePropertyVolumeScalar,
                status: status
            )
        }
        return Double(value)
    }

    private func readMute(for deviceID: AudioObjectID) throws -> Bool {
        var address = Self.muteAddress()
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == noErr else {
            throw CoreAudioDiscoveryError.propertyReadFailed(
                objectID: deviceID,
                selector: kAudioDevicePropertyMute,
                status: status
            )
        }
        return value != 0
    }

    private func readName(for deviceID: AudioObjectID) throws -> String {
        var address = Self.nameAddress()
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else {
            throw CoreAudioDiscoveryError.propertyReadFailed(
                objectID: deviceID,
                selector: kAudioObjectPropertyName,
                status: status
            )
        }
        return value?.takeRetainedValue() as String? ?? ""
    }

    // MARK: - Volume / mute writes

    private func setVolumeScalar(_ volume: Double, for deviceID: AudioObjectID) throws {
        let clamped = min(max(volume.isFinite ? volume : 1, 0), 1)
        var address = Self.volumeAddress()
        var value = Float32(clamped)
        let status = withUnsafePointer(to: &value) { pointer in
            AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), pointer)
        }
        guard status == noErr else {
            throw CoreAudioDiscoveryError.propertyReadFailed(
                objectID: deviceID,
                selector: kAudioDevicePropertyVolumeScalar,
                status: status
            )
        }
    }

    private func setMute(_ muted: Bool, for deviceID: AudioObjectID) throws {
        var address = Self.muteAddress()
        var value: UInt32 = muted ? 1 : 0
        let status = withUnsafePointer(to: &value) { pointer in
            AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), pointer)
        }
        guard status == noErr else {
            throw CoreAudioDiscoveryError.propertyReadFailed(
                objectID: deviceID,
                selector: kAudioDevicePropertyMute,
                status: status
            )
        }
    }

    // MARK: - Listeners

    private func installDefaultDeviceListener() {
        var address = Self.defaultOutputDeviceAddress()
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.removePropertyListeners()
            self.installPropertyListeners(for: try? self.defaultOutputDeviceID())
            self.notifyChange()
        }
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        guard status == noErr else { return }
        defaultDeviceListener = listener
    }

    private func removeDefaultDeviceListener() {
        guard let defaultDeviceListener else { return }
        var address = Self.defaultOutputDeviceAddress()
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, defaultDeviceListener)
        self.defaultDeviceListener = nil
    }

    private func installPropertyListeners(for deviceID: AudioObjectID?) {
        guard let deviceID, deviceID != AudioObjectID(kAudioObjectUnknown) else { return }
        observedDeviceID = deviceID
        var volumeAddress = Self.volumeAddress()
        let volumeListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.notifyChange() }
        let volumeStatus = AudioObjectAddPropertyListenerBlock(deviceID, &volumeAddress, queue, volumeListener)
        guard volumeStatus == noErr else { return }
        self.volumeListener = volumeListener

        var muteAddress = Self.muteAddress()
        let muteListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.notifyChange() }
        let muteStatus = AudioObjectAddPropertyListenerBlock(deviceID, &muteAddress, queue, muteListener)
        guard muteStatus == noErr else { return }
        self.muteListener = muteListener
    }

    private func removePropertyListeners() {
        let deviceID = observedDeviceID
        if let volumeListener, deviceID != AudioObjectID(kAudioObjectUnknown) {
            var address = Self.volumeAddress()
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, queue, volumeListener)
        }
        if let muteListener, deviceID != AudioObjectID(kAudioObjectUnknown) {
            var address = Self.muteAddress()
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, queue, muteListener)
        }
        volumeListener = nil
        muteListener = nil
        observedDeviceID = AudioObjectID(kAudioObjectUnknown)
    }

    private func notifyChange() {
        onChange?()
    }
}
