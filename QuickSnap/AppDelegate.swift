import AppKit
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let folderService = FolderService()
    lazy var screenshotManager = ScreenshotManager(folderService: folderService)
    private var hotkeyManager: HotkeyManager?
    private var onboardingController: OnboardingWindowController?

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

        // Check Screen Recording permission and guide the user if not granted.
        Task {
            let granted = await CaptureEngine.requestAccess()
            print("[QuickSnap] Screen Recording permission: \(granted ? "GRANTED" : "NOT GRANTED")")
            if !granted {
                showScreenRecordingAlert()
            }
        }

        // Show onboarding on first launch
        if OnboardingWindowController.shouldShow {
            onboardingController = OnboardingWindowController()
            onboardingController?.show()
        }
    }

    private func showScreenRecordingAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = "QuickSnap needs Screen Recording access to capture screenshots.\n\nClick \"Open Settings\" and enable QuickSnap in the list. You may need to quit and relaunch the app afterwards."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")

        NSApp.activate(ignoringOtherApps: true)

        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
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
