import SwiftUI

private let onboardingShownKey = "QuickSnap.onboardingShown"

// MARK: - Consistent color palette used across the app
// Capture: .blue    StackSnap: .indigo    BurstSnap: .teal
// RecordSnap: .red  AI: .purple           Claude Code: .orange

enum OnboardingPage: Int, CaseIterable {
    case welcome, permissions, capture, stack, burst, record, ai, claudeCode
}

struct OnboardingView: View {
    @State private var page: OnboardingPage = .welcome
    let onFinish: () -> Void

    private var isLast: Bool { page == OnboardingPage.allCases.last }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch page {
                case .welcome:     welcomePage.transition(.push(from: .trailing))
                case .permissions: permissionsPage.transition(.push(from: .trailing))
                case .capture:     capturePage.transition(.push(from: .trailing))
                case .stack:       stackPage.transition(.push(from: .trailing))
                case .burst:       burstPage.transition(.push(from: .trailing))
                case .record:      recordPage.transition(.push(from: .trailing))
                case .ai:          aiPage.transition(.push(from: .trailing))
                case .claudeCode:  claudeCodePage.transition(.push(from: .trailing))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            // Bottom bar
            VStack(spacing: 0) {
                Divider()
                HStack {
                    HStack(spacing: 8) {
                        ForEach(OnboardingPage.allCases, id: \.rawValue) { p in
                            Circle()
                                .fill(p == page ? Color.accentColor : Color.primary.opacity(0.15))
                                .frame(width: 8, height: 8)
                                .scaleEffect(p == page ? 1.0 : 0.85)
                                .animation(.spring(response: 0.3), value: page)
                        }
                    }

                    Spacer()

                    HStack(spacing: 12) {
                        if page != .welcome {
                            Button("Back") {
                                withAnimation(.easeInOut(duration: 0.35)) {
                                    page = OnboardingPage(rawValue: page.rawValue - 1) ?? .welcome
                                }
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }

                        Button(isLast ? "Get Started" : "Continue") {
                            if isLast {
                                UserDefaults.standard.set(true, forKey: onboardingShownKey)
                                onFinish()
                            } else {
                                withAnimation(.easeInOut(duration: 0.35)) {
                                    page = OnboardingPage(rawValue: page.rawValue + 1) ?? page
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
            }
        }
        .frame(width: 600, height: 520)
        .background(.background)
    }

    // MARK: - Hero Icon

    private func heroIcon(_ symbol: String, gradient: [Color], size: CGFloat = 44) -> some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 88, height: 88)
                .shadow(color: gradient.first?.opacity(0.25) ?? .clear, radius: 12, y: 6)

            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.white)
        }
        .padding(.bottom, 4)
    }

    // MARK: - 1. Welcome

    private var welcomePage: some View {
        VStack(spacing: 16) {
            Spacer()

            heroIcon("camera.viewfinder", gradient: [.blue, .cyan])

            Text("Welcome to QuickSnap")
                .font(.system(size: 28, weight: .bold, design: .rounded))

            Text("A power-user screenshot tool\nthat lives in your menu bar.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer().frame(height: 8)

            VStack(spacing: 6) {
                shortcutPill(keys: ["\u{2318}", "\u{21E7}", "4"], label: "Capture")
                shortcutPill(keys: ["\u{2318}", "\u{21E7}", "R"], label: "Record Process")
            }

            Spacer()
        }
        .padding(.horizontal, 40)
    }

    // MARK: - 2. Permissions

    private var permissionsPage: some View {
        VStack(spacing: 16) {
            Spacer()

            heroIcon("lock.shield.fill", gradient: [.green, .mint])

            Text("Permissions")
                .font(.system(size: 26, weight: .bold, design: .rounded))

            Text("QuickSnap needs a couple of macOS permissions to work.\nYour data never leaves your machine unless you enable the Claude API.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            Spacer().frame(height: 4)

            VStack(spacing: 12) {
                permissionRow(
                    icon: "rectangle.dashed.and.arrow.up",
                    title: "Screen Recording",
                    detail: "Required to capture screenshots and record workflows. macOS will prompt you on first capture.",
                    color: .blue,
                    required: true
                )

                permissionRow(
                    icon: "keyboard",
                    title: "Global Shortcuts",
                    detail: "Works automatically \u{2014} no extra permission needed. Uses the same system as Spotlight.",
                    color: .green,
                    required: false
                )

                permissionRow(
                    icon: "folder",
                    title: "File Access",
                    detail: "Saves screenshots to your chosen folder. You pick the location in Settings.",
                    color: .orange,
                    required: false
                )
            }
            .frame(maxWidth: 440)

            Spacer()
        }
        .padding(.horizontal, 40)
    }

    private func permissionRow(icon: String, title: String, detail: String, color: Color, required: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 8)
                .fill(color.gradient.opacity(0.12))
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(color)
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    if required {
                        Text("Required")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(color))
                    }
                }
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 3. Capture

    private var capturePage: some View {
        VStack(spacing: 16) {
            Spacer()

            heroIcon("viewfinder", gradient: [.blue, .indigo])

            Text("Capture")
                .font(.system(size: 26, weight: .bold, design: .rounded))

            Text("Click a window or drag a region to capture.")
                .font(.body)
                .foregroundStyle(.secondary)

            Spacer().frame(height: 4)

            featureGrid([
                ("rectangle.dashed", "Region Select", "Drag any area", Color.blue),
                ("macwindow", "Window Snap", "Click to capture", Color.blue),
                ("pencil.tip.crop.circle", "Annotate", "Markup before sharing", Color.blue),
                ("doc.on.clipboard.fill", "Auto-Copy", "Clipboard ready instantly", Color.blue),
            ])

            Spacer().frame(height: 6)

            // Action panel mock
            actionPanelMock

            Spacer()
        }
        .padding(.horizontal, 40)
    }

    /// Stylized representation of the post-capture action panel.
    private var actionPanelMock: some View {
        HStack(spacing: 10) {
            // Thumbnail placeholder
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.green.opacity(0.15))
                .frame(width: 48, height: 34)
                .overlay(
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 14))
                        .foregroundStyle(.green.opacity(0.5))
                )

            // Text area
            VStack(alignment: .leading, spacing: 2) {
                Text("email-client-invoice-thread")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("The main email displayed is from Dirk...")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                Text("~/QuickSnaps")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.3))
            }

            Spacer(minLength: 0)

            // Action buttons mock
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    mockActionIcon("pencil.tip")
                    mockActionIcon("pin")
                }
                HStack(spacing: 2) {
                    mockActionIcon("doc.on.clipboard")
                    mockActionIcon("folder")
                }
            }

            // Close
            mockActionIcon("minus")
            mockActionIcon("xmark")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.85))
        )
        .frame(maxWidth: 420)
    }

    private func mockActionIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
            .frame(width: 20, height: 20)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - 4. StackSnap

    private var stackPage: some View {
        VStack(spacing: 16) {
            Spacer()

            heroIcon("square.stack.3d.up.fill", gradient: [.indigo, .purple])

            Text("StackSnap")
                .font(.system(size: 26, weight: .bold, design: .rounded))

            Text("Capture multiple regions into a single PDF.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer().frame(height: 4)

            featureGrid([
                ("square.stack.3d.up", "Stack Mode", "Select in the action panel", Color.indigo),
                ("camera.viewfinder", "Snap Pages", "Add each page with Snap", Color.indigo),
                ("checkmark.circle", "Finish", "Merge into a single PDF", Color.indigo),
            ])

            Text("Perfect for multi-step forms, long pages, or documentation.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)

            Spacer()
        }
        .padding(.horizontal, 40)
    }

    // MARK: - 5. BurstSnap

    private var burstPage: some View {
        VStack(spacing: 16) {
            Spacer()

            heroIcon("square.stack", gradient: [.teal, .mint])

            Text("BurstSnap")
                .font(.system(size: 26, weight: .bold, design: .rounded))

            Text("Select a region once \u{2014} QuickSnap captures it\nevery 2 seconds, hands-free.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer().frame(height: 4)

            featureGrid([
                ("timer", "Timed", "Auto-captures until you stop", Color.teal),
                ("rectangle.on.rectangle", "Same Region", "Pixel-perfect consistency", Color.teal),
                ("chart.line.uptrend.xyaxis", "Monitor", "Track dashboards & progress", Color.teal),
            ])

            Spacer()
        }
        .padding(.horizontal, 40)
    }

    // MARK: - 6. RecordSnap

    private var recordPage: some View {
        VStack(spacing: 16) {
            Spacer()

            heroIcon("record.circle.fill", gradient: [.red, .orange])

            Text("RecordSnap")
                .font(.system(size: 26, weight: .bold, design: .rounded))

            Text("Record a workflow and AI writes\na step-by-step runbook for you.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer().frame(height: 4)

            featureGrid([
                ("camera.fill", "Smart Captures", "On clicks & app switches", Color.red),
                ("keyboard.fill", "Input Logging", "Shortcuts & clipboard", Color.red),
                ("doc.text.fill", "AI Runbook", "Markdown process doc", Color.red),
            ])

            Spacer().frame(height: 4)

            shortcutPill(keys: ["\u{2318}", "\u{21E7}", "R"], label: "Start / Stop")

            Spacer()
        }
        .padding(.horizontal, 40)
    }

    // MARK: - 7. AI Naming

    private var aiPage: some View {
        VStack(spacing: 16) {
            Spacer()

            heroIcon("brain.fill", gradient: [.purple, .pink])

            Text("AI-Powered Naming")
                .font(.system(size: 26, weight: .bold, design: .rounded))

            Text("Every screenshot is analyzed for context \u{2014} generating descriptive filenames and rich metadata that tools like Claude Code can use.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            Spacer().frame(height: 4)

            HStack(spacing: 20) {
                providerCard(
                    icon: "apple.logo",
                    title: "Apple Intelligence",
                    perks: ["On-device & private", "Free, no setup", "Concise names"],
                    color: .primary
                )

                providerCard(
                    icon: "cloud.fill",
                    title: "Claude API",
                    perks: ["Deep context analysis", "Detailed descriptions", "Requires API key"],
                    color: .purple
                )
            }
            .frame(maxWidth: 440)

            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.purple)
                Text("Use **Boost** to re-analyze any screenshot with Claude Opus for the richest detail \u{2014} on demand, so you save tokens on the rest.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 440)

            Spacer()
        }
        .padding(.horizontal, 40)
    }

    // MARK: - 8. Claude Code

    private var claudeCodePage: some View {
        VStack(spacing: 16) {
            Spacer()

            heroIcon("sparkles", gradient: [.orange, .yellow])

            Text("One More Thing\u{2026}")
                .font(.system(size: 26, weight: .bold, design: .rounded))

            Text("Every screenshot carries rich metadata \u{2014} app name, window title, coordinates, and AI-generated context.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            Spacer().frame(height: 4)

            VStack(alignment: .leading, spacing: 14) {
                claudeFeatureRow(
                    icon: "terminal.fill",
                    gradient: [.orange, .yellow],
                    title: "Claude Code Integration",
                    detail: "Paste a screenshot into Claude Code \u{2014} the embedded metadata gives Claude full context about what you\u{2019}re looking at."
                )

                claudeFeatureRow(
                    icon: "bolt.fill",
                    gradient: [.orange, .red],
                    title: "Supercharged Debugging",
                    detail: "\u{201C}Fix the bug in this screenshot\u{201D} just works \u{2014} Claude knows the app, window, and exact region."
                )

                claudeFeatureRow(
                    icon: "puzzlepiece.extension.fill",
                    gradient: [.orange, .pink],
                    title: "Install the Skill",
                    detail: "Search for QuickSnap in the Claude Code skill/plugin marketplace to unlock full integration."
                )
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14).fill(.primary.opacity(0.04)))
            .frame(maxWidth: 440)

            Spacer()
        }
        .padding(.horizontal, 40)
    }

    private func claudeFeatureRow(icon: String, gradient: [Color], title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(colors: gradient, startPoint: .top, endPoint: .bottom))
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Shared Components

    private func featureGrid(_ items: [(icon: String, title: String, detail: String, color: Color)]) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 16), count: min(items.count, 4))
        return LazyVGrid(columns: columns, spacing: 14) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(item.color.gradient.opacity(0.12))
                        .frame(width: 44, height: 44)
                        .overlay(
                            Image(systemName: item.icon)
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(item.color)
                        )

                    Text(item.title)
                        .font(.system(size: 12, weight: .semibold))

                    Text(item.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: 440)
    }

    private func shortcutPill(keys: [String], label: String) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    Text(key)
                        .font(.system(size: 13, weight: .medium))
                        .frame(minWidth: 22, minHeight: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(.primary.opacity(0.08))
                        )
                }
            }
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private func providerCard(icon: String, title: String, perks: [String], color: Color) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(color)
                .frame(height: 32)

            Text(title)
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 4) {
                ForEach(perks, id: \.self) { perk in
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.green)
                        Text(perk)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.primary.opacity(0.04)))
    }
}

// MARK: - Window Controller

@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?

    static var shouldShow: Bool {
        !UserDefaults.standard.bool(forKey: onboardingShownKey)
    }

    func show() {
        guard window == nil else {
            window?.makeKeyAndOrderFront(nil)
            return
        }

        let view = OnboardingView { [weak self] in
            self?.window?.close()
            self?.window = nil
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 520),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.center()
        w.contentView = NSHostingView(rootView: view)
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)

        self.window = w
    }
}
