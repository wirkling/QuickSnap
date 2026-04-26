import AppKit

enum CaptureResult {
    case captured(CGImage)
    case burstRegionSelected(CGRect)  // CG coordinates for burst capture
    case cancelled
}

/// Manages one or more fullscreen transparent overlay windows (one per screen)
/// for the capture interaction.
@MainActor
final class CaptureOverlayController {
    private var windows: [CaptureOverlayWindow] = []
    private let completion: (CaptureResult) -> Void
    var onStartStack: (() -> Void)?
    /// Read the current capture mode from an external source (e.g. CaptureActionPanel).
    var captureModeProvider: (() -> CaptureOverlayView.CaptureMode)?

    init(completion: @escaping (CaptureResult) -> Void) {
        self.completion = completion
    }

    func show() {
        // Create an overlay on each screen
        for screen in NSScreen.screens {
            let window = CaptureOverlayWindow(screen: screen) { [weak self] result in
                self?.handleResult(result)
            }
            window.overlayView.onStartStack = onStartStack
            window.overlayView.captureModeProvider = captureModeProvider
            windows.append(window)
        }
    }

    func dismiss() {
        for window in windows {
            window.close()
        }
        windows.removeAll()
    }

    private func handleResult(_ result: CaptureResult) {
        dismiss()
        completion(result)
    }
}
