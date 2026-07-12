import CoreAudio
import Darwin
import Foundation

/// Pure fixed-slot tracker for aggregate device IDs. Unit-tested in isolation;
/// the installed crash guard keeps its own signal-safe buffer separately.
final class CoreAudioAggregateTracker {
    private var slots: [AudioObjectID]

    init(maxSlots: Int = 64) {
        slots = Array(repeating: AudioObjectID(kAudioObjectUnknown), count: max(maxSlots, 1))
    }

    @discardableResult
    func track(_ id: AudioObjectID) -> Bool {
        guard !slots.contains(id),
              let index = slots.firstIndex(of: AudioObjectID(kAudioObjectUnknown)) else {
            return false
        }
        slots[index] = id
        return true
    }

    func untrack(_ id: AudioObjectID) {
        guard let index = slots.firstIndex(of: id) else { return }
        slots[index] = AudioObjectID(kAudioObjectUnknown)
    }

    func trackedIDs() -> [AudioObjectID] {
        slots.filter { $0 != AudioObjectID(kAudioObjectUnknown) }
    }
}

// MARK: Process-wide crash guard

private let crashGuardCapacity = 64

/// Signal-safe backing store: a fixed heap buffer written under a lock from
/// normal context and read lock-free from the signal handler.
nonisolated(unsafe) private let crashGuardSlots: UnsafeMutablePointer<AudioObjectID> = {
    let pointer = UnsafeMutablePointer<AudioObjectID>.allocate(capacity: crashGuardCapacity)
    pointer.initialize(repeating: AudioObjectID(kAudioObjectUnknown), count: crashGuardCapacity)
    return pointer
}()

/// Async-signal-safe: iterates the raw buffer and destroys each tracked aggregate,
/// then restores the default handler and re-raises so the crash still surfaces.
private let crashGuardHandler: @convention(c) (Int32) -> Void = { sig in
    for index in 0..<crashGuardCapacity {
        let id = crashGuardSlots[index]
        if id != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(id)
        }
    }
    signal(sig, SIG_DFL)
    raise(sig)
}

/// Destroys tracked aggregate devices if the process crashes, so a hard failure
/// does not leave the system routed through an orphaned EQMacRep aggregate.
enum CoreAudioAggregateCrashGuard {
    nonisolated(unsafe) private static var installed = false
    private static let lock = NSLock()

    static func install() {
        lock.lock()
        defer { lock.unlock() }
        guard !installed else { return }
        installed = true
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGTRAP] {
            signal(sig, crashGuardHandler)
        }
    }

    static func trackDevice(_ id: AudioObjectID) {
        guard id != AudioObjectID(kAudioObjectUnknown) else { return }
        lock.lock()
        defer { lock.unlock() }
        for index in 0..<crashGuardCapacity where crashGuardSlots[index] == AudioObjectID(kAudioObjectUnknown) {
            crashGuardSlots[index] = id
            return
        }
    }

    static func untrackDevice(_ id: AudioObjectID) {
        lock.lock()
        defer { lock.unlock() }
        for index in 0..<crashGuardCapacity where crashGuardSlots[index] == id {
            crashGuardSlots[index] = AudioObjectID(kAudioObjectUnknown)
            return
        }
    }
}
