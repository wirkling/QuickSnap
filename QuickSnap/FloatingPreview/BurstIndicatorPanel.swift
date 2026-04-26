import AppKit
import SwiftUI

@MainActor
final class BurstIndicatorPanel {
    private let panel: NSPanel
    private var hostingView: NSHostingView<BurstIndicatorView>
    private let onStop: () -> Void

    init(onStop: @escaping () -> Void) {
        self.onStop = onStop

        let view = BurstIndicatorView(count: 0, max: 20, onStop: onStop)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 200, height: 50)
        hostingView = hosting

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 50),
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

        // Position near top-center of main screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - 100
            let y = screenFrame.maxY - 70
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFront(nil)
    }

    func update(count: Int, max: Int) {
        hostingView.rootView = BurstIndicatorView(count: count, max: max, onStop: onStop)
    }

    func dismiss() {
        panel.orderOut(nil)
    }
}

struct BurstIndicatorView: View {
    let count: Int
    let max: Int
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
            Text("Burst: \(count)/\(max)")
                .font(.system(.caption, design: .monospaced, weight: .medium))
                .foregroundStyle(.white)
            Button("Stop") { onStop() }
                .buttonStyle(.plain)
                .font(.caption.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.red.opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
