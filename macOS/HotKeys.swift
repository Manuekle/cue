import Carbon.HIToolbox
import Foundation

/// Atajos de teclado globales (funcionan aunque Pronter no esté al frente).
/// Usa la API de Carbon, que no requiere permisos de accesibilidad.
final class HotKeys {
    static let shared = HotKeys()

    private var actions: [UInt32: () -> Void] = [:]
    private var references: [EventHotKeyRef] = []
    private var handlerInstalled = false

    /// Tecla + modificadores (por defecto ⌃⌥).
    func register(_ keyCode: Int, modifiers: Int = controlKey | optionKey, action: @escaping () -> Void) {
        installHandlerIfNeeded()
        let id = UInt32(actions.count + 1)
        actions[id] = action
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5052_4E54), id: id) // "PRNT"
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &reference)
        if status == noErr, let reference {
            references.append(reference)
        } else {
            NSLog("Pronter: no se pudo registrar el atajo (tecla %d, modificadores %d): error %d", keyCode, modifiers, status)
        }
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            if ProcessInfo.processInfo.environment["PRONTER_DEBUG_HOTKEYS"] != nil { NSLog("Pronter: atajo %d", id) }
            DispatchQueue.main.async { HotKeys.shared.actions[id]?() }
            return noErr
        }, 1, &eventType, nil, nil)
    }
}
