import AppKit
import Foundation

/// Orchestrates a process recording session: smart screenshots, input logging, and timing.
@MainActor
final class ProcessRecordingController: ObservableObject {
    let session: ProcessRecordingSession

    private var clickMonitor: Any?
    private var appSwitchObserver: NSObjectProtocol?
    private var diffTimer: Timer?
    private var elapsedTimer: Timer?
    private var inputEventLogger: InputEventLogger?
    private var lastCapturedImage: NSImage?
    private var isCapturing = false // guard against re-entrancy

    let onStop: (ProcessRecordingSession) -> Void

    init(onStop: @escaping (ProcessRecordingSession) -> Void) {
        self.session = ProcessRecordingSession()
        self.onStop = onStop
    }

    // MARK: - Lifecycle

    func start() {
        NSLog("[QuickSnap] Process recording started — \(session.sessionFolder.path)")

        // Input event logger
        inputEventLogger = InputEventLogger(sessionStart: session.startedAt) { [weak self] kind, elapsed in
            self?.session.events.append(.inputEvent(timestamp: elapsed, kind: kind))
        }
        inputEventLogger?.start()

        // Click monitor — capture on every left mouse down
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, !self.session.isPaused else { return }
            let position = NSEvent.mouseLocation
            let appName = NSWorkspace.shared.frontmostApplication?.localizedName
            Task { @MainActor in
                self.session.events.append(.inputEvent(
                    timestamp: Date().timeIntervalSince(self.session.startedAt),
                    kind: .mouseClick(position: position, axLabel: nil, appName: appName)
                ))
                await self.captureFrame(trigger: .click)
            }
        }

        // App switch observer
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, !self.session.isPaused else { return }
            Task { @MainActor in
                // Small delay for the new app to render
                try? await Task.sleep(for: .milliseconds(400))
                await self.captureFrame(trigger: .appSwitch)
            }
        }

        // Diff-gated periodic capture (every 5s)
        diffTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self, !self.session.isPaused else { return }
            Task { @MainActor in
                await self.captureIfChanged()
            }
        }

        // Elapsed time counter
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.session.isPaused else { return }
                self.session.elapsed += 1
            }
        }
    }

    func pause() {
        session.isPaused = true
        NSLog("[QuickSnap] Recording paused at \(formatElapsed(session.elapsed))")
    }

    func resume() {
        session.isPaused = false
        NSLog("[QuickSnap] Recording resumed")
    }

    func stop() {
        tearDown()
        session.isRecording = false
        NSLog("[QuickSnap] Recording stopped: \(session.frameCount) frames, \(session.eventCount) events, \(formatElapsed(session.elapsed))")
        onStop(session)
    }

    func addNote(_ text: String) {
        let elapsed = Date().timeIntervalSince(session.startedAt)
        session.events.append(.userNote(timestamp: elapsed, text: text))
    }

    // MARK: - Capture

    private func captureFrame(trigger: CaptureTrigger) async {
        guard !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }

        guard let screen = NSScreen.main else {
            NSLog("[QuickSnap] Recording: no main screen")
            return
        }

        // Try multiple capture methods — SCK may fail on macOS 26 permission changes
        let cgImage: CGImage
        if let sckImage = await CaptureEngine.captureRegion(screen.frame) {
            cgImage = sckImage
        } else if let dispImage = CGDisplayCreateImage(CGMainDisplayID()) {
            // CGDisplayCreateImage is the most reliable fallback
            cgImage = dispImage
            if session.frameCount == 0 {
                NSLog("[QuickSnap] Recording: using CGDisplayCreateImage fallback")
            }
        } else {
            NSLog("[QuickSnap] Recording: ALL capture methods failed")
            return
        }

        let fullImage = NSImage(cgImage: cgImage, size: screen.frame.size)
        let apiImage = downscaleForAPI(cgImage, screenSize: screen.frame.size)

        let id = UUID()
        let elapsed = Date().timeIntervalSince(session.startedAt)
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName
        // Get window title by querying the frontmost window at screen center
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let mouseLocation = NSEvent.mouseLocation
        let cgPoint = CGPoint(x: mouseLocation.x, y: mainHeight - mouseLocation.y)
        let windowTitle = WindowDetector.windowAt(point: cgPoint)?.name

        // Save full-res PNG to session folder
        let filename = String(format: "frame-%04d-%@.png", session.frameCount, trigger.rawValue)
        let fileURL = session.sessionFolder.appendingPathComponent(filename)
        if let tiff = fullImage.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: fileURL)
        }

        let screenshot = RecordingScreenshot(
            id: id,
            timestamp: elapsed,
            trigger: trigger,
            fileURL: fileURL,
            apiImage: apiImage,
            appName: appName,
            windowTitle: windowTitle
        )
        session.screenshots.append(screenshot)
        session.events.append(.screenshot(
            id: id, timestamp: elapsed, trigger: trigger,
            appName: appName, windowTitle: windowTitle
        ))

        lastCapturedImage = fullImage
        NSLog("[QuickSnap] Frame \(session.frameCount): \(trigger.rawValue) — \(appName ?? "unknown")")
    }

    /// Only capture if the screen has changed significantly since the last frame.
    private func captureIfChanged() async {
        guard let screen = NSScreen.main,
              let cgImage = await CaptureEngine.captureRegion(screen.frame) else { return }

        let current = NSImage(cgImage: cgImage, size: screen.frame.size)

        if let last = lastCapturedImage {
            let diff = ImageComparisonService.pixelDifference(last, current)
            guard diff > ImageComparisonService.similarityThreshold else { return }
        }

        // Screen changed enough — save the frame
        await captureFrame(trigger: .diffGated)
    }

    /// Downscale to max 1280×800 for API consumption.
    private func downscaleForAPI(_ image: CGImage, screenSize: NSSize) -> NSImage {
        let maxW: CGFloat = 1280
        let maxH: CGFloat = 800
        let scale = min(maxW / screenSize.width, maxH / screenSize.height, 1.0)
        let targetSize = NSSize(width: screenSize.width * scale, height: screenSize.height * scale)

        let result = NSImage(size: targetSize)
        result.lockFocus()
        NSImage(cgImage: image, size: screenSize)
            .draw(in: NSRect(origin: .zero, size: targetSize))
        result.unlockFocus()
        return result
    }

    private func tearDown() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
        if let observer = appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appSwitchObserver = nil
        }
        diffTimer?.invalidate()
        diffTimer = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        inputEventLogger?.stop()
        inputEventLogger = nil
    }

    private func formatElapsed(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }
}
