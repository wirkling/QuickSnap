import AppKit
import Foundation

/// Manages preset screenshot destination folders and tracks the last 5 used folders.
@MainActor
final class FolderService: ObservableObject {
    @Published var presetFolders: [URL] = []
    @Published var recentFolders: [URL] = []

    private let presetsKey = "QuickSnap.presetFolders"
    private let recentKey = "QuickSnap.recentFolders"
    private let maxRecent = 5

    init() {
        loadFromDefaults()
    }

    // MARK: - Move File

    func moveScreenshot(at source: URL, to folderURL: URL) throws -> URL {
        let destination = folderURL.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.moveItem(at: source, to: destination)
        trackRecentFolder(folderURL)
        return destination
    }

    // MARK: - Preset Folders

    func addPresetFolder(_ url: URL) {
        guard !presetFolders.contains(url) else { return }
        presetFolders.append(url)
        saveToDefaults()
    }

    func removePresetFolder(at index: Int) {
        guard presetFolders.indices.contains(index) else { return }
        presetFolders.remove(at: index)
        saveToDefaults()
    }

    /// Opens an NSOpenPanel to let the user pick a folder to add as a preset.
    func pickAndAddPresetFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to add as a QuickSnap preset"
        panel.prompt = "Add Folder"

        if panel.runModal() == .OK, let url = panel.url {
            addPresetFolder(url)
        }
    }

    // MARK: - Recent Folders

    func trackRecentFolder(_ url: URL) {
        recentFolders.removeAll { $0 == url }
        recentFolders.insert(url, at: 0)
        if recentFolders.count > maxRecent {
            recentFolders = Array(recentFolders.prefix(maxRecent))
        }
        saveToDefaults()
    }

    /// Combined list: presets first, then recent (excluding duplicates).
    var allFolders: [(url: URL, isPreset: Bool)] {
        var result: [(URL, Bool)] = presetFolders.map { ($0, true) }
        for recent in recentFolders where !presetFolders.contains(recent) {
            result.append((recent, false))
        }
        return result
    }

    // MARK: - Persistence

    private func saveToDefaults() {
        let defaults = UserDefaults.standard
        defaults.set(presetFolders.map(\.path), forKey: presetsKey)
        defaults.set(recentFolders.map(\.path), forKey: recentKey)
    }

    private func loadFromDefaults() {
        let defaults = UserDefaults.standard
        if let paths = defaults.stringArray(forKey: presetsKey) {
            presetFolders = paths.map { URL(fileURLWithPath: $0) }
        }
        if let paths = defaults.stringArray(forKey: recentKey) {
            recentFolders = paths.map { URL(fileURLWithPath: $0) }
        }
    }
}
