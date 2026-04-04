import AppKit
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let screenshotManager = ScreenshotManager()
    let folderService = FolderService()
    private var hotkeyManager: HotkeyManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        hotkeyManager = HotkeyManager { [weak self] in
            Task { @MainActor in
                self?.screenshotManager.startCapture()
            }
        }
        hotkeyManager?.register()

        // Request Screen Recording permission via ScreenCaptureKit.
        // SCK manages its own permission prompt and works reliably with Xcode debug builds.
        Task {
            let granted = await CaptureEngine.requestAccess()
            print("[QuickSnap] Screen Recording permission: \(granted ? "GRANTED" : "NOT GRANTED")")
        }
    }
}
