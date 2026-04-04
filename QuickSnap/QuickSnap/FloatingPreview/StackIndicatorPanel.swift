import AppKit
import SwiftUI

@MainActor
final class StackIndicatorPanel {
    private let panel: NSPanel
    private var hostingView: NSHostingView<StackIndicatorView>
    private let onDone: () -> Void
    private let onCancel: () -> Void

    init(onDone: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onDone = onDone
        self.onCancel = onCancel

        let view = StackIndicatorView(count: 0, onDone: onDone, onCancel: onCancel)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 280, height: 50)
        hostingView = hosting

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 50),
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
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        panel.collectionBehavior = [.canJoinAllSpaces]
        panel.isMovableByWindowBackground = true

        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - 140
            let y = screenFrame.maxY - 70
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFront(nil)
    }

    func update(count: Int) {
        hostingView.rootView = StackIndicatorView(count: count, onDone: onDone, onCancel: onCancel)
    }

    func dismiss() {
        panel.orderOut(nil)
    }
}

struct StackIndicatorView: View {
    let count: Int
    let onDone: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 14))
                .foregroundStyle(.blue)

            Text("Stack: \(count) page\(count == 1 ? "" : "s")")
                .font(.system(.caption, design: .monospaced, weight: .medium))
                .foregroundStyle(.white)

            Button("Done") { onDone() }
                .buttonStyle(.plain)
                .font(.caption.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(count > 0 ? Color.green.opacity(0.8) : Color.gray.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .disabled(count == 0)

            Button("Cancel") { onCancel() }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.white.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
