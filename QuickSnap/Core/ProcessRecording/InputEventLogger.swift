import AppKit
import Foundation

/// Captures keyboard shortcuts and clipboard changes during a recording session.
@MainActor
final class InputEventLogger {
    private var keyMonitor: Any?
    private var clipboardTimer: Timer?
    private var lastClipboardChangeCount: Int
    private let onEvent: (InputEventKind, TimeInterval) -> Void
    private let sessionStart: Date

    init(sessionStart: Date, onEvent: @escaping (InputEventKind, TimeInterval) -> Void) {
        self.sessionStart = sessionStart
        self.onEvent = onEvent
        self.lastClipboardChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        // Global key monitor for ⌘-modified shortcuts
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            guard event.modifierFlags.contains(.command) else { return }
            let keys = Self.formatShortcut(event)
            let elapsed = Date().timeIntervalSince(self.sessionStart)
            Task { @MainActor in
                self.onEvent(.keyboardShortcut(keys: keys), elapsed)
            }
        }

        // Clipboard polling every 2s
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkClipboard()
            }
        }
    }

    func stop() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        clipboardTimer?.invalidate()
        clipboardTimer = nil
    }

    private func checkClipboard() {
        let pb = NSPasteboard.general
        let currentCount = pb.changeCount
        guard currentCount != lastClipboardChangeCount else { return }
        lastClipboardChangeCount = currentCount

        let preview: String
        if let str = pb.string(forType: .string) {
            preview = String(str.prefix(200))
        } else if let _ = pb.data(forType: .png) ?? pb.data(forType: .tiff) {
            preview = "[image data]"
        } else if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], let first = urls.first {
            preview = first.lastPathComponent
        } else {
            preview = "[unknown content]"
        }

        let elapsed = Date().timeIntervalSince(sessionStart)
        onEvent(.clipboardChange(preview: preview), elapsed)
    }

    // MARK: - Shortcut formatting

    private static func formatShortcut(_ event: NSEvent) -> String {
        var parts: [String] = []
        let mods = event.modifierFlags
        if mods.contains(.control) { parts.append("⌃") }
        if mods.contains(.option)  { parts.append("⌥") }
        if mods.contains(.shift)   { parts.append("⇧") }
        if mods.contains(.command) { parts.append("⌘") }

        // Map common key codes to readable names
        let key: String
        switch event.keyCode {
        case 0: key = "A"; case 1: key = "S"; case 2: key = "D"; case 3: key = "F"
        case 4: key = "H"; case 5: key = "G"; case 6: key = "Z"; case 7: key = "X"
        case 8: key = "C"; case 9: key = "V"; case 11: key = "B"; case 12: key = "Q"
        case 13: key = "W"; case 14: key = "E"; case 15: key = "R"; case 16: key = "Y"
        case 17: key = "T"; case 31: key = "O"; case 32: key = "U"; case 34: key = "I"
        case 35: key = "P"; case 37: key = "L"; case 38: key = "J"; case 40: key = "K"
        case 41: key = ";"; case 45: key = "N"; case 46: key = "M"
        case 36: key = "↩"; case 48: key = "⇥"; case 49: key = "Space"
        case 51: key = "⌫"; case 53: key = "⎋"
        default:
            key = event.charactersIgnoringModifiers?.uppercased() ?? "?"
        }

        parts.append(key)
        return parts.joined()
    }
}
