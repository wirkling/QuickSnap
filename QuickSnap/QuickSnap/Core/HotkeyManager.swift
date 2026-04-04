import AppKit
import Carbon

/// Global hotkey manager using Carbon RegisterEventHotKey.
/// Carbon hot keys work globally without Accessibility permission —
/// they're the same mechanism Alfred, Spotlight, etc. use.
///
/// Registers both Cmd+Shift+4 and Cmd+Shift+2.
final class HotkeyManager {
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    deinit {
        unregister()
    }

    func register() {
        // Install Carbon event handler for hot key events
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passRetained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotKeyHandler,
            1,
            &eventType,
            selfPtr,
            nil
        )

        // Register Cmd+Shift+4 (keyCode 21)
        registerHotKey(keyCode: UInt32(kVK_ANSI_4), id: 1)
        // Register Cmd+Shift+2 (keyCode 19)
        registerHotKey(keyCode: UInt32(kVK_ANSI_2), id: 2)

        print("[QuickSnap] Hotkeys registered via Carbon (Cmd+Shift+4 and Cmd+Shift+2)")
    }

    func unregister() {
        for ref in hotKeyRefs {
            if let ref = ref {
                UnregisterEventHotKey(ref)
            }
        }
        hotKeyRefs.removeAll()
    }

    fileprivate func handleHotkey() {
        DispatchQueue.main.async { [weak self] in
            self?.action()
        }
    }

    private func registerHotKey(keyCode: UInt32, id: UInt32) {
        let modifiers: UInt32 = UInt32(cmdKey | shiftKey)
        var hotKeyID = EventHotKeyID(signature: OSType(0x5153_4E50), id: id) // "QSNP"
        var hotKeyRef: EventHotKeyRef?

        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status == noErr {
            hotKeyRefs.append(hotKeyRef)
        } else {
            print("[QuickSnap] Failed to register hotkey id=\(id), keyCode=\(keyCode), status=\(status)")
        }
    }
}

// MARK: - Carbon Event Handler

private func carbonHotKeyHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData = userData, let event = event else {
        return OSStatus(eventNotHandledErr)
    }

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

    guard status == noErr else {
        return OSStatus(eventNotHandledErr)
    }

    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    manager.handleHotkey()

    return noErr
}
