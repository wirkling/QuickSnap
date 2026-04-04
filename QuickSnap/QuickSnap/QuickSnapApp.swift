import SwiftUI
import SwiftData

@main
struct QuickSnapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("QuickSnap", systemImage: "camera.viewfinder") {
            MenuBarView(folderService: appDelegate.folderService)
                .environmentObject(appDelegate.screenshotManager)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(
                folderService: appDelegate.folderService,
                screenshotManager: appDelegate.screenshotManager
            )
        }
    }
}

struct SettingsView: View {
    @ObservedObject var folderService: FolderService
    @ObservedObject var screenshotManager: ScreenshotManager
    @State private var apiKey: String = ""
    @State private var hasKey: Bool = false
    @State private var showKey: Bool = false
    @State private var selectedTab = 0
    @State private var selectedProvider: AIProvider = .auto
    @State private var boostEnabled: Bool = false

    var body: some View {
        TabView(selection: $selectedTab) {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }
                .tag(0)

            foldersTab
                .tabItem { Label("Folders", systemImage: "folder") }
                .tag(1)

            apiTab
                .tabItem { Label("AI Naming", systemImage: "brain") }
                .tag(2)
        }
        .frame(width: 480, height: 380)
        .onAppear {
            Task {
                hasKey = await screenshotManager.llmNamingService.hasAPIKey()
                if hasKey {
                    apiKey = await screenshotManager.llmNamingService.getAPIKey() ?? ""
                }
                selectedProvider = await screenshotManager.llmNamingService.selectedProvider
                boostEnabled = await screenshotManager.llmNamingService.isBoostEnabled
            }
        }
    }

    private var generalTab: some View {
        Form {
            Section("Hotkey") {
                HStack {
                    Text("Capture Shortcut")
                    Spacer()
                    Text("⌘⇧4")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                Text("To use ⌘⇧4, disable the macOS screenshot shortcut:\nSystem Settings → Keyboard → Keyboard Shortcuts → Screenshots")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Save Location") {
                HStack {
                    Text("Default Folder")
                    Spacer()
                    Text("~/Downloads")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }

    private var foldersTab: some View {
        Form {
            Section("Preset Folders") {
                if folderService.presetFolders.isEmpty {
                    Text("No preset folders configured")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    ForEach(Array(folderService.presetFolders.enumerated()), id: \.offset) { index, url in
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.blue)
                            Text(url.lastPathComponent)
                            Spacer()
                            Text(url.path)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                            Button(action: { folderService.removePresetFolder(at: index) }) {
                                Image(systemName: "minus.circle")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Button("Add Folder...") {
                    folderService.pickAndAddPresetFolder()
                }
            }

            Section("Recent Folders") {
                if folderService.recentFolders.isEmpty {
                    Text("No recent folders yet")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    ForEach(folderService.recentFolders, id: \.self) { url in
                        HStack {
                            Image(systemName: "clock")
                                .foregroundStyle(.secondary)
                            Text(url.lastPathComponent)
                            Spacer()
                            Text(url.path)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding()
    }

    private var apiTab: some View {
        Form {
            Section("AI Provider") {
                Picker("Provider", selection: $selectedProvider) {
                    ForEach(AIProvider.allCases, id: \.self) { provider in
                        Label(provider.displayName, systemImage: provider.icon)
                            .tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: selectedProvider) {
                    Task { await screenshotManager.llmNamingService.setProvider(selectedProvider) }
                }

                switch selectedProvider {
                case .auto:
                    Text(hasKey ? "Using Claude (API key detected)" : "Using Apple Intelligence (no API key)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .claude:
                    if !hasKey {
                        Label("Claude requires an API key — add one below", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                case .appleIntelligence:
                    Text("On-device, private, free. Shorter descriptions than Claude.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if selectedProvider != .appleIntelligence {
                Section("Claude API Key") {
                    HStack {
                        if showKey {
                            TextField("sk-ant-...", text: $apiKey)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("sk-ant-...", text: $apiKey)
                                .textFieldStyle(.roundedBorder)
                        }
                        Button(showKey ? "Hide" : "Show") {
                            showKey.toggle()
                        }
                        .frame(width: 50)
                    }

                    HStack {
                        Button("Save Key") {
                            Task {
                                await screenshotManager.llmNamingService.setAPIKey(apiKey)
                                hasKey = true
                            }
                        }
                        .disabled(apiKey.isEmpty)

                        if hasKey {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Key saved in Keychain")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Boost Mode") {
                    Text("Use the bolt icon next to any screenshot to re-analyze it with Claude Opus for richer, more detailed descriptions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }
}
