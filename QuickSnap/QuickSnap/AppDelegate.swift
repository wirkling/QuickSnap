import AppKit
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let folderService = FolderService()
    lazy var screenshotManager = ScreenshotManager(folderService: folderService)
    private var hotkeyManager: HotkeyManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        hotkeyManager = HotkeyManager(
            captureAction: { [weak self] in
                Task { @MainActor in
                    self?.screenshotManager.startCapture()
                }
            },
            recordAction: { [weak self] in
                Task { @MainActor in
                    self?.toggleRecording()
                }
            }
        )
        hotkeyManager?.register()

        // Request Screen Recording permission via ScreenCaptureKit.
        Task {
            let granted = await CaptureEngine.requestAccess()
            print("[QuickSnap] Screen Recording permission: \(granted ? "GRANTED" : "NOT GRANTED")")
        }
    }

    private func toggleRecording() {
        if screenshotManager.isRecording {
            screenshotManager.stopProcessRecording()
        } else {
            screenshotManager.startProcessRecording()
        }
    }
}
