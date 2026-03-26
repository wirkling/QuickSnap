import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var screenshotManager: ScreenshotManager
    @ObservedObject var folderService: FolderService
    @State private var showFolderPicker = false
    @State private var selectedHistoryItem: ScreenshotItem?
    @State private var hasAPIKey = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("QuickSnap")
                    .font(.headline)
                Spacer()
                Button(action: { screenshotManager.startCapture() }) {
                    Image(systemName: "camera")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .help("Take Screenshot (⌘⇧4)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            // Last screenshot
            if let last = screenshotManager.lastScreenshot {
                lastCaptureView(last)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "camera.viewfinder")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No screenshots yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Press ⌘⇧4 to capture")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            }

            Divider()
                .padding(.top, 6)

            // History
            HistoryGridView(selectedItem: $selectedHistoryItem)

            if let selected = selectedHistoryItem {
                selectedItemBar(selected)
            }

            Divider()
                .padding(.top, 6)

            // Move to folder
            if showFolderPicker {
                let activeURL = selectedHistoryItem?.fileURL ?? screenshotManager.lastScreenshot?.fileURL
                FolderPickerView(
                    folderService: folderService,
                    screenshotURL: activeURL,
                    onMoved: { newURL in
                        if var selected = selectedHistoryItem,
                           let idx = screenshotManager.history.firstIndex(where: { $0.id == selected.id }) {
                            selected.fileURL = newURL
                            screenshotManager.history[idx] = selected
                        }
                        screenshotManager.lastScreenshot?.fileURL = newURL
                        showFolderPicker = false
                    }
                )
            } else {
                Button(action: { showFolderPicker = true }) {
                    Label("Move to Folder...", systemImage: "folder")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .disabled(screenshotManager.lastScreenshot == nil && selectedHistoryItem == nil)
            }

            Divider()

            // API key hint
            if !hasAPIKey {
                HStack(spacing: 4) {
                    Image(systemName: "brain")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Add API key in Settings for smart filenames")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                Divider()
            }

            // Footer
            HStack {
                Button("Settings...") {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.plain)
                .font(.caption)

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 400)
        .onAppear {
            Task {
                hasAPIKey = await screenshotManager.llmNamingService.hasAPIKey()
            }
        }
    }

    // MARK: - Last Capture

    @ViewBuilder
    private func lastCaptureView(_ item: ScreenshotItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Last Capture")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                LLMStatusBadge(naming: item.llmNamingStatus, compare: item.llmCompareStatus)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            HStack(alignment: .top, spacing: 12) {
                DraggableThumbnailView(
                    image: item.thumbnail,
                    fileURL: item.fileURL,
                    size: CGSize(width: 120, height: 90),
                    burstImageURLs: item.burstImageURLs
                )

                VStack(alignment: .leading, spacing: 6) {
                    // Title — full, wrapping
                    Text(item.displayName)
                        .font(.callout.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)

                    Text(item.createdAt, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    // Actions
                    HStack(spacing: 10) {
                        ActionButton(icon: "pencil.tip", label: "Annotate") {
                            screenshotManager.annotate(item)
                        }
                        ActionButton(icon: "pin", label: "Pin") {
                            screenshotManager.pin(item)
                        }
                        ActionButton(icon: "doc.on.clipboard", label: "Copy") {
                            copyToClipboard(item)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)

            // Metadata section
            if item.llmDescription != nil || item.comparisonDescription != nil {
                VStack(alignment: .leading, spacing: 4) {
                    if let desc = item.llmDescription {
                        Text(desc)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let comparison = item.comparisonDescription {
                        HStack(alignment: .top, spacing: 4) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                            Text(comparison)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 2)
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: - Selected Item Bar

    @ViewBuilder
    private func selectedItemBar(_ item: ScreenshotItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(item.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                LLMStatusBadge(naming: item.llmNamingStatus, compare: item.llmCompareStatus)
                ActionButton(icon: "pencil.tip", label: "Annotate") {
                    screenshotManager.annotate(item)
                }
                ActionButton(icon: "pin", label: "Pin") {
                    screenshotManager.pin(item)
                }
                ActionButton(icon: "doc.on.clipboard", label: "Copy") {
                    copyToClipboard(item)
                }
            }
            if let desc = item.llmDescription {
                Text(desc)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func copyToClipboard(_ item: ScreenshotItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item.thumbnail])
    }
}

// MARK: - LLM Status Badge

struct LLMStatusBadge: View {
    let naming: LLMStatus
    let compare: LLMStatus

    var body: some View {
        HStack(spacing: 3) {
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
                .frame(width: 6, height: 6)
            if status == .processing {
                Text(label)
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .help("\(label): \(statusLabel(status))")
    }

    private func statusColor(_ status: LLMStatus) -> Color {
        switch status {
        case .pending: return .gray.opacity(0.4)
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

struct ActionButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption)
        }
        .buttonStyle(.plain)
        .help(label)
    }
}
