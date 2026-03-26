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
        .frame(width: 450, height: 300)
        .onAppear {
            Task {
                hasKey = await screenshotManager.llmNamingService.hasAPIKey()
                if hasKey {
                    apiKey = await screenshotManager.llmNamingService.getAPIKey() ?? ""
                }
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

                Text("Used by Claude Haiku to generate descriptive filenames for your screenshots. Key is stored securely in macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("How It Works") {
                Text("After each screenshot, QuickSnap sends a compressed JPEG to the Claude API. Claude analyzes the content and returns a short descriptive filename like \"xcode-build-error-dialog\" or \"slack-team-chat\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}
