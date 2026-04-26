import AppKit
import Carbon

/// Global hotkey manager using Carbon RegisterEventHotKey.
/// Carbon hot keys work globally without Accessibility permission —
/// they're the same mechanism Alfred, Spotlight, etc. use.
///
/// Registers Cmd+Shift+4, Cmd+Shift+2 (capture), and Cmd+Shift+R (recording).
final class HotkeyManager {
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private let captureAction: () -> Void
    private let recordAction: () -> Void

    init(captureAction: @escaping () -> Void, recordAction: @escaping () -> Void) {
        self.captureAction = captureAction
        self.recordAction = recordAction
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

        // Register Cmd+Shift+4 (keyCode 21) — capture
        registerHotKey(keyCode: UInt32(kVK_ANSI_4), id: 1)
        // Register Cmd+Shift+2 (keyCode 19) — capture
        registerHotKey(keyCode: UInt32(kVK_ANSI_2), id: 2)
        // Register Cmd+Shift+R (keyCode 15) — recording toggle
        registerHotKey(keyCode: UInt32(kVK_ANSI_R), id: 3)

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

    fileprivate func handleHotkey(id: UInt32) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch id {
            case 1, 2:
                self.captureAction()
            case 3:
                self.recordAction()
            default:
                break
            }
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
    manager.handleHotkey(id: hotKeyID.id)

    return noErr
}
