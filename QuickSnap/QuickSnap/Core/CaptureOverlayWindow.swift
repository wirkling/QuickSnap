import AppKit

/// Creates and configures a transparent fullscreen window for screenshot selection.
/// Click = capture window under cursor. Click+drag = capture selected region.
final class CaptureOverlayWindow {
    let window: NSWindow
    let overlayView: CaptureOverlayView

    init(screen: NSScreen, completion: @escaping (CaptureResult) -> Void) {
        overlayView = CaptureOverlayView(screenFrame: screen.frame, completion: completion)

        window = KeyableWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        window.level = .init(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 1)
        window.isOpaque = false
        window.hasShadow = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.contentView = overlayView
        window.setFrame(screen.frame, display: true)

        // Escape key handler
        let escapeCompletion = completion
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape
                escapeCompletion(.cancelled)
                return nil
            }
            return event
        }

        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.orderOut(nil)
    }
}

/// A minimal NSWindow subclass that can become key (required for mouse events).
private class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
