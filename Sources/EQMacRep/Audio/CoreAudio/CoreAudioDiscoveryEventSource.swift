import CoreAudio
import Foundation

/// Owns CoreAudio HAL property listeners for the system object and emits a
/// coalesced change event whenever the process list, device list, or default
/// output device changes. Consumers debounce these ticks and re-fetch a snapshot.
final class CoreAudioDiscoveryEventSource {
    private struct ListenerKey: Hashable {
        var objectID: AudioObjectID
        var selector: AudioObjectPropertySelector
        var scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
        var element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain

        var address: AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        }
    }

    private var continuation: AsyncStream<Void>.Continuation?
    private var registrations = Set<ListenerKey>()

    init() {}

    lazy var events: AsyncStream<Void> = AsyncStream { continuation in
        self.continuation = continuation
        self.registerListeners()
    }

    deinit {
        unregisterListeners()
    }

    private var selfContext: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    private func registerListeners() {
        addSystemListener(kAudioHardwarePropertyProcessObjectList)
        addSystemListener(kAudioHardwarePropertyDevices)
        addSystemListener(kAudioHardwarePropertyDefaultOutputDevice)
        refreshDeviceListeners()
    }

    private func addSystemListener(_ selector: AudioObjectPropertySelector) {
        addListener(ListenerKey(objectID: AudioObjectID(kAudioObjectSystemObject), selector: selector))
    }

    /// Refreshes per-device listeners after a HAL device-list change. Nominal
    /// rate changes keep active controller coefficients current; aggregate full
    /// and active-list changes cause Follow Default to be re-resolved.
    func refreshDeviceListeners() {
        let deviceIDs: [AudioObjectID] = (try? CoreAudioPropertyReader.array(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices
        )) ?? []
        var desired = Set<ListenerKey>()
        for deviceID in deviceIDs {
            if CoreAudioPropertyReader.hasProperty(
                objectID: deviceID,
                selector: kAudioDevicePropertyNominalSampleRate
            ) {
                desired.insert(ListenerKey(objectID: deviceID, selector: kAudioDevicePropertyNominalSampleRate))
            }
            if CoreAudioPropertyReader.hasProperty(
                objectID: deviceID,
                selector: kAudioAggregateDevicePropertyFullSubDeviceList
            ) {
                desired.insert(ListenerKey(objectID: deviceID, selector: kAudioAggregateDevicePropertyFullSubDeviceList))
            }
            if CoreAudioPropertyReader.hasProperty(
                objectID: deviceID,
                selector: kAudioAggregateDevicePropertyActiveSubDeviceList
            ) {
                desired.insert(ListenerKey(objectID: deviceID, selector: kAudioAggregateDevicePropertyActiveSubDeviceList))
            }
        }

        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        for key in Array(registrations) where key.objectID != systemObject && !desired.contains(key) {
            removeListener(key)
        }
        for key in desired {
            addListener(key)
        }
    }

    private func addListener(_ key: ListenerKey) {
        guard !registrations.contains(key) else { return }
        var address = key.address
        let status = AudioObjectAddPropertyListener(
            key.objectID,
            &address,
            Self.listenerProc,
            selfContext
        )
        if status == noErr {
            registrations.insert(key)
        }
    }

    private func removeListener(_ key: ListenerKey) {
        var address = key.address
        AudioObjectRemovePropertyListener(
            key.objectID,
            &address,
            Self.listenerProc,
            selfContext
        )
        registrations.remove(key)
    }

    private func unregisterListeners() {
        for key in Array(registrations) {
            removeListener(key)
        }
    }

    private static let listenerProc: AudioObjectPropertyListenerProc = { _, _, _, context in
        guard let context else { return noErr }
        let source = Unmanaged<CoreAudioDiscoveryEventSource>
            .fromOpaque(context)
            .takeUnretainedValue()
        source.continuation?.yield(())
        return noErr
    }
}
