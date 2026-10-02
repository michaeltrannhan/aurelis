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
    private var registrations: [ListenerKey: AudioObjectPropertyListenerBlock] = [:]
    private var retiredRegistrations = Set<ListenerKey>()
    private let queue = DispatchQueue(label: "Auralis.CoreAudioDiscoveryEvents")

    init() {}

    var events: AsyncStream<Void> {
        stop()
        let events = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation = events.continuation
        registerListeners()
        return events.stream
    }

    deinit {
        stop()
    }

    func stop() {
        continuation?.finish()
        continuation = nil
        unregisterListeners()
        retiredRegistrations = Set(registrations.keys)
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

    /// Refreshes per-device listeners after a HAL device-list change. Alive
    /// changes catch transports that briefly remain enumerated during unplug;
    /// nominal-rate and aggregate changes keep active routes current.
    func refreshDeviceListeners() {
        guard continuation != nil else { return }
        let deviceIDs: [AudioObjectID] = (try? CoreAudioPropertyReader.array(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices
        )) ?? []
        var desired = Set<ListenerKey>()
        for deviceID in deviceIDs {
            if CoreAudioPropertyReader.hasProperty(
                objectID: deviceID,
                selector: kAudioDevicePropertyDeviceIsAlive
            ) {
                desired.insert(ListenerKey(objectID: deviceID, selector: kAudioDevicePropertyDeviceIsAlive))
            }
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
        for key in Array(registrations.keys) where key.objectID != systemObject && !desired.contains(key) {
            removeListener(key)
        }
        for key in desired {
            addListener(key)
        }
    }

    private func addListener(_ key: ListenerKey) {
        if retiredRegistrations.contains(key) { removeListener(key) }
        guard registrations[key] == nil, let continuation else { return }
        var address = key.address
        // Capture only the thread-safe continuation. Failed HAL removal cannot
        // leave a callback pointing at an already released event source.
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            continuation.yield(())
        }
        let status = AudioObjectAddPropertyListenerBlock(key.objectID, &address, queue, listener)
        if status == noErr {
            registrations[key] = listener
        }
    }

    private func removeListener(_ key: ListenerKey) {
        guard let listener = registrations[key] else { return }
        var address = key.address
        let status = AudioObjectRemovePropertyListenerBlock(key.objectID, &address, queue, listener)
        if status == noErr {
            registrations.removeValue(forKey: key)
            retiredRegistrations.remove(key)
        }
    }

    private func unregisterListeners() {
        for key in Array(registrations.keys) {
            removeListener(key)
        }
    }
}
