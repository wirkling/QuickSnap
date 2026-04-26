import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var screenshotManager: ScreenshotManager
    @ObservedObject var folderService: FolderService
    @State private var showFolderPicker = false
    @State private var selectedHistoryItemID: UUID?
    @State private var hasAPIKey = false
    @State private var providerName = ""
    @State private var isUsingClaude = false
    @State private var editingItemID: UUID?
    @State private var editName: String = ""
    @State private var editDescription: String = ""
    @Environment(\.openSettings) private var openSettings
    @State private var onboardingController: OnboardingWindowController?

    /// Live lookup — always returns the latest data from the published history array.
    private var selectedHistoryItem: ScreenshotItem? {
        guard let id = selectedHistoryItemID else { return nil }
        return screenshotManager.history.first { $0.id == id }
    }

    /// The item whose full detail is shown at the top — either a selected Recent item, or the last capture.
    private var detailItem: ScreenshotItem? {
        selectedHistoryItem ?? screenshotManager.lastScreenshot
    }

    private var detailLabel: String {
        selectedHistoryItem != nil ? "Selected" : "Just now"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            heroRow
                .padding(.horizontal, 12)
                .padding(.bottom, 12)

            if let item = detailItem {
                lastCaptureCard(item)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            } else {
                emptyState
            }

            Divider()

            if showFolderPicker {
                FolderPickerView(
                    folderService: folderService,
                    screenshotURL: (selectedHistoryItem?.fileURL ?? screenshotManager.lastScreenshot?.fileURL),
                    onMoved: { newURL in
                        if let id = selectedHistoryItemID,
                           let idx = screenshotManager.history.firstIndex(where: { $0.id == id }) {
                            screenshotManager.history[idx].fileURL = newURL
                        }
                        screenshotManager.lastScreenshot?.fileURL = newURL
                        showFolderPicker = false
                    }
                )
                Divider()
            }

            HistoryGridView(selectedItemID: $selectedHistoryItemID)
                .padding(.bottom, 4)

            Divider()

            footer
        }
        .frame(width: 460)
        .onChange(of: selectedHistoryItemID) {
            editingItemID = nil
        }
        .onAppear {
            Task {
                hasAPIKey = await screenshotManager.llmNamingService.hasAPIKey()
                providerName = await screenshotManager.llmNamingService.providerName
                isUsingClaude = await screenshotManager.llmNamingService.isUsingClaude
            }
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.34, green: 0.48, blue: 0.82),
                                 Color(red: 0.46, green: 0.38, blue: 0.80)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    Image(systemName: "camera.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                )
                .frame(width: 22, height: 22)
                .shadow(color: .black.opacity(0.12), radius: 1, y: 1)

            VStack(alignment: .leading, spacing: 1) {
                Text("QuickSnap")
                    .font(.system(size: 13, weight: .semibold))
                statusLine
            }

            Spacer()

            ToolbarButton(icon: "clock.arrow.circlepath", label: "Open captures folder") {
                NSWorkspace.shared.open(folderService.effectiveDefault)
            }
            ToolbarButton(icon: "gearshape", label: "Settings") {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var statusLine: some View {
        if screenshotManager.isRecording {
            HStack(spacing: 4) {
                Circle().fill(.red).frame(width: 6, height: 6)
                    .modifier(PulseOpacity())
                Text("Recording")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
            }
        } else if screenshotManager.isStackMode {
            HStack(spacing: 4) {
                Circle().fill(.blue).frame(width: 6, height: 6)
                Text("Stacking · \(screenshotManager.stackCount) \(screenshotManager.stackCount == 1 ? "page" : "pages")")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.blue)
            }
        } else {
            HStack(spacing: 4) {
                Circle().fill(.green).frame(width: 6, height: 6)
                Text("Idle · \(screenshotManager.history.count) \(screenshotManager.history.count == 1 ? "capture" : "captures")")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Hero row

    private var heroRow: some View {
        HStack(spacing: 6) {
            HeroCaptureButton(
                title: "Capture Screenshot",
                shortcut: "⌘⇧4"
            ) {
                screenshotManager.startCapture()
            }

            ModeChipButton(
                icon: screenshotManager.isStackMode ? "square.stack.3d.up.fill" : "square.stack.3d.up",
                label: screenshotManager.isStackMode ? "Finish" : "Stack",
                tone: screenshotManager.isStackMode ? .blue : .neutral,
                help: screenshotManager.isStackMode ? "Finish stack" : "Start Stack"
            ) {
                if screenshotManager.isStackMode {
                    screenshotManager.finishStack()
                } else {
                    screenshotManager.startStackMode()
                }
            }

            ModeChipButton(
                icon: screenshotManager.isRecording ? "stop.circle.fill" : "record.circle",
                label: screenshotManager.isRecording ? "Stop" : "Record",
                tone: screenshotManager.isRecording ? .red : .neutral,
                help: screenshotManager.isRecording ? "Stop recording" : "Record Process (⌘⇧R)"
            ) {
                if screenshotManager.isRecording {
                    screenshotManager.stopProcessRecording()
                } else {
                    screenshotManager.startProcessRecording()
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No screenshots yet")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("Press ⌘⇧4 to capture")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.bottom, 4)
    }

    // MARK: - Last capture card

    @ViewBuilder
    private func lastCaptureCard(_ item: ScreenshotItem) -> some View {
        let isEditing = editingItemID == item.id

        HStack(alignment: .top, spacing: 12) {
            DraggableThumbnailView(
                image: item.thumbnail,
                fileURL: item.fileURL,
                size: CGSize(width: 118, height: 88),
                burstImageURLs: item.burstImageURLs,
                isStack: item.isStack,
                stackPageCount: item.stackPageURLs?.count ?? 0,
                pdfURL: item.pdfURL
            )

            VStack(alignment: .leading, spacing: 4) {
                // Meta row: relative time + AI chip + status
                HStack(spacing: 6) {
                    Text(detailLabel == "Selected" ? "Selected" : relativeTime(for: item.createdAt))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)

                    if item.llmName != nil {
                        AiNamedChip()
                    } else if item.llmNamingStatus == .processing {
                        ProcessingChip()
                    }

                    Spacer()

                    LLMStatusBadge(naming: item.llmNamingStatus, compare: item.llmCompareStatus)
                }

                if isEditing {
                    TextField("Name", text: $editName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onSubmit { saveEdit(for: item) }
                } else {
                    Text(item.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if isEditing {
                    TextField("Description", text: $editDescription, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .lineLimit(3...8)
                } else if let desc = item.llmDescription {
                    Text(desc)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let comparison = item.comparisonDescription, !isEditing {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                        Text(comparison)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                    .padding(.top, 2)
                }

                // Named action row
                if isEditing {
                    HStack(spacing: 6) {
                        PillButton(title: "Save", icon: "checkmark", style: .primary) {
                            saveEdit(for: item)
                        }
                        PillButton(title: "Cancel", icon: nil, style: .secondary) {
                            editingItemID = nil
                        }
                    }
                    .padding(.top, 4)
                } else {
                    HStack(spacing: 4) {
                        NamedActionButton(icon: "pencil.tip", label: "Annotate") {
                            screenshotManager.annotate(item)
                        }
                        NamedActionButton(icon: "doc.on.doc", label: "Copy") {
                            copyToClipboard(item)
                        }
                        Menu {
                            if item.llmName != nil {
                                Button {
                                    startEditing(item)
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                            }
                            if item.llmNamingStatus == .done {
                                Button {
                                    screenshotManager.boostItem(itemID: item.id)
                                } label: {
                                    Label("Boost — re-analyze with Opus", systemImage: "bolt.fill")
                                }
                            }
                            Button {
                                screenshotManager.pin(item)
                            } label: {
                                Label("Pin on screen", systemImage: "pin")
                            }
                            Divider()
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
                            } label: {
                                Label("Reveal in Finder", systemImage: "folder")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 26, height: 22)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.primary.opacity(0.04))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                                        )
                                )
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("More")
                    }
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            FolderChip(
                title: folderChipTitle,
                disabled: detailItem == nil
            ) {
                showFolderPicker.toggle()
            }

            ProviderPill(
                name: providerName.isEmpty ? "AI" : providerName,
                usingClaude: isUsingClaude,
                hasKey: hasAPIKey
            )

            Spacer()

            ToolbarButton(icon: "questionmark.circle", label: "Guide") {
                let controller = OnboardingWindowController()
                controller.show()
                onboardingController = controller
            }

            Menu {
                Button("Settings…") {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button("Guide") {
                    let controller = OnboardingWindowController()
                    controller.show()
                    onboardingController = controller
                }
                Divider()
                Button("Quit QuickSnap") {
                    NSApplication.shared.terminate(nil)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var folderChipTitle: String {
        let url = folderService.effectiveDefault
        let path = url.path
        if path.hasPrefix(NSHomeDirectory()) {
            return "~" + path.dropFirst(NSHomeDirectory().count)
        }
        return url.lastPathComponent
    }

    // MARK: - Helpers

    private func relativeTime(for date: Date) -> String {
        let delta = Date().timeIntervalSince(date)
        if delta < 60 { return "Just now" }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        return fmt.localizedString(for: date, relativeTo: Date())
    }

    private func startEditing(_ item: ScreenshotItem) {
        editName = item.llmName ?? item.fileURL.deletingPathExtension().lastPathComponent
        editDescription = item.llmDescription ?? ""
        withAnimation(.easeInOut(duration: 0.15)) {
            editingItemID = item.id
        }
    }

    private func saveEdit(for item: ScreenshotItem) {
        let trimmedName = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let desc = editDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        screenshotManager.updateItemMetadata(
            itemID: item.id,
            newName: trimmedName,
            newDescription: desc.isEmpty ? nil : desc
        )
        editingItemID = nil
    }

    private func copyToClipboard(_ item: ScreenshotItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item.thumbnail])
    }
}

// MARK: - Hero capture button (dark pill with shortcut)

private struct HeroCaptureButton: View {
    let title: String
    let shortcut: String
    let action: () -> Void
    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                Spacer()
                Text(shortcut)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.12))
                    )
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        isHovered
                        ? Color.black.opacity(0.9)
                        : Color.black.opacity(0.85)
                    )
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(title)
    }
}

// MARK: - Mode chip button (Stack / Record)

private struct ModeChipButton: View {
    enum Tone { case neutral, red, blue }

    let icon: String
    let label: String
    let tone: Tone
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(background)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }

    private var foreground: Color {
        switch tone {
        case .neutral: return isHovered ? .primary : .primary.opacity(0.82)
        case .red: return .red
        case .blue: return .blue
        }
    }

    private var background: Color {
        switch tone {
        case .neutral: return Color.primary.opacity(isHovered ? 0.08 : 0.05)
        case .red: return Color.red.opacity(isHovered ? 0.18 : 0.12)
        case .blue: return Color.blue.opacity(isHovered ? 0.18 : 0.12)
        }
    }
}

// MARK: - Named action button (Annotate / Copy)

private struct NamedActionButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.primary.opacity(0.06) : Color.white.opacity(0.85))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - AI chips

private struct AiNamedChip: View {
    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(.green).frame(width: 5, height: 5)
            Text("AI named")
                .font(.system(size: 9.5, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(
            Capsule().fill(Color.primary.opacity(0.05))
        )
    }
}

private struct ProcessingChip: View {
    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(.orange).frame(width: 5, height: 5)
                .modifier(PulseOpacity())
            Text("Naming…")
                .font(.system(size: 9.5, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(
            Capsule().fill(Color.primary.opacity(0.05))
        )
    }
}

// MARK: - Footer pills

private struct FolderChip: View {
    let title: String
    let disabled: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .font(.system(size: 10, weight: .medium))
                Text(title)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(isHovered ? 0.08 : 0.05))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1.0)
        .help("Move to folder")
    }
}

private struct ProviderPill: View {
    let name: String
    let usingClaude: Bool
    let hasKey: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(hasKey ? Color.green : Color.gray.opacity(0.4))
                .frame(width: 5, height: 5)
            Text(name)
                .font(.system(size: 10.5, weight: .medium))
        }
        .foregroundStyle(usingClaude ? .blue : .purple)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color.primary.opacity(0.04))
        )
        .help(hasKey ? "Naming with \(name)" : "\(name) (no API key configured)")
    }
}

// MARK: - Pulse modifier

private struct PulseOpacity: ViewModifier {
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .opacity(on ? 0.35 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

// MARK: - Toolbar Button (macOS-style icon button with hover)

struct ToolbarButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovered ? .primary : .secondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isHovered ? Color.primary.opacity(0.08) : .clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(label)
    }
}

// MARK: - Pill Button (Save / Cancel actions)

struct PillButton: View {
    enum Style { case primary, secondary }

    let title: String
    let icon: String?
    let style: Style
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 11, weight: style == .primary ? .semibold : .regular))
            }
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(backgroundColor)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var foregroundColor: Color {
        switch style {
        case .primary: return .white
        case .secondary: return isHovered ? .primary : .secondary
        }
    }

    private var backgroundColor: Color {
        switch style {
        case .primary: return isHovered ? .accentColor.opacity(0.85) : .accentColor
        case .secondary: return isHovered ? Color.primary.opacity(0.08) : Color.primary.opacity(0.04)
        }
    }
}

// MARK: - LLM Status Badge

struct LLMStatusBadge: View {
    let naming: LLMStatus
    let compare: LLMStatus

    var body: some View {
        HStack(spacing: 4) {
            statusDot(naming, label: "AI")
            if compare != .pending || compare == .processing {
                statusDot(compare, label: "Diff")
            }
        }
    }

    @ViewBuilder
    private func statusDot(_ status: LLMStatus, label: String) -> some View {
        HStack(spacing: 2) {
            Circle()
                .fill(statusColor(status))
                .frame(width: 7, height: 7)
            if status == .processing {
                Text(label)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .help("\(label): \(statusLabel(status))")
    }

    private func statusColor(_ status: LLMStatus) -> Color {
        switch status {
        case .pending: return .gray.opacity(0.35)
        case .processing: return .orange
        case .done: return .green
        case .failed: return .red
        }
    }

    private func statusLabel(_ status: LLMStatus) -> String {
        switch status {
        case .pending: return "Pending"
        case .processing: return "Processing..."
        case .done: return "Done"
        case .failed: return "Failed"
        }
    }
}

// MARK: - Legacy ActionButton (kept for compatibility)

struct ActionButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        ToolbarButton(icon: icon, label: label, action: action)
    }
}
