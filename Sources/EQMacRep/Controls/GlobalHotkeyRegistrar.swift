import AppKit
import Carbon.HIToolbox
import Foundation

/// Registers global hotkeys via Carbon `RegisterEventHotKey` and routes presses
/// back to `ShortcutAction`s. The Carbon event handler runs on the main run loop,
/// so `onAction` is invoked directly there.
///
/// Not unit-tested: exercised only on real hardware.
final class GlobalHotkeyRegistrar {
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var actionsByID: [UInt32: ShortcutAction] = [:]
    private var eventHandler: EventHandlerRef?
    private let signature: OSType = 0x45514D52 // 'EQMR'

    var onAction: ((ShortcutAction) -> Void)?

    func register(_ bindings: [ShortcutAction: HotkeyBinding]) {
        installHandlerIfNeeded()
        unregisterAll()
        var nextID: UInt32 = 1
        for (action, binding) in bindings {
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
            }
            nextID += 1
        }
    }

    func unregisterAll() {
        for ref in hotKeyRefs.values {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        actionsByID.removeAll()
    }

    fileprivate func action(for id: UInt32) -> ShortcutAction? {
        actionsByID[id]
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyEventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }
}

private func hotkeyEventHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return noErr }
    let registrar = Unmanaged<GlobalHotkeyRegistrar>.fromOpaque(userData).takeUnretainedValue()

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

    if let action = registrar.action(for: hotKeyID.id) {
        registrar.onAction?(action)
    }
    return noErr
}
