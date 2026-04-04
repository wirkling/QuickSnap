import AppKit

/// A floating, always-on-top panel that displays a pinned screenshot.
final class PinnedScreenshotPanel {
    private let panel: NSPanel

    init(image: NSImage, title: String) {
        let imageSize = image.size
        let maxDimension: CGFloat = 500
        let scale = min(maxDimension / imageSize.width, maxDimension / imageSize.height, 1.0)
        let displaySize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)

        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: displaySize),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.title = title
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let imageView = NSImageView(frame: NSRect(origin: .zero, size: displaySize))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]

        panel.contentView = imageView
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        panel.orderOut(nil)
    }
}
