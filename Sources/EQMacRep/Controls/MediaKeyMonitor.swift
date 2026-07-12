import AppKit
import CoreGraphics
import Foundation

/// Owns a CGEvent tap for system-defined media-key events (volume up/down/mute).
/// Decodes each press and forwards it; swallows the event so the system HUD does
/// not also react. Requires Accessibility trust to receive events.
///
/// Not unit-tested: exercised only on real hardware with permission granted.
final class MediaKeyMonitor {
    private let decoder: MediaKeyEventDecoding
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastDisableTime: CFAbsoluteTime = 0

    /// Called on the main run loop for each decoded media-key event. Return value
    /// is ignored; the monitor always swallows recognized events.
    var onEvent: ((MediaKeyEvent) -> Void)?
    /// Whether the monitor is currently allowed to intercept keys.
    var isEnabled = true

    init(decoder: MediaKeyEventDecoding = IOKitMediaKeyDecoder()) {
        self.decoder = decoder
    }

    func start() {
        guard eventTap == nil else { return }
        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: mediaKeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
    }

    /// Re-enables the tap after a timeout/user-input disable, unless it is
    /// flapping (two disables within 5s), in which case it stays off.
    fileprivate func handleTapDisabled() {
        let now = CFAbsoluteTimeGetCurrent()
        defer { lastDisableTime = now }
        guard now - lastDisableTime > 5 else {
            stop()
            return
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    /// Returns true if the event was a recognized media key that was handled.
    fileprivate func handle(cgEvent: CGEvent) -> Bool {
        guard isEnabled, let nsEvent = NSEvent(cgEvent: cgEvent) else { return false }
        guard nsEvent.type == .systemDefined, nsEvent.subtype.rawValue == 8 else { return false }
        guard let event = decoder.decode(data1: nsEvent.data1) else { return false }
        onEvent?(event)
        return true
    }
}

/// C trampoline for the CGEvent tap. Recovers the monitor from `userInfo` and
/// dispatches; consumes recognized media keys by returning nil.
private func mediaKeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<MediaKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        monitor.handleTapDisabled()
        return Unmanaged.passUnretained(event)
    }

    if monitor.handle(cgEvent: event) {
        return nil
    }
    return Unmanaged.passUnretained(event)
}
