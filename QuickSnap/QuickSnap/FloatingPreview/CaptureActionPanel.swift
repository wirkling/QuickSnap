import AppKit
import Combine
import SwiftUI

/// Capture modes shown in the action panel's segmented control.
enum CaptureActionMode: String, CaseIterable {
    case single, burst, stack
}

/// Lifecycle phases of the action panel.
enum CaptureActionPhase: Equatable {
    case idle                                 // overlay up, pre-capture chrome
    case stackCollecting(count: Int)          // stack mode active, between captures
    case postCapture(itemID: UUID)            // capture finished, show preview + actions
    case recording(elapsed: TimeInterval, events: Int, frames: Int) // process recording active
}

/// Observable state driving the action panel view. ScreenshotManager updates this;
/// the panel view observes and re-renders.
@MainActor
final class CaptureActionState: ObservableObject {
    @Published var phase: CaptureActionPhase = .idle
    @Published var mode: CaptureActionMode = .single
    @Published var destination: URL
    @Published var historyIndex: Int = 0
    @Published var isHovering: Bool = false
    @Published var isCollapsed: Bool = false

    var accumulatedScrollDelta: CGFloat = 0
    private let scrollThreshold: CGFloat = 2 // every tick = new card

    init(destination: URL) {
        self.destination = destination
    }

    /// Compute the item ID for the currently displayed carousel card.
    func currentItemID(postCaptureID: UUID, history: [ScreenshotItem]) -> UUID {
        if historyIndex == 0 { return postCaptureID }
        guard let baseIndex = history.firstIndex(where: { $0.id == postCaptureID }) else {
            return postCaptureID
        }
        let target = baseIndex + historyIndex
        guard history.indices.contains(target) else {
            return history.last?.id ?? postCaptureID
        }
        return history[target].id
    }

    /// Accumulate scroll delta and change card when threshold is reached (~2 scroll ticks).
    func scrollCarousel(delta: CGFloat, history: [ScreenshotItem], postCaptureID: UUID) {
        guard case .postCapture = phase else { return }
        guard let baseIndex = history.firstIndex(where: { $0.id == postCaptureID }) else { return }
        let maxOffset = max(0, history.count - 1 - baseIndex)

        accumulatedScrollDelta += delta

        if accumulatedScrollDelta < -scrollThreshold { // scroll down = older
            accumulatedScrollDelta = 0
            historyIndex = min(historyIndex + 1, maxOffset)
        } else if accumulatedScrollDelta > scrollThreshold { // scroll up = newer
            accumulatedScrollDelta = 0
            historyIndex = max(historyIndex - 1, 0)
        }
    }
}

/// NSHostingView subclass that reports `mouseDownCanMoveWindow = true` so the panel
/// can be dragged from any non-interactive region.
private final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
}

/// An NSView that reliably captures scroll wheel events and forwards them via a callback.
/// Used as the backing view for the scroll pad area.
private class ScrollCatcherNSView: NSView {
    var onScroll: ((CGFloat) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.3 else { return }
        onScroll?(delta)
    }

    override var acceptsFirstResponder: Bool { true }
}

/// SwiftUI wrapper for ScrollCatcherNSView.
private struct ScrollPadCatcher: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollCatcherNSView {
        let v = ScrollCatcherNSView()
        v.onScroll = onScroll
        return v
    }
    func updateNSView(_ nsView: ScrollCatcherNSView, context: Context) {
        nsView.onScroll = onScroll
    }
}

/// A floating, draggable action panel that mirrors macOS's native screenshot bar.
/// Lives across the whole capture lifecycle: idle → (stackCollecting) → postCapture.
@MainActor
final class CaptureActionPanel {
    let state: CaptureActionState
    private var panel: NSPanel?
    private var hostingView: DraggableHostingView<CaptureActionPanelView>?
    private weak var screenshotManager: ScreenshotManager?
    private weak var folderService: FolderService?

    // Auto-dismiss
    private var autoDismissTask: Task<Void, Never>?
    private var autoDismissElapsed: TimeInterval = 0
    private var hoverCancellable: AnyCancellable?
    private var indexCancellable: AnyCancellable?

    // Collapse to dot
    private var collapseTask: Task<Void, Never>?
    private var collapseElapsed: TimeInterval = 0
    private var expandedFrame: NSRect?
    private let collapseAfterSeconds: TimeInterval = 15

    // Callbacks wired by ScreenshotManager
    var onStartStack: (() -> Void)?
    var onFinishStack: (() -> Void)?
    var onCancelStack: (() -> Void)?
    var onTakeSnap: (() -> Void)?
    var onRemoveStackPage: ((Int) -> Void)?
    var onStopRecording: (() -> Void)?
    var onPauseRecording: (() -> Void)?
    var onResumeRecording: (() -> Void)?
    var onAddRecordingNote: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onAnnotate: ((UUID) -> Void)?
    var onPin: ((UUID) -> Void)?
    var onCopy: ((UUID) -> Void)?

    init(screenshotManager: ScreenshotManager, folderService: FolderService) {
        self.screenshotManager = screenshotManager
        self.folderService = folderService
        self.state = CaptureActionState(destination: folderService.effectiveDefault)
    }

    /// Show the panel in idle phase, resetting mode and destination to defaults.
    func showIdle() {
        pauseAutoDismissTimer()
        pauseCollapseTimer()
        exitCollapsedState()
        state.mode = .single
        state.historyIndex = 0
        if let fs = folderService {
            state.destination = fs.effectiveDefault
        }
        state.phase = .idle
        ensurePanel()
        revealPanel()
    }

    /// Transition to stack-collecting phase with current count.
    func showStackCollecting(count: Int) {
        pauseAutoDismissTimer()
        pauseCollapseTimer()
        exitCollapsedState()
        state.phase = .stackCollecting(count: count)
        ensurePanel()
        revealPanel()
    }

    /// Transition to process recording phase.
    func showRecording(elapsed: TimeInterval, events: Int, frames: Int) {
        pauseAutoDismissTimer()
        pauseCollapseTimer()
        exitCollapsedState()
        state.phase = .recording(elapsed: elapsed, events: events, frames: frames)
        ensurePanel()
        revealPanel()
    }

    /// Transition to post-capture phase (shows preview + actions).
    func showPostCapture(itemID: UUID) {
        exitCollapsedState()
        state.phase = .postCapture(itemID: itemID)
        state.historyIndex = 0
        state.accumulatedScrollDelta = 0
        ensurePanel()
        revealPanel()
        restartAutoDismissTimer()
        restartCollapseTimer()
    }

    /// Temporarily hide the panel (used during the actual screen capture so it doesn't
    /// appear in the shot). Use `revealPanel()` afterwards.
    func hideForCapture() {
        panel?.orderOut(nil)
    }

    /// Re-show the panel after `hideForCapture()`.
    func revealPanel() {
        panel?.orderFront(nil)
    }

    /// Fully tear down the panel.
    func dismiss() {
        pauseAutoDismissTimer()
        pauseCollapseTimer()
        hoverCancellable = nil
        indexCancellable = nil
        state.isCollapsed = false
        expandedFrame = nil
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
    }

    // MARK: - Auto-dismiss Timer

    private func startAutoDismissTimer() {
        let seconds = UserDefaults.standard.double(forKey: "QuickSnap.autoDismissSeconds")
        guard seconds > 0 else { return }
        autoDismissElapsed = 0
        autoDismissTask?.cancel()
        autoDismissTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                guard case .postCapture = self.state.phase else { return }
                self.autoDismissElapsed += 0.1
                if self.autoDismissElapsed >= seconds {
                    self.onCancel?()
                    return
                }
            }
        }
    }

    private func pauseAutoDismissTimer() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
    }

    private func restartAutoDismissTimer() {
        autoDismissElapsed = 0
        startAutoDismissTimer()
    }

    // MARK: - Collapse to Dot

    private func startCollapseTimer() {
        collapseElapsed = 0
        collapseTask?.cancel()
        collapseTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                guard case .postCapture = self.state.phase else { return }
                guard !self.state.isCollapsed else { return }
                self.collapseElapsed += 0.1
                if self.collapseElapsed >= self.collapseAfterSeconds {
                    self.collapsePanel()
                    return
                }
            }
        }
    }

    private func pauseCollapseTimer() {
        collapseTask?.cancel()
        collapseTask = nil
    }

    private func restartCollapseTimer() {
        collapseElapsed = 0
        startCollapseTimer()
    }

    /// Restore panel from collapsed dot to full size (if currently collapsed).
    private func exitCollapsedState() {
        guard state.isCollapsed, let panel, let frame = expandedFrame else {
            state.isCollapsed = false
            expandedFrame = nil
            return
        }
        panel.setFrame(frame, display: true)
        panel.hasShadow = true
        state.isCollapsed = false
        expandedFrame = nil
    }

    /// Shrink the panel to a small dot.
    private func collapsePanel() {
        guard let panel else { return }
        pauseAutoDismissTimer()
        expandedFrame = panel.frame
        state.isCollapsed = true
        panel.hasShadow = false
        let dotSize: CGFloat = 24
        let newX = panel.frame.midX - dotSize / 2
        let newY = panel.frame.midY - dotSize / 2
        panel.setFrame(NSRect(x: newX, y: newY, width: dotSize, height: dotSize), display: true)
    }

    /// Expand the panel back from the dot.
    private func expandPanel() {
        guard let panel, let expandedSize = expandedFrame?.size else { return }
        let dotCenter = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let newFrame = NSRect(
            x: dotCenter.x - expandedSize.width / 2,
            y: dotCenter.y - expandedSize.height / 2,
            width: expandedSize.width,
            height: expandedSize.height
        )
        panel.setFrame(newFrame, display: true)
        panel.hasShadow = true
        state.isCollapsed = false
        expandedFrame = nil
        restartCollapseTimer()
        restartAutoDismissTimer()
    }

    // MARK: - Panel Setup

    private func ensurePanel() {
        guard panel == nil, let sm = screenshotManager, let fs = folderService else { return }

        let rootView = CaptureActionPanelView(
            state: state,
            screenshotManager: sm,
            folderService: fs,
            onStartStack: { [weak self] in self?.onStartStack?() },
            onFinishStack: { [weak self] in self?.onFinishStack?() },
            onCancelStack: { [weak self] in self?.onCancelStack?() },
            onTakeSnap: { [weak self] in self?.onTakeSnap?() },
            onRemoveStackPage: { [weak self] index in self?.onRemoveStackPage?(index) },
            onStopRecording: { [weak self] in self?.onStopRecording?() },
            onPauseRecording: { [weak self] in self?.onPauseRecording?() },
            onResumeRecording: { [weak self] in self?.onResumeRecording?() },
            onAddRecordingNote: { [weak self] text in self?.onAddRecordingNote?(text) },
            onCancel: { [weak self] in self?.onCancel?() },
            onMinimize: { [weak self] in self?.collapsePanel() },
            onAnnotate: { [weak self] id in self?.onAnnotate?(id) },
            onPin: { [weak self] id in self?.onPin?(id) },
            onCopy: { [weak self] id in self?.onCopy?(id) }
        )

        let hosting = DraggableHostingView(rootView: rootView)
        self.hostingView = hosting

        // Scroll is handled by the ScrollPadCatcher NSViewRepresentable on the scroll pad.

        // Observe hover state for timer pause/resume and collapse expansion
        hoverCancellable = state.$isHovering.sink { [weak self] hovering in
            guard let self else { return }
            if hovering {
                self.pauseAutoDismissTimer()
                self.pauseCollapseTimer()
                if self.state.isCollapsed {
                    self.expandPanel()
                }
            } else {
                self.restartAutoDismissTimer()
                if !self.state.isCollapsed, case .postCapture = self.state.phase {
                    self.restartCollapseTimer()
                }
            }
        }

        // Reset timer when carousel index changes
        indexCancellable = state.$historyIndex.dropFirst().sink { [weak self] _ in
            self?.restartAutoDismissTimer()
        }

        // One level ABOVE the capture overlay so clicks on the panel are not intercepted
        // by the full-screen overlay window. CaptureOverlayView.hideAllOverlays() hides
        // any window at >= overlay level, so the panel is still hidden during the grab.
        let overlayLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 1)
        let panelLevel = NSWindow.Level(rawValue: overlayLevel.rawValue + 1)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 64),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // NOTE: order matters — `isFloatingPanel = true` resets `level` to `.floating`,
        // so we must set `level` AFTER it.
        panel.isFloatingPanel = true
        panel.level = panelLevel
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Force dark appearance so NSView-backed controls (segmented picker, menus)
        // render with light text on the dark panel background.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = hosting

        // Default position: top center of main screen
        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            let size = hosting.fittingSize
            let finalWidth = max(size.width, 560)
            let finalHeight = max(size.height, 64)
            let x = vf.midX - finalWidth / 2
            let y = vf.maxY - finalHeight - 24
            panel.setFrame(NSRect(x: x, y: y, width: finalWidth, height: finalHeight), display: false)
        }

        self.panel = panel
    }
}

// MARK: - SwiftUI View

struct CaptureActionPanelView: View {
    @ObservedObject var state: CaptureActionState
    @ObservedObject var screenshotManager: ScreenshotManager
    @ObservedObject var folderService: FolderService

    let onStartStack: () -> Void
    let onFinishStack: () -> Void
    let onCancelStack: () -> Void
    let onTakeSnap: () -> Void
    let onRemoveStackPage: (Int) -> Void
    let onStopRecording: () -> Void
    let onPauseRecording: () -> Void
    let onResumeRecording: () -> Void
    let onAddRecordingNote: (String) -> Void
    let onCancel: () -> Void
    let onMinimize: () -> Void
    let onAnnotate: (UUID) -> Void
    let onPin: (UUID) -> Void
    let onCopy: (UUID) -> Void

    @State private var showNoteField = false
    @State private var noteText = ""
    @State private var recPulse = false

    var body: some View {
        Group {
            switch state.phase {
            case .idle:
                cardChrome { idleContent }
            case .stackCollecting(let count):
                cardChrome { stackContent(count: count) }
            case .postCapture(let itemID):
                if state.isCollapsed {
                    collapsedDot
                } else {
                    carouselContent(postCaptureID: itemID)
                }
            case .recording(let elapsed, let events, let frames):
                cardChrome { recordingContent(elapsed: elapsed, events: events, frames: frames) }
            }
        }
        .foregroundStyle(.white)
        .colorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: state.phase)
        .animation(.easeInOut(duration: 0.2), value: state.isCollapsed)
        .onHover { state.isHovering = $0 }
        .onChange(of: screenshotManager.history.count) { _, newCount in
            guard case .postCapture(let itemID) = state.phase else { return }
            guard let baseIndex = screenshotManager.history.firstIndex(where: { $0.id == itemID }) else { return }
            let maxOffset = max(0, newCount - 1 - baseIndex)
            if state.historyIndex > maxOffset {
                state.historyIndex = maxOffset
            }
        }
    }

    /// Standard pill chrome used for idle and stack phases.
    private func cardChrome<C: View>(@ViewBuilder content: () -> C) -> some View {
        HStack(spacing: 12) { content() }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.black.opacity(0.82))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
            )
    }

    // MARK: - Idle (pre-capture)

    private var idleContent: some View {
        HStack(spacing: 12) {
            Picker("", selection: $state.mode) {
                Image(systemName: "camera.viewfinder").tag(CaptureActionMode.single)
                Image(systemName: "square.stack").tag(CaptureActionMode.burst)
                Image(systemName: "square.stack.3d.up").tag(CaptureActionMode.stack)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .onChange(of: state.mode) { _, newMode in
                if newMode == .stack { onStartStack() }
            }
            .help("Capture mode")

            divider
            folderMenu
            divider

            Text(hintText)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
                .frame(minWidth: 160, alignment: .leading)

            Spacer(minLength: 0)
            closeButton
        }
    }

    private var hintText: String {
        switch state.mode {
        case .single: return "Click a window or drag a region"
        case .burst:  return "Drag a region — captures every 2s"
        case .stack:  return ""
        }
    }

    // MARK: - Stack collecting

    private func stackContent(count: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 14))
                .foregroundStyle(.blue)

            Text("\(count)")
                .font(.system(.callout, design: .monospaced, weight: .semibold))
                .frame(minWidth: 14)

            divider

            if count > 0 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(screenshotManager.stackThumbnails.enumerated()), id: \.offset) { index, thumb in
                            StackThumbnail(image: thumb, index: index, onRemove: onRemoveStackPage)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .frame(maxWidth: 260, maxHeight: 44)
            } else {
                Text("No pages yet — click or drag to capture")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }

            divider
            folderMenu
            Spacer(minLength: 4)

            Button(action: onTakeSnap) {
                Label("Snap", systemImage: "camera.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.blue.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("Capture the next page (⌘⇧4)")

            Button(action: onFinishStack) {
                Label("Finish", systemImage: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(count > 0 ? Color.green.opacity(0.85) : Color.gray.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(count == 0)
            .help("Finish stack and save PDF")

            Button(action: onCancelStack) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("Cancel stack")
        }
    }

    // MARK: - Recording

    private func recordingContent(elapsed: TimeInterval, events: Int, frames: Int) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                // Pulsing red dot
                Circle()
                    .fill(.red)
                    .frame(width: 10, height: 10)
                    .opacity(recPulse ? 0.35 : 1.0)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: recPulse)
                    .onAppear { recPulse = true }

                Text("REC")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.red)

                Text(formatRecordingTime(elapsed))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))

                divider

                Label("\(frames)", systemImage: "camera.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.7))
                Label("\(events)", systemImage: "list.bullet")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.7))

                Spacer(minLength: 4)

                // Add note
                Button {
                    showNoteField.toggle()
                } label: {
                    Image(systemName: "note.text.badge.plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Add a timestamped note")

                divider

                // Pause / Resume
                Button {
                    if screenshotManager.recordingController?.session.isPaused == true {
                        onResumeRecording()
                    } else {
                        onPauseRecording()
                    }
                } label: {
                    Image(systemName: screenshotManager.recordingController?.session.isPaused == true ? "play.fill" : "pause.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Pause / Resume")

                // Stop
                Button(action: onStopRecording) {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10))
                        Text("Stop")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.red.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Stop recording and process")
            }

            // Inline note field (slides open when Add Note is tapped)
            if showNoteField {
                HStack(spacing: 8) {
                    TextField("Add a note...", text: $noteText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .padding(6)
                        .background(.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .onSubmit {
                            if !noteText.isEmpty {
                                onAddRecordingNote(noteText)
                                noteText = ""
                                showNoteField = false
                            }
                        }
                    Button("Add") {
                        if !noteText.isEmpty {
                            onAddRecordingNote(noteText)
                            noteText = ""
                            showNoteField = false
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.blue)
                }
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private func formatRecordingTime(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    // MARK: - Time Machine Carousel

    private func carouselContent(postCaptureID: UUID) -> some View {
        let currentID = state.currentItemID(
            postCaptureID: postCaptureID,
            history: screenshotManager.history
        )
        let bgCards = backgroundCardIDs(for: postCaptureID)
        let total = totalCarouselCount(postCaptureID: postCaptureID)

        // VStack with negative spacing creates overlapping cards that participate
        // in real layout (unlike offset, which clips outside the parent bounds).
        return VStack(spacing: -52) {
            ForEach(Array(bgCards.reversed().enumerated()), id: \.element) { reverseDepth, bgID in
                let depth = Double(bgCards.count - reverseDepth)
                backgroundCard(id: bgID)
                    .scaleEffect(1 - 0.05 * depth, anchor: .bottom)
                    .opacity(max(0, 1 - 0.25 * depth))
                    .zIndex(-depth)
            }

            // Front card (interactive) with scroll pad on the right
            frontCard(id: currentID, total: total, postCaptureID: postCaptureID)
                .zIndex(10)
                .id(currentID)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: currentID)
    }

    /// Full interactive card for the currently focused item.
    private func frontCard(id itemID: UUID, total: Int, postCaptureID: UUID) -> some View {
        let item = liveItem(id: itemID)
        return HStack(spacing: 0) {
            // Main content area
            HStack(spacing: 12) {
                if let item {
                    ZStack {
                        Image(nsImage: item.thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 72, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        FileDragSource(fileURL: item.fileURL, thumbnail: item.thumbnail)
                    }
                    .frame(width: 72, height: 54)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            if item.llmNamingStatus == .processing {
                                ProgressView()
                                    .controlSize(.small)
                                    .colorScheme(.dark)
                            }
                            Text(item.llmNamingStatus == .processing ? "Analyzing…" : item.displayName)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if let desc = item.llmDescription, !desc.isEmpty {
                            Text(oneLiner(desc))
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.65))
                                .lineLimit(2)
                                .truncationMode(.tail)
                        }
                        Text(shortPath(item.fileURL.deletingLastPathComponent()))
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // 2×2 action grid — compact to leave room for text
                    VStack(spacing: 3) {
                        HStack(spacing: 3) {
                            actionButton("pencil.tip", help: "Annotate") { onAnnotate(itemID) }
                            actionButton("pin", help: "Pin") { onPin(itemID) }
                        }
                        HStack(spacing: 3) {
                            actionButton("doc.on.clipboard", help: "Copy") { onCopy(itemID) }
                            actionButton("folder", help: "Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
                            }
                        }
                    }

                    minimizeButton
                    closeButton
                } else {
                    Text("Capture ready")
                        .font(.system(size: 12))
                    Spacer(minLength: 4)
                    minimizeButton
                    closeButton
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            // Scroll pad — visible only when there's history to scroll through
            if total > 1 {
                scrollPad(total: total, postCaptureID: postCaptureID)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.black.opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    /// A vertical scroll pad with grip lines, chevrons, and position counter.
    /// Uses an NSView-backed scroll catcher for reliable scroll event capture.
    private func scrollPad(total: Int, postCaptureID: UUID) -> some View {
        let canGoUp = state.historyIndex > 0
        let canGoDown = state.historyIndex < total - 1

        return ZStack {
            // Invisible NSView that reliably captures scroll wheel events
            ScrollPadCatcher { delta in
                state.scrollCarousel(
                    delta: delta,
                    history: screenshotManager.history,
                    postCaptureID: postCaptureID
                )
            }

            // Chrome: clickable chevrons + grip + counter
            VStack(spacing: 4) {
                Button {
                    guard canGoUp else { return }
                    state.historyIndex -= 1
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(canGoUp ? 0.85 : 0.2))
                        .frame(width: 28, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canGoUp)

                // Grip dots
                VStack(spacing: 3) {
                    ForEach(0..<2, id: \.self) { _ in
                        HStack(spacing: 3) {
                            Circle().frame(width: 2, height: 2)
                            Circle().frame(width: 2, height: 2)
                        }
                        .foregroundStyle(.white.opacity(0.25))
                    }
                }
                .allowsHitTesting(false)

                Text("\(state.historyIndex + 1)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .allowsHitTesting(false)

                VStack(spacing: 3) {
                    ForEach(0..<2, id: \.self) { _ in
                        HStack(spacing: 3) {
                            Circle().frame(width: 2, height: 2)
                            Circle().frame(width: 2, height: 2)
                        }
                        .foregroundStyle(.white.opacity(0.25))
                    }
                }
                .allowsHitTesting(false)

                Button {
                    guard canGoDown else { return }
                    state.historyIndex += 1
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(canGoDown ? 0.85 : 0.2))
                        .frame(width: 28, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canGoDown)
            }
        }
        .frame(width: 36)
        .padding(.vertical, 6)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                    bottomTrailingRadius: 14, topTrailingRadius: 14)
                .fill(.white.opacity(0.06))
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(.white.opacity(0.1))
                .frame(width: 0.5)
        }
        .help("Scroll or click arrows to browse captures")
    }

    /// Simplified non-interactive card peeking behind the front card.
    private func backgroundCard(id itemID: UUID) -> some View {
        HStack(spacing: 12) {
            if let item = liveItem(id: itemID) {
                Image(nsImage: item.thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 72, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Text(item.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.5))

                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.black.opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
        )
        .allowsHitTesting(false)
    }

    /// IDs of the 1-2 items behind the current carousel position.
    private func backgroundCardIDs(for postCaptureID: UUID) -> [UUID] {
        let history = screenshotManager.history
        guard let baseIndex = history.firstIndex(where: { $0.id == postCaptureID }) else { return [] }
        let current = baseIndex + state.historyIndex
        var result: [UUID] = []
        for offset in 1...2 {
            let idx = current + offset
            guard history.indices.contains(idx) else { break }
            result.append(history[idx].id)
        }
        return result
    }

    private func totalCarouselCount(postCaptureID: UUID) -> Int {
        let history = screenshotManager.history
        guard let baseIndex = history.firstIndex(where: { $0.id == postCaptureID }) else { return 1 }
        return history.count - baseIndex
    }

    // MARK: - Shared bits

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.15))
            .frame(width: 1, height: 22)
    }

    private var minimizeButton: some View {
        Button {
            onMinimize()
        } label: {
            Image(systemName: "minus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 22, height: 22)
                .background(.white.opacity(0.08))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Minimize to dot")
    }

    private var closeButton: some View {
        Button {
            state.historyIndex = 0
            onCancel()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 22, height: 22)
                .background(.white.opacity(0.08))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Close")
    }

    private func actionButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 28, height: 28)
                .background(.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var folderMenu: some View {
        Menu {
            Button {
                state.destination = folderService.effectiveDefault
            } label: {
                Label("Default (\(folderService.effectiveDefault.lastPathComponent))",
                      systemImage: "star.fill")
            }

            if !folderService.presetFolders.isEmpty {
                Divider()
                ForEach(folderService.presetFolders, id: \.self) { url in
                    Button {
                        state.destination = url
                    } label: {
                        Label(url.lastPathComponent, systemImage: "folder.fill")
                    }
                }
            }

            if !folderService.recentFolders.isEmpty {
                Divider()
                ForEach(folderService.recentFolders.prefix(5), id: \.self) { url in
                    Button {
                        state.destination = url
                    } label: {
                        Label(url.lastPathComponent, systemImage: "clock")
                    }
                }
            }

            Divider()

            Button {
                pickCustomFolder()
            } label: {
                Label("Other…", systemImage: "folder.badge.questionmark")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                Text(state.destination.lastPathComponent)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .opacity(0.7)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.white.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(maxWidth: 160)
        .help("Save to folder")
    }

    private func pickCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Save Here"
        if panel.runModal() == .OK, let url = panel.url {
            state.destination = url
        }
    }

    // MARK: - Collapsed Dot

    private var collapsedDot: some View {
        Circle()
            .fill(.black.opacity(0.85))
            .frame(width: 14, height: 14)
            .overlay(
                Circle()
                    .strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
            )
            .padding(5)
    }

    // MARK: - Helpers

    private func liveItem(id: UUID) -> ScreenshotItem? {
        if screenshotManager.lastScreenshot?.id == id {
            return screenshotManager.lastScreenshot
        }
        return screenshotManager.history.first { $0.id == id }
    }

    private func shortPath(_ url: URL) -> String {
        let path = url.path
        if let range = path.range(of: NSHomeDirectory()) {
            return "~" + path[range.upperBound...]
        }
        return path
    }

    /// Extract an additive sentence from the description — skips the first sentence
    /// (which usually restates the filename) and returns the second one with more detail.
    private func oneLiner(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Split into sentences
        var sentences: [String] = []
        trimmed.enumerateSubstrings(in: trimmed.startIndex..., options: .bySentences) { sub, _, _, _ in
            if let s = sub?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                sentences.append(s)
            }
        }
        // Use second sentence if available (more additive); fall back to first
        let best = sentences.count > 1 ? sentences[1] : sentences.first ?? trimmed
        if best.count > 100 {
            let end = best.index(best.startIndex, offsetBy: 100)
            return String(best[..<end]) + "…"
        }
        return best
    }
}

/// One thumbnail in the stack strip. Shows a red remove button on hover.
private struct StackThumbnail: View {
    let image: NSImage
    let index: Int
    let onRemove: (Int) -> Void
    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 52, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
                )

            Text("\(index + 1)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(Color.black.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .padding(2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

            if isHovering {
                Button {
                    onRemove(index)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white, .red)
                        .background(Circle().fill(.white).scaleEffect(0.85))
                }
                .buttonStyle(.plain)
                .padding(-4)
                .help("Remove this page")
            }
        }
        .onHover { isHovering = $0 }
    }
}

// MARK: - File Drag Source

/// Transparent overlay that handles drag-to-paste for a file URL.
/// Returns `mouseDownCanMoveWindow = false` so the panel doesn't move when
/// the user drags the thumbnail.
private struct FileDragSource: NSViewRepresentable {
    let fileURL: URL
    let thumbnail: NSImage

    func makeNSView(context: Context) -> FileDragSourceNSView {
        let v = FileDragSourceNSView()
        v.fileURL = fileURL
        v.thumbnailImage = thumbnail
        return v
    }

    func updateNSView(_ nsView: FileDragSourceNSView, context: Context) {
        nsView.fileURL = fileURL
        nsView.thumbnailImage = thumbnail
    }
}

/// NSView that initiates a file-URL drag session. `mouseDownCanMoveWindow`
/// returns `false` so the enclosing panel stays put during the drag.
private class FileDragSourceNSView: NSView, NSDraggingSource {
    var fileURL: URL?
    var thumbnailImage: NSImage?
    private var dragOrigin: NSPoint?

    override var mouseDownCanMoveWindow: Bool { false }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin, let fileURL else { return }
        let current = convert(event.locationInWindow, from: nil)
        let distance = hypot(current.x - origin.x, current.y - origin.y)
        guard distance > 4 else { return }
        dragOrigin = nil

        let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        let imageSize = NSSize(width: 60, height: 45)
        item.setDraggingFrame(
            NSRect(x: current.x - imageSize.width / 2,
                   y: current.y - imageSize.height / 2,
                   width: imageSize.width,
                   height: imageSize.height),
            contents: thumbnailImage
        )
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
    }
}
