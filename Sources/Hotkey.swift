import Carbon.HIToolbox
import Cocoa

/// Minimal Carbon global hotkey wrapper.
///
/// Carbon's RegisterEventHotKey is used rather than a CGEventTap because it
/// needs no Accessibility permission -- the app stays zero-prompt on install.
final class Hotkey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var eventHandlerInstalled = false

    private var ref: EventHotKeyRef?
    private let id: UInt32

    /// - Parameters:
    ///   - keyCode: a `kVK_*` virtual key code.
    ///   - modifiers: Carbon modifier mask, e.g. `controlKey | optionKey`.
    /// - Returns: nil if the combination is already claimed by another app.
    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        Hotkey.installEventHandlerIfNeeded()

        id = Hotkey.nextID
        Hotkey.nextID += 1

        let hotKeyID = EventHotKeyID(signature: OSType(0x53504754), id: id) // 'SPGT'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }

        self.ref = ref
        Hotkey.handlers[id] = handler
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Hotkey.handlers.removeValue(forKey: id)
    }

    private static func installEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        eventHandlerInstalled = true

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            if let handler = Hotkey.handlers[hotKeyID.id] {
                DispatchQueue.main.async(execute: handler)
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
