import AppKit

/// The view that handles mouse tracking, window highlighting, and region selection.
///
/// Behavior:
/// - On hover: highlights the window under the cursor with a subtle border
/// - On click (< 5px movement, < 300ms): captures the window under cursor
/// - On click+drag: draws a selection rectangle and captures that region
class CaptureOverlayView: NSView {
    private let screenFrame: CGRect
    private let completion: (CaptureResult) -> Void

    // Capture mode (single vs burst)
    private var captureMode: CaptureMode = .single

    enum CaptureMode {
        case single
        case burst
    }

    // Mouse tracking state
    private var mouseDownPoint: NSPoint?
    private var mouseDownTime: Date?
    private var currentDragRect: NSRect?
    private var isDragging = false

    // Window highlight state
    private var highlightedWindowBounds: CGRect?
    private var highlightedWindowID: CGWindowID?

    // Thresholds
    private let clickMovementThreshold: CGFloat = 5.0
    private let clickDurationThreshold: TimeInterval = 0.3

    init(screenFrame: CGRect, completion: @escaping (CaptureResult) -> Void) {
        self.screenFrame = screenFrame
        self.completion = completion
        super.init(frame: screenFrame)

        // Add a tracking area for mouse moved events
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)

        // Show crosshair cursor immediately
        NSCursor.crosshair.push()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            NSCursor.pop()
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Semi-transparent dark overlay
        NSColor.black.withAlphaComponent(0.2).setFill()
        dirtyRect.fill()

        if isDragging, let dragRect = currentDragRect {
            // Clear the selection area (make it transparent)
            NSGraphicsContext.current?.compositingOperation = .copy
            NSColor.clear.setFill()
            NSBezierPath(rect: dragRect).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver

            // Draw selection border
            NSColor.white.setStroke()
            let borderPath = NSBezierPath(rect: dragRect)
            borderPath.lineWidth = 1.5
            borderPath.stroke()

            // Draw size label
            drawSizeLabel(for: dragRect)
        } else if let windowBounds = highlightedWindowBounds {
            // Highlight the window under cursor
            let localBounds = convertFromScreen(windowBounds)
            NSGraphicsContext.current?.compositingOperation = .copy
            NSColor.clear.setFill()
            NSBezierPath(rect: localBounds).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver

            NSColor(calibratedRed: 0.2, green: 0.5, blue: 1.0, alpha: 0.8).setStroke()
            let borderPath = NSBezierPath(rect: localBounds)
            borderPath.lineWidth = 2.0
            borderPath.stroke()
        }
    }

    private func drawSizeLabel(for rect: NSRect) {
        // Show dimensions as "WxH" near the bottom-right of selection
        let width = Int(rect.width * (window?.backingScaleFactor ?? 2.0))
        let height = Int(rect.height * (window?.backingScaleFactor ?? 2.0))
        let text = "\(width) × \(height)"

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.7)
        ]
        let attrStr = NSAttributedString(string: " \(text) ", attributes: attributes)
        let textSize = attrStr.size()
        let textPoint = NSPoint(
            x: rect.maxX - textSize.width - 4,
            y: rect.minY - textSize.height - 4
        )
        attrStr.draw(at: textPoint)
    }

    // MARK: - Mouse Events

    override func mouseMoved(with event: NSEvent) {
        let screenPoint = NSEvent.mouseLocation
        // Convert to CG coordinates (origin at top-left)
        let cgPoint = CGPoint(
            x: screenPoint.x,
            y: NSScreen.screens.first!.frame.height - screenPoint.y
        )

        if let windowInfo = WindowDetector.windowAt(point: cgPoint) {
            highlightedWindowBounds = windowInfo.bounds
            highlightedWindowID = windowInfo.windowID
        } else {
            highlightedWindowBounds = nil
            highlightedWindowID = nil
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        // Control+click = right-click on trackpads; route to context menu
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: event)
            return
        }
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        mouseDownTime = Date()
        isDragging = false
        currentDragRect = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint = mouseDownPoint else { return }
        let currentPoint = convert(event.locationInWindow, from: nil)

        let dx = abs(currentPoint.x - startPoint.x)
        let dy = abs(currentPoint.y - startPoint.y)

        if dx >= clickMovementThreshold || dy >= clickDurationThreshold {
            isDragging = true

            let origin = NSPoint(
                x: min(startPoint.x, currentPoint.x),
                y: min(startPoint.y, currentPoint.y)
            )
            let size = NSSize(
                width: abs(currentPoint.x - startPoint.x),
                height: abs(currentPoint.y - startPoint.y)
            )
            currentDragRect = NSRect(origin: origin, size: size)
            highlightedWindowBounds = nil
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging, let dragRect = currentDragRect, dragRect.width > 2, dragRect.height > 2 {
            if captureMode == .burst {
                emitBurstRegion(dragRect)
            } else {
                captureRegion(dragRect)
            }
        } else if let windowID = highlightedWindowID {
            // Window clicks always use single capture, even in burst mode
            captureWindow(windowID)
        } else {
            completion(.cancelled)
        }

        mouseDownPoint = nil
        mouseDownTime = nil
        isDragging = false
        currentDragRect = nil
    }

    // MARK: - Right-Click Context Menu

    /// Set this before showing the overlay to add "Start Stack" to the right-click menu.
    var onStartStack: (() -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()

        let singleItem = NSMenuItem(title: "Single Capture", action: #selector(selectSingleMode), keyEquivalent: "")
        singleItem.target = self
        singleItem.state = captureMode == .single ? .on : .off
        menu.addItem(singleItem)

        let burstItem = NSMenuItem(title: "Burst Mode (every 2s)", action: #selector(selectBurstMode), keyEquivalent: "")
        burstItem.target = self
        burstItem.state = captureMode == .burst ? .on : .off
        menu.addItem(burstItem)

        menu.addItem(NSMenuItem.separator())

        let stackItem = NSMenuItem(title: "Start Stack (multi-page PDF)", action: #selector(selectStackMode), keyEquivalent: "")
        stackItem.target = self
        menu.addItem(stackItem)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func selectSingleMode() { captureMode = .single }
    @objc private func selectBurstMode() { captureMode = .burst }
    @objc private func selectStackMode() {
        onStartStack?()
        completion(.cancelled) // Dismiss the overlay — stack mode takes over
    }

    // MARK: - Capture

    private func captureRegion(_ viewRect: NSRect) {
        guard let window = self.window else {
            completion(.cancelled)
            return
        }

        // Convert view rect to screen rect
        let windowRect = convert(viewRect, to: nil)
        let screenRect = window.convertToScreen(windowRect)

        // CG coordinates: origin top-left, NSScreen: origin bottom-left
        let mainScreenHeight = NSScreen.screens.first!.frame.height
        let cgRect = CGRect(
            x: screenRect.origin.x,
            y: mainScreenHeight - screenRect.maxY,
            width: screenRect.width,
            height: screenRect.height
        )

        // Hide all overlays, then capture using ScreenCaptureKit (excludes our windows automatically)
        hideAllOverlays()

        let completion = self.completion
        Task {
            if let image = await CaptureEngine.captureRegion(cgRect) {
                await MainActor.run { completion(.captured(image)) }
            } else {
                await MainActor.run { completion(.cancelled) }
            }
        }
    }

    private func captureWindow(_ windowID: CGWindowID) {
        hideAllOverlays()

        let completion = self.completion
        Task {
            if let image = await CaptureEngine.captureWindow(windowID: windowID) {
                await MainActor.run { completion(.captured(image)) }
            } else {
                await MainActor.run { completion(.cancelled) }
            }
        }
    }

    /// Compute the CG rect for burst mode and emit .burstRegionSelected
    private func emitBurstRegion(_ viewRect: NSRect) {
        guard let window = self.window else {
            completion(.cancelled)
            return
        }

        // Convert view rect to screen rect (same math as captureRegion)
        let windowRect = convert(viewRect, to: nil)
        let screenRect = window.convertToScreen(windowRect)

        // CG coordinates: origin top-left, NSScreen: origin bottom-left
        let mainScreenHeight = NSScreen.screens.first!.frame.height
        let cgRect = CGRect(
            x: screenRect.origin.x,
            y: mainScreenHeight - screenRect.maxY,
            width: screenRect.width,
            height: screenRect.height
        )

        hideAllOverlays()
        completion(.burstRegionSelected(cgRect))
    }

    /// Hide all windows at the overlay's window level so none appear in the capture.
    private func hideAllOverlays() {
        guard let myLevel = self.window?.level else { return }
        for window in NSApp.windows where window.level == myLevel {
            window.orderOut(nil)
        }
    }

    // MARK: - Coordinate Conversion

    /// Convert CG screen rect (origin top-left) to view-local NSRect (origin bottom-left).
    private func convertFromScreen(_ cgRect: CGRect) -> NSRect {
        guard let window = self.window else { return .zero }
        let mainScreenHeight = NSScreen.screens.first!.frame.height
        let nsScreenRect = NSRect(
            x: cgRect.origin.x,
            y: mainScreenHeight - cgRect.origin.y - cgRect.height,
            width: cgRect.width,
            height: cgRect.height
        )
        let windowRect = window.convertFromScreen(nsScreenRect)
        return convert(windowRect, from: nil)
    }
}
