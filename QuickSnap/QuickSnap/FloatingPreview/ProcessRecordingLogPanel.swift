import AppKit
import SwiftUI

/// Floating panel showing a live scrolling log of recording events.
@MainActor
final class ProcessRecordingLogPanel {
    private var panel: NSPanel?

    func show(session: ProcessRecordingSession) {
        guard panel == nil else { return }

        let view = ProcessRecordingLogView(session: session)
        let hosting = NSHostingView(rootView: view)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Recording Log"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
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

        // Position: bottom-right of main screen
        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            let x = vf.maxX - 440
            let y = vf.origin.y + 20
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFront(nil)
        self.panel = panel
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: - SwiftUI View

struct ProcessRecordingLogView: View {
    @ObservedObject var session: ProcessRecordingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "terminal")
                    .font(.system(size: 11, weight: .semibold))
                Text("Recording Log")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(session.eventCount) events")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.white.opacity(0.05))

            Divider().opacity(0.3)

            // Scrolling log
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(session.events.enumerated()), id: \.offset) { index, event in
                            logRow(event)
                                .id(index)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .onChange(of: session.events.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(session.events.count - 1, anchor: .bottom)
                    }
                }
            }

            Divider().opacity(0.3)

            // Footer
            HStack(spacing: 12) {
                Label("\(session.frameCount)", systemImage: "camera.fill")
                Label("\(session.eventCount)", systemImage: "list.bullet")
                Spacer()
                Text(formatElapsed(session.elapsed))
                    .font(.system(.caption, design: .monospaced, weight: .medium))
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(minWidth: 360, minHeight: 200)
        .background(.black.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .foregroundStyle(.white)
        .colorScheme(.dark)
    }

    private func logRow(_ event: RecordingEvent) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(formatTimestamp(event.timestamp))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 38, alignment: .trailing)

            Text(eventIcon(event))
                .font(.system(size: 10))
                .frame(width: 16)

            Text(eventText(event))
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }

    private func eventIcon(_ event: RecordingEvent) -> String {
        switch event {
        case .screenshot: return "📸"
        case .inputEvent(_, let kind):
            switch kind {
            case .mouseClick: return "🖱"
            case .keyboardShortcut: return "⌨️"
            case .clipboardChange: return "📋"
            }
        case .userNote: return "📝"
        }
    }

    private func eventText(_ event: RecordingEvent) -> String {
        switch event {
        case .screenshot(_, _, let trigger, let app, let window):
            return "\(trigger.rawValue) — \(app ?? "?") \(window ?? "")"
        case .inputEvent(_, let kind):
            switch kind {
            case .mouseClick(_, let label, let app):
                return "\(app ?? "?") — \(label ?? "click")"
            case .keyboardShortcut(let keys):
                return keys
            case .clipboardChange(let preview):
                return String(preview.prefix(60))
            }
        case .userNote(_, let text):
            return text
        }
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }

    private func formatElapsed(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
