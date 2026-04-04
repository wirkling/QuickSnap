import AppKit
import SwiftUI

@MainActor
final class PostCapturePanel {
    private var panel: NSPanel?
    private var dismissTimer: Timer?
    private var isHovering = false
    private let itemID: UUID
    private let screenshotManager: ScreenshotManager
    private let onAnnotate: () -> Void
    private let onPin: () -> Void
    private let onDismiss: () -> Void
    private let onNameChanged: ((String) -> Void)?

    init(item: ScreenshotItem, screenshotManager: ScreenshotManager, onAnnotate: @escaping () -> Void, onPin: @escaping () -> Void, onDismiss: @escaping () -> Void, onNameChanged: ((String) -> Void)? = nil) {
        self.itemID = item.id
        self.screenshotManager = screenshotManager
        self.onAnnotate = onAnnotate
        self.onPin = onPin
        self.onDismiss = onDismiss
        self.onNameChanged = onNameChanged
        setupPanel(initialItem: item)
        startDismissTimer()
    }

    private func setupPanel(initialItem: ScreenshotItem) {
        let content = PostCapturePanelView(
            itemID: itemID,
            screenshotManager: screenshotManager,
            initialThumbnail: initialItem.thumbnail,
            initialFileURL: initialItem.fileURL,
            onAnnotate: { [weak self] in self?.onAnnotate(); self?.dismiss() },
            onPin: { [weak self] in self?.onPin(); self?.dismiss() },
            onCopy: { [weak self] in
                guard let self else { return }
                let item = self.screenshotManager.history.first { $0.id == self.itemID } ?? initialItem
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects([item.thumbnail])
            },
            onDismiss: { [weak self] in self?.dismiss() }
        )

        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 80)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 80),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = hosting
        panel.collectionBehavior = [.canJoinAllSpaces]

        // Position near top-right
        if let screen = NSScreen.main {
            let visibleFrame = screen.visibleFrame
            let x = visibleFrame.maxX - 380
            let y = visibleFrame.maxY - 100
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        // Track mouse for hover-to-pause
        let trackingView = HoverTrackingView(frame: hosting.bounds)
        trackingView.autoresizingMask = [.width, .height]
        trackingView.onHoverChanged = { [weak self] hovering in
            self?.isHovering = hovering
            if !hovering {
                self?.startDismissTimer()
            } else {
                self?.dismissTimer?.invalidate()
            }
        }
        hosting.addSubview(trackingView)

        panel.orderFront(nil)
        self.panel = panel
    }

    private func startDismissTimer() {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                if self?.isHovering == false {
                    self?.dismiss()
                }
            }
        }
    }

    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

// Helper NSView for mouse hover tracking
class HoverTrackingView: NSView {
    var onHoverChanged: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }
}

struct PostCapturePanelView: View {
    let itemID: UUID
    @ObservedObject var screenshotManager: ScreenshotManager
    let initialThumbnail: NSImage
    let initialFileURL: URL
    let onAnnotate: () -> Void
    let onPin: () -> Void
    let onCopy: () -> Void
    let onDismiss: () -> Void

    private var liveItem: ScreenshotItem? {
        screenshotManager.lastScreenshot?.id == itemID
            ? screenshotManager.lastScreenshot
            : screenshotManager.history.first { $0.id == itemID }
    }

    private var displayName: String {
        liveItem?.displayName ?? initialFileURL.deletingPathExtension().lastPathComponent
    }

    private var thumbnail: NSImage {
        liveItem?.thumbnail ?? initialThumbnail
    }

    private var fileURL: URL {
        liveItem?.fileURL ?? initialFileURL
    }

    private var isProcessing: Bool {
        guard let item = liveItem else { return true }
        return item.llmNamingStatus == .processing || item.llmCompareStatus == .processing
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 80, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .draggable(fileURL) {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 60, height: 45)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .opacity(0.8)
                }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if isProcessing {
                        ProgressView()
                            .controlSize(.small)
                            .colorScheme(.dark)
                    }
                    Text(isProcessing ? "Analyzing..." : displayName)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.25), value: displayName)
                        .animation(.easeInOut(duration: 0.25), value: isProcessing)
                }

                HStack(spacing: 14) {
                    panelButton("pencil.tip", label: "Annotate", action: onAnnotate)
                    panelButton("pin", label: "Pin", action: onPin)
                    panelButton("doc.on.clipboard", label: "Copy", action: onCopy)
                }
            }

            Spacer(minLength: 4)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(.black.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func panelButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.body)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.9))
        .help(label)
    }
}
