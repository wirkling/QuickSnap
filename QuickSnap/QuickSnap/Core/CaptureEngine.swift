import AppKit
import ScreenCaptureKit

/// Screen capture using ScreenCaptureKit (macOS 12.3+).
/// SCK handles its own permission prompts and works reliably with Xcode debug builds.
struct CaptureEngine {

    /// Request screen recording access. Call early so the user sees the prompt.
    /// Uses CGPreflightScreenCaptureAccess / CGRequestScreenCaptureAccess instead of
    /// SCShareableContent to avoid the recurring permission dialog on macOS 15+.
    static func requestAccess() async -> Bool {
        if CGPreflightScreenCaptureAccess() {
            print("[QuickSnap] Screen recording already granted")
            return true
        }
        // This shows the system prompt once; user must restart the app after granting.
        let granted = CGRequestScreenCaptureAccess()
        print("[QuickSnap] Screen recording request result: \(granted)")
        return granted
    }

    /// Capture a rectangular region of the main display.
    static func captureRegion(_ rect: CGRect) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

            // Find the display that contains the rect
            guard let display = content.displays.first(where: { display in
                let displayBounds = CGRect(
                    x: CGFloat(display.frame.origin.x),
                    y: CGFloat(display.frame.origin.y),
                    width: CGFloat(display.width),
                    height: CGFloat(display.height)
                )
                return displayBounds.intersects(rect)
            }) else {
                print("[QuickSnap] No display found for rect \(rect)")
                return nil
            }

            // Exclude QuickSnap's own windows from the capture
            let myPID = ProcessInfo.processInfo.processIdentifier
            let excludedWindows = content.windows.filter { $0.owningApplication?.processID == myPID }

            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)

            let config = SCStreamConfiguration()
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            config.sourceRect = rect
            config.width = Int(rect.width * scale)
            config.height = Int(rect.height * scale)
            config.capturesAudio = false
            config.showsCursor = false

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return image

        } catch {
            print("[QuickSnap] SCK capture failed: \(error)")
            // Fall back to CGWindowListCreateImage
            return CGWindowListCreateImage(rect, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution])
        }
    }

    /// Capture a specific window by its CGWindowID.
    static func captureWindow(windowID: CGWindowID) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

            guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
                print("[QuickSnap] Window \(windowID) not found in SCK")
                return nil
            }

            let filter = SCContentFilter(desktopIndependentWindow: scWindow)

            let config = SCStreamConfiguration()
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            config.width = Int(CGFloat(scWindow.frame.width) * scale)
            config.height = Int(CGFloat(scWindow.frame.height) * scale)
            config.capturesAudio = false
            config.showsCursor = false

            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        } catch {
            print("[QuickSnap] SCK window capture failed: \(error)")
            return nil
        }
    }
}
