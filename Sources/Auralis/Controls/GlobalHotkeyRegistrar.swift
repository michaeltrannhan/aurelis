import AppKit
import Carbon.HIToolbox
import Foundation

struct HotkeyRegistrationFailure: Equatable, Sendable {
    let action: ShortcutAction?
    let status: OSStatus
}

struct HotkeyRegistrationReport: Equatable, Sendable {
    let registeredActions: Set<ShortcutAction>
    let failures: [HotkeyRegistrationFailure]

    var succeeded: Bool { failures.isEmpty }
}

@MainActor
protocol GlobalHotkeyRegistering: AnyObject {
    var onAction: ((ShortcutAction) -> Void)? { get set }
    func register(_ bindings: [ShortcutAction: HotkeyBinding]) -> HotkeyRegistrationReport
    func unregisterAll()
    func stop()
}

/// Registers global hotkeys via Carbon `RegisterEventHotKey` and routes presses
/// back to `ShortcutAction`s. The Carbon event handler runs on the main run loop,
/// so `onAction` is invoked directly there.
@MainActor
final class GlobalHotkeyRegistrar: GlobalHotkeyRegistering {
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var actionsByID: [UInt32: ShortcutAction] = [:]
    private var eventHandler: EventHandlerRef?
    private var callbackContext: HotkeyCallbackContext?
    private var callbackContextPointer: UnsafeMutableRawPointer?
    private let signature: OSType = 0x45514D52 // 'EQMR'

    var onAction: ((ShortcutAction) -> Void)?

    func register(_ bindings: [ShortcutAction: HotkeyBinding]) -> HotkeyRegistrationReport {
        unregisterAll()
        let handlerStatus = installHandlerIfNeeded()
        guard handlerStatus == noErr else {
            return HotkeyRegistrationReport(
                registeredActions: [],
                failures: [HotkeyRegistrationFailure(action: nil, status: handlerStatus)]
            )
        }
        var registered: Set<ShortcutAction> = []
        var failures: [HotkeyRegistrationFailure] = []
        var nextID: UInt32 = 1
        for action in bindings.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let binding = bindings[action] else { continue }
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: signature, id: nextID)
            let status = RegisterEventHotKey(
                binding.keyCode,
                binding.modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                hotKeyRefs[nextID] = ref
                actionsByID[nextID] = action
                registered.insert(action)
            } else {
                failures.append(HotkeyRegistrationFailure(action: action, status: status))
            }
            nextID += 1
        }
        return HotkeyRegistrationReport(registeredActions: registered, failures: failures)
    }

    func unregisterAll() {
        for ref in hotKeyRefs.values {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        actionsByID.removeAll()
    }

    func stop() {
        unregisterAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        callbackContext?.registrar = nil
        callbackContext = nil
        if let callbackContextPointer {
            Unmanaged<HotkeyCallbackContext>.fromOpaque(callbackContextPointer).release()
            self.callbackContextPointer = nil
        }
        onAction = nil
    }

    fileprivate func action(for id: UInt32) -> ShortcutAction? {
        actionsByID[id]
    }

    private func installHandlerIfNeeded() -> OSStatus {
        guard eventHandler == nil else { return noErr }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = HotkeyCallbackContext(registrar: self)
        let contextPointer = Unmanaged.passRetained(context).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyEventHandler,
            1,
            &eventType,
            contextPointer,
            &eventHandler
        )
        guard status == noErr else {
            Unmanaged<HotkeyCallbackContext>.fromOpaque(contextPointer).release()
            eventHandler = nil
            return status
        }
        callbackContext = context
        callbackContextPointer = contextPointer
        return noErr
    }
}

/// Carbon invokes this handler on the application event target's main run loop;
/// its C callback type cannot encode that executor contract.
private final class HotkeyCallbackContext: @unchecked Sendable {
    weak var registrar: GlobalHotkeyRegistrar?

    init(registrar: GlobalHotkeyRegistrar) {
        self.registrar = registrar
    }
}

private func hotkeyEventHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    let notHandled = OSStatus(eventNotHandledErr)
    guard let event, let userData else { return notHandled }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    let context = Unmanaged<HotkeyCallbackContext>.fromOpaque(userData).takeUnretainedValue()
    return MainActor.assumeIsolated {
        guard let registrar = context.registrar else { return notHandled }
        if let action = registrar.action(for: hotKeyID.id) {
            registrar.onAction?(action)
            return noErr
        }
        return notHandled
    }
}
