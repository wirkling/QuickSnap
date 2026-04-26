import AppKit
import SwiftUI

/// Floating panel showing pipeline processing progress and cost.
@MainActor
final class ProcessingProgressPanel: ObservableObject {
    private var panel: NSPanel?

    @Published var currentStage: String = "Preparing..."
    @Published var stageMessage: String = ""

    func show(costTracker: CostTracker) {
        guard panel == nil else { return }

        let view = ProcessingProgressView(
            panel: self,
            costTracker: costTracker
        )
        let hosting = NSHostingView(rootView: view)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 180),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = hosting

        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            let x = vf.midX - 200
            let y = vf.midY - 90
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFront(nil)
        self.panel = panel
    }

    func updateStage(_ stage: String, message: String) {
        currentStage = stage
        stageMessage = message
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}

struct ProcessingProgressView: View {
    @ObservedObject var panel: ProcessingProgressPanel
    @ObservedObject var costTracker: CostTracker

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Image(systemName: "gearshape.2.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.blue)
                Text("Processing Recording")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }

            // Stage
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .colorScheme(.dark)
                    Text(panel.currentStage)
                        .font(.system(size: 12, weight: .medium))
                }
                if !panel.stageMessage.isEmpty {
                    Text(panel.stageMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider().opacity(0.3)

            // Cost
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Estimated Cost")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(costTracker.formattedCost)
                        .font(.system(size: 18, weight: .semibold, design: .monospaced))
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("API Calls: \(costTracker.calls.count)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text("Tokens: \(costTracker.totalInputTokens + costTracker.totalOutputTokens)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.black.opacity(0.88))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        )
        .foregroundStyle(.white)
        .colorScheme(.dark)
    }
}
