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
        selectedHistoryItem != nil ? "Selected" : "Last Capture"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("QuickSnap")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if screenshotManager.isStackMode {
                    HStack(spacing: 4) {
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.blue)
                        Text("Stacking \(screenshotManager.stackCount)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.blue)
                    }
                } else {
                    ToolbarButton(icon: "square.stack.3d.up", label: "Start Stack") {
                        screenshotManager.startStackMode()
                    }
                }
                ToolbarButton(icon: "camera", label: "Take Screenshot (⌘⇧4)") {
                    screenshotManager.startCapture()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Detail view — selected recent item OR last capture
            if let item = detailItem {
                detailView(item, label: detailLabel)
            } else {
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
                .padding(.vertical, 32)
            }

            Divider()

            // History
            HistoryGridView(selectedItemID: $selectedHistoryItemID)
                .padding(.bottom, 6)

            Divider()

            // Move to folder
            if showFolderPicker {
                let activeURL = selectedHistoryItem?.fileURL ?? screenshotManager.lastScreenshot?.fileURL
                FolderPickerView(
                    folderService: folderService,
                    screenshotURL: activeURL,
                    onMoved: { newURL in
                        if let id = selectedHistoryItemID,
                           let idx = screenshotManager.history.firstIndex(where: { $0.id == id }) {
                            screenshotManager.history[idx].fileURL = newURL
                        }
                        screenshotManager.lastScreenshot?.fileURL = newURL
                        showFolderPicker = false
                    }
                )
            } else {
                Button(action: { showFolderPicker = true }) {
                    Label("Move to Folder...", systemImage: "folder")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .disabled(screenshotManager.lastScreenshot == nil && selectedHistoryItem == nil)
            }

            Divider()

            // AI provider hint
            if true {
                HStack(spacing: 5) {
                    Image(systemName: isUsingClaude ? "cloud.fill" : "apple.intelligence")
                        .font(.system(size: 10))
                        .foregroundStyle(isUsingClaude ? .blue : .purple)
                    Text(providerName.isEmpty ? "AI" : providerName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isUsingClaude ? .blue : .purple)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                Divider()
            }

            // Footer
            HStack {
                Button("Settings...") {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
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

    // MARK: - Detail View (shared for last capture and selected recent item)

    @ViewBuilder
    private func detailView(_ item: ScreenshotItem, label: String) -> some View {
        let isEditing = editingItemID == item.id

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                LLMStatusBadge(naming: item.llmNamingStatus, compare: item.llmCompareStatus)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            HStack(alignment: .top, spacing: 14) {
                DraggableThumbnailView(
                    image: item.thumbnail,
                    fileURL: item.fileURL,
                    size: CGSize(width: 140, height: 105),
                    burstImageURLs: item.burstImageURLs,
                    isStack: item.isStack,
                    stackPageCount: item.stackPageURLs?.count ?? 0,
                    pdfURL: item.pdfURL
                )

                VStack(alignment: .leading, spacing: 8) {
                    if isEditing {
                        TextField("Name", text: $editName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))
                            .onSubmit { saveEdit(for: item) }
                    } else {
                        Text(item.displayName)
                            .font(.system(size: 13, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text(item.createdAt, style: .time)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)

                    // Actions
                    if isEditing {
                        HStack(spacing: 6) {
                            PillButton(title: "Save", icon: "checkmark", style: .primary) {
                                saveEdit(for: item)
                            }
                            PillButton(title: "Cancel", icon: nil, style: .secondary) {
                                editingItemID = nil
                            }
                        }
                    } else {
                        HStack(spacing: 4) {
                            if item.llmName != nil {
                                ToolbarButton(icon: "pencil", label: "Edit") {
                                    startEditing(item)
                                }
                            }
                            if item.llmNamingStatus == .done {
                                ToolbarButton(icon: "bolt.fill", label: "Boost — re-analyze with Claude Opus") {
                                    screenshotManager.boostItem(itemID: item.id)
                                }
                            }
                            ToolbarButton(icon: "pencil.tip", label: "Annotate") {
                                screenshotManager.annotate(item)
                            }
                            ToolbarButton(icon: "pin", label: "Pin") {
                                screenshotManager.pin(item)
                            }
                            ToolbarButton(icon: "doc.on.clipboard", label: "Copy") {
                                copyToClipboard(item)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)

            // Metadata section
            if isEditing {
                TextField("Description", text: $editDescription, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .lineLimit(10...15)
                    .padding(.horizontal, 16)
            } else if item.llmDescription != nil || item.comparisonDescription != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if let desc = item.llmDescription {
                        Text(desc)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let comparison = item.comparisonDescription {
                        HStack(alignment: .top, spacing: 5) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                            Text(comparison)
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 2)
            }
        }
        .padding(.bottom, 10)
    }

    // MARK: - Helpers

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
