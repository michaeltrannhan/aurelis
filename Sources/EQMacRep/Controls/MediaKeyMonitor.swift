import AppKit
import CoreGraphics
import Foundation

enum MediaKeyMonitorStartResult: Equatable, Sendable {
    case running
    case failed(String)
}

enum MediaTapRecoveryDecision: Equatable, Sendable {
    case reenable(afterNanoseconds: UInt64)
    case stop(String)
}

/// Bounded recovery model for event-tap timeout/user-input disable bursts.
/// A quiet window resets the budget; sustained flapping is surfaced instead of
/// silently leaving controls dead or retrying forever.
struct MediaTapRecoveryPolicy: Equatable, Sendable {
    var window: TimeInterval = 10
    var retryDelaysNanoseconds: [UInt64] = [0, 250_000_000, 1_000_000_000]
    private(set) var disableTimes: [TimeInterval] = []

    mutating func decision(at now: TimeInterval) -> MediaTapRecoveryDecision {
        disableTimes.removeAll { now - $0 > window || now < $0 }
        disableTimes.append(now)
        let attempt = disableTimes.count - 1
        guard retryDelaysNanoseconds.indices.contains(attempt) else {
            return .stop("Media-key monitoring was repeatedly disabled by macOS. Retry after checking Accessibility permission.")
        }
        return .reenable(afterNanoseconds: retryDelaysNanoseconds[attempt])
    }

    mutating func reset() {
        disableTimes.removeAll()
    }
}

@MainActor
protocol MediaKeyMonitoring: AnyObject {
    var onEvent: ((MediaKeyEvent) -> Void)? { get set }
    var onOperationalFailure: ((String) -> Void)? { get set }
    func start() -> MediaKeyMonitorStartResult
    func stop()
}

/// Owns a CGEvent tap for system-defined media-key events. The callback context
/// is retained independently and invalidated during stop, eliminating the old
/// unretained-self lifetime hazard.
@MainActor
final class MediaKeyMonitor: MediaKeyMonitoring {
    private let decoder: any MediaKeyEventDecoding
    private let now: @Sendable () -> TimeInterval
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var callbackContext: MediaKeyCallbackContext?
    private var callbackContextPointer: UnsafeMutableRawPointer?
    private var recoveryWorkItem: DispatchWorkItem?
    private var recoveryPolicy: MediaTapRecoveryPolicy

    var onEvent: ((MediaKeyEvent) -> Void)?
    var onOperationalFailure: ((String) -> Void)?

    init(
        decoder: any MediaKeyEventDecoding = IOKitMediaKeyDecoder(),
        recoveryPolicy: MediaTapRecoveryPolicy = MediaTapRecoveryPolicy(),
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.decoder = decoder
        self.recoveryPolicy = recoveryPolicy
        self.now = now
    }

    func start() -> MediaKeyMonitorStartResult {
        guard eventTap == nil else { return .running }
        recoveryWorkItem?.cancel()
        recoveryPolicy.reset()
        let context = MediaKeyCallbackContext(monitor: self)
        let contextPointer = Unmanaged.passRetained(context).toOpaque()
        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: mediaKeyTapCallback,
            userInfo: contextPointer
        ) else {
            Unmanaged<MediaKeyCallbackContext>.fromOpaque(contextPointer).release()
            let message = "Couldn’t create the media-key event tap. Check Accessibility permission and retry."
            onOperationalFailure?(message)
            return .failed(message)
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        callbackContext = context
        callbackContextPointer = contextPointer
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return .running
    }

    func stop() {
        recoveryWorkItem?.cancel()
        recoveryWorkItem = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        callbackContext?.monitor = nil
        callbackContext = nil
        if let callbackContextPointer {
            Unmanaged<MediaKeyCallbackContext>.fromOpaque(callbackContextPointer).release()
            self.callbackContextPointer = nil
        }
        recoveryPolicy.reset()
    }

    fileprivate func handleTapDisabled() {
        guard let tap = eventTap else { return }
        switch recoveryPolicy.decision(at: now()) {
        case let .reenable(delay):
            recoveryWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let activeTap = self.eventTap else { return }
                    CGEvent.tapEnable(tap: activeTap, enable: true)
                }
            }
            recoveryWorkItem = workItem
            if delay == 0 {
                DispatchQueue.main.async(execute: workItem)
            } else {
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + .nanoseconds(Int(min(delay, UInt64(Int.max)))),
                    execute: workItem
                )
            }
        case let .stop(message):
            stop()
            onOperationalFailure?(message)
        }
        _ = tap
    }

    /// Returns true if a recognized media key was handled and should be
    /// swallowed so macOS does not also show its system HUD.
    fileprivate func handle(cgEvent: CGEvent) -> Bool {
        guard let nsEvent = NSEvent(cgEvent: cgEvent),
              nsEvent.type == .systemDefined,
              nsEvent.subtype.rawValue == 8,
              let event = decoder.decode(data1: nsEvent.data1) else { return false }
        onEvent?(event)
        return true
    }
}

/// The event tap and this weak context are installed, invoked, and invalidated
/// on the main run loop. The C callback cannot express that executor contract.
private final class MediaKeyCallbackContext: @unchecked Sendable {
    weak var monitor: MediaKeyMonitor?

    init(monitor: MediaKeyMonitor) {
        self.monitor = monitor
    }
}

private func mediaKeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let context = Unmanaged<MediaKeyCallbackContext>.fromOpaque(userInfo).takeUnretainedValue()
    let eventBox = UncheckedCGEvent(event)
    let handled = MainActor.assumeIsolated {
        guard let monitor = context.monitor else { return false }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            monitor.handleTapDisabled()
            return false
        }
        return monitor.handle(cgEvent: eventBox.value)
    }
    return handled ? nil : Unmanaged.passUnretained(event)
}

/// Core Graphics event-tap callbacks are synchronously invoked on the run loop
/// where the tap was installed. Swift's imported `CGEvent` type does not state
/// that guarantee, so contain the unchecked crossing at this callback boundary.
private struct UncheckedCGEvent: @unchecked Sendable {
    let value: CGEvent

    init(_ value: CGEvent) {
        self.value = value
    }
}
