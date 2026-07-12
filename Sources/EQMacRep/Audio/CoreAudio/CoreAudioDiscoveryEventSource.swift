import CoreAudio
import Foundation

/// Owns CoreAudio HAL property listeners for the system object and emits a
/// coalesced change event whenever the process list, device list, or default
/// output device changes. Consumers debounce these ticks and re-fetch a snapshot.
final class CoreAudioDiscoveryEventSource {
    private var continuation: AsyncStream<Void>.Continuation?
    private var registeredAddresses: [AudioObjectPropertyAddress] = []

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
        guard registeredAddresses.isEmpty else { return }
        addSystemListener(kAudioHardwarePropertyProcessObjectList)
        addSystemListener(kAudioHardwarePropertyDevices)
        addSystemListener(kAudioHardwarePropertyDefaultOutputDevice)
    }

    private func addSystemListener(_ selector: AudioObjectPropertySelector) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            Self.listenerProc,
            selfContext
        )
        if status == noErr {
            registeredAddresses.append(address)
        }
    }

    private func unregisterListeners() {
        for address in registeredAddresses {
            var mutableAddress = address
            AudioObjectRemovePropertyListener(
                AudioObjectID(kAudioObjectSystemObject),
                &mutableAddress,
                Self.listenerProc,
                selfContext
            )
        }
        registeredAddresses.removeAll()
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
