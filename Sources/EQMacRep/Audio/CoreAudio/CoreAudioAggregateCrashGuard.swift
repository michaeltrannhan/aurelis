import Darwin
import Foundation

/// Fatal signals are not a valid cleanup context: CoreAudio, locks, allocation,
/// Swift collections, and filesystem APIs are all forbidden here. Aggregate
/// ownership is persisted during normal execution and recovered next launch.
private let crashGuardHandler: @convention(c) (Int32) -> Void = { signalNumber in
    signal(signalNumber, SIG_DFL)
    _ = raise(signalNumber)
    _exit(128 + signalNumber)
}

enum CoreAudioAggregateCrashGuard {
    /// Exposed so regression tests assert the production handler contract rather
    /// than exercising a separate mock tracker.
    static let fatalSignalHandlerPerformsExternalCleanup = false

    nonisolated(unsafe) private static var installed = false
    private static let lock = NSLock()

    static func install() {
        lock.lock()
        defer { lock.unlock() }
        guard !installed else { return }
        installed = true
        for signalNumber in [SIGABRT, SIGSEGV, SIGBUS, SIGTRAP] {
            signal(signalNumber, crashGuardHandler)
        }
    }
}
