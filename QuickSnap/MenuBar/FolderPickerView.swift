import SwiftUI

struct FolderPickerView: View {
    @EnvironmentObject var screenshotManager: ScreenshotManager
    @ObservedObject var folderService: FolderService
    let screenshotURL: URL?
    let onMoved: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Preset and recent folders
            if folderService.allFolders.isEmpty {
                Text("No folders configured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            } else {
                ForEach(folderService.allFolders, id: \.url) { folder in
                    FolderRow(
                        url: folder.url,
                        isPreset: folder.isPreset,
                        disabled: screenshotURL == nil
                    ) {
                        moveToFolder(folder.url)
                    }
                }
            }

            Divider()

            // Add preset folder
            Button(action: { folderService.pickAndAddPresetFolder() }) {
                Label("Add Preset Folder...", systemImage: "plus.circle")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            // Choose folder ad-hoc
            Button(action: pickFolder) {
                Label("Choose Folder...", systemImage: "folder.badge.questionmark")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .disabled(screenshotURL == nil)
        }
        .padding(.vertical, 4)
    }

    private func moveToFolder(_ folderURL: URL) {
        guard let source = screenshotURL else { return }
        do {
            let newURL = try folderService.moveScreenshot(at: source, to: folderURL)
            onMoved(newURL)
        } catch {
            print("[QuickSnap] Move failed: \(error)")
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Move Here"

        if panel.runModal() == .OK, let url = panel.url {
            moveToFolder(url)
        }
    }
}

struct FolderRow: View {
    let url: URL
    let isPreset: Bool
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isPreset ? "folder.fill" : "clock")
                    .font(.caption)
                    .foregroundStyle(isPreset ? .blue : .secondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 0) {
                    Text(url.lastPathComponent)
                        .font(.caption)
                        .lineLimit(1)
                    Text(shortenedPath(url))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func shortenedPath(_ url: URL) -> String {
        let path = url.path
        if let homeRange = path.range(of: NSHomeDirectory()) {
            return "~" + path[homeRange.upperBound...]
        }
        return path
    }
}
