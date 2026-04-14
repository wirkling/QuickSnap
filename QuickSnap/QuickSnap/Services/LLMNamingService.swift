import AppKit
import Foundation
import Security

/// AI provider selection — persisted in UserDefaults.
enum AIProvider: String, CaseIterable {
    case auto = "auto"              // Claude if key exists, else Apple Intelligence
    case claude = "claude"          // Force Claude (requires API key)
    case appleIntelligence = "apple" // Force Apple Intelligence (on-device)

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .claude: return "Claude"
        case .appleIntelligence: return "Apple Intelligence"
        }
    }

    var icon: String {
        switch self {
        case .auto: return "sparkles"
        case .claude: return "cloud.fill"
        case .appleIntelligence: return "apple.intelligence"
        }
    }
}

/// Claude model tier for quality control.
enum ClaudeModelTier: String, CaseIterable {
    case haiku = "claude-haiku-4-5"
    case sonnet = "claude-sonnet-4-5"
    case opus = "claude-opus-4-6"

    var displayName: String {
        switch self {
        case .haiku: return "Haiku (fast, cheap)"
        case .sonnet: return "Sonnet (balanced)"
        case .opus: return "Opus (best quality)"
        }
    }

    var maxTokens: Int {
        switch self {
        case .haiku: return 300
        case .sonnet: return 500
        case .opus: return 800
        }
    }
}

/// Routes between Claude API and Apple Intelligence based on provider setting.
actor LLMNamingService {
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let keychainKey = "com.dirkwilfling.QuickSnap.anthropicAPIKey"
    private let providerKey = "com.dirkwilfling.QuickSnap.aiProvider"
    private let boostKey = "com.dirkwilfling.QuickSnap.boostEnabled"

    /// The default Claude model for standard captures.
    private var standardModel: String { "claude-haiku-4-5" }

    /// The boost model for richer analysis.
    private var boostModel: String { "claude-opus-4-6" }

    /// The currently active Claude model (standard or boost).
    var model: String {
        isBoostEnabled ? boostModel : standardModel
    }

    /// Max tokens scales with model tier.
    var maxTokensForDescription: Int {
        isBoostEnabled ? 800 : 300
    }

    // MARK: - Provider Settings

    var selectedProvider: AIProvider {
        get {
            let raw = UserDefaults.standard.string(forKey: providerKey) ?? "auto"
            return AIProvider(rawValue: raw) ?? .auto
        }
    }

    func setProvider(_ provider: AIProvider) {
        UserDefaults.standard.set(provider.rawValue, forKey: providerKey)
    }

    var isBoostEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: boostKey) }
    }

    func setBoost(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: boostKey)
    }

    /// Whether the active configuration will use Claude.
    var isUsingClaude: Bool {
        switch selectedProvider {
        case .claude:
            return hasAPIKey()
        case .appleIntelligence:
            return false
        case .auto:
            return hasAPIKey()
        }
    }

    /// Whether to use Apple Intelligence for the current request.
    private var shouldUseAppleIntelligence: Bool {
        switch selectedProvider {
        case .appleIntelligence:
            return true
        case .claude:
            return false
        case .auto:
            return !hasAPIKey()
        }
    }

    var providerName: String {
        if isUsingClaude {
            return isBoostEnabled ? "Claude Opus (Boost)" : "Claude Haiku"
        }
        return "Apple Intelligence"
    }

    /// Returns the API key if Claude should be used, nil if Apple Intelligence should be used.
    private func claudeAPIKeyIfActive() -> String? {
        guard !shouldUseAppleIntelligence else { return nil }
        guard let key = getAPIKey(), !key.isEmpty else { return nil }
        return key
    }

    /// Check if an error is a network/connectivity issue (triggers Apple Intelligence fallback).
    private func isNetworkError(_ error: Error) -> Bool {
        let nsError = error as NSError
        let networkCodes: Set<Int> = [
            NSURLErrorNotConnectedToInternet,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorTimedOut,
            NSURLErrorSecureConnectionFailed,
            NSURLErrorDataNotAllowed
        ]
        return nsError.domain == NSURLErrorDomain && networkCodes.contains(nsError.code)
    }

    /// Try Apple Intelligence as a fallback when Claude fails due to network.
    private func appleIntelligenceFallback<T>(
        _ operation: @Sendable () async -> T?
    ) async -> T? {
        if #available(macOS 26.0, *) {
            print("[QuickSnap] Claude failed (network) — falling back to Apple Intelligence")
            return await operation()
        }
        return nil
    }

    // MARK: - Public API

    /// Generate a filename for the given image. Returns nil on failure.
    func generateFilename(for image: NSImage) async -> String? {
        guard let apiKey = claudeAPIKeyIfActive() else {
            if #available(macOS 26.0, *), shouldUseAppleIntelligence {
                let result = await AppleIntelligenceService().generateFilenameAndDescription(for: image)
                return result?.filename
            }
            return nil
        }

        guard let base64 = imageToBase64(image) else {
            print("[QuickSnap] Failed to encode image to base64")
            return nil
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 60,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/jpeg",
                                "data": base64
                            ]
                        ],
                        [
                            "type": "text",
                            "text": "Generate a short, filesystem-safe filename (no extension) for this screenshot. ALWAYS use English regardless of the content's language. Use lowercase-kebab-case. Max 6 words. Just output the filename, nothing else."
                        ]
                    ]
                ]
            ]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            return nil
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = jsonData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                print("[QuickSnap] LLM API: no HTTP response")
                return nil
            }
            guard httpResponse.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "no body"
                print("[QuickSnap] LLM API returned \(httpResponse.statusCode): \(body)")
                return nil
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? [[String: Any]],
                  let firstBlock = content.first,
                  let text = firstBlock["text"] as? String else {
                return nil
            }

            let filename = sanitizeFilename(text)
            return filename.isEmpty ? nil : filename
        } catch {
            print("[QuickSnap] LLM API error: \(error.localizedDescription)")
            return nil
        }
    }

    /// Generate a filename and description for an annotated screenshot.
    /// The prompt specifically asks the LLM to pay attention to annotations (arrows, highlights, text, redactions).
    func generateAnnotatedDescription(for image: NSImage) async -> (filename: String, description: String)? {
        guard let apiKey = claudeAPIKeyIfActive() else {
            if #available(macOS 26.0, *) {
                return await AppleIntelligenceService().generateAnnotatedDescription(for: image)
            }
            return nil
        }
        guard let base64 = imageToBase64(image) else { return nil }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 400,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": ["type": "base64", "media_type": "image/jpeg", "data": base64]
                        ],
                        [
                            "type": "text",
                            "text": """
                            This screenshot has been annotated by a user with arrows, rectangles, text labels, or redactions.

                            Analyze BOTH the underlying screenshot content AND the annotations. Pay special attention to:
                            - Where arrows point — describe what they're highlighting
                            - What rectangles are drawn around — describe the enclosed content
                            - Any text annotations — include them in your description
                            - Redacted/blurred areas — note that something was redacted there

                            Respond with EXACTLY two lines:
                            Line 1: A short filesystem-safe filename (no extension), lowercase-kebab-case, max 6 words, ALWAYS in English. Include a hint about the annotation (e.g., "arrow-pointing-to-error-dialog").
                            Line 2: A detailed description covering the screenshot content AND what the annotations highlight. ALWAYS in English. This will be embedded as metadata for AI tools.
                            """
                        ]
                    ]
                ]
            ]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = jsonData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                print("[QuickSnap] LLM annotated API error: \(body)")
                return nil
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? [[String: Any]],
                  let firstBlock = content.first,
                  let text = firstBlock["text"] as? String else { return nil }

            let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard lines.count >= 2 else {
                let filename = sanitizeFilename(text)
                return filename.isEmpty ? nil : (filename: filename, description: "")
            }
            let filename = sanitizeFilename(lines[0])
            let description = lines.dropFirst().joined(separator: " ")
            return filename.isEmpty ? nil : (filename: filename, description: description)
        } catch {
            print("[QuickSnap] LLM annotated API error: \(error.localizedDescription)")
            if isNetworkError(error) {
                return await appleIntelligenceFallback {
                    if #available(macOS 26.0, *) {
                        return await AppleIntelligenceService().generateAnnotatedDescription(for: image)
                    }
                    return nil
                }
            }
            return nil
        }
    }

    /// Generate a filename AND a detailed description for the given image.
    func generateFilenameAndDescription(for image: NSImage) async -> (filename: String, description: String)? {
        guard let apiKey = claudeAPIKeyIfActive() else {
            if #available(macOS 26.0, *) {
                print("[QuickSnap] Using Apple Intelligence (on-device)")
                return await AppleIntelligenceService().generateFilenameAndDescription(for: image)
            }
            return nil
        }

        guard let base64 = imageToBase64(image) else {
            print("[QuickSnap] Failed to encode image to base64")
            return nil
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 300,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/jpeg",
                                "data": base64
                            ]
                        ],
                        [
                            "type": "text",
                            "text": """
                            Analyze this screenshot and respond with EXACTLY two lines:
                            Line 1: A short filesystem-safe filename (no extension), lowercase-kebab-case, max 6 words, ALWAYS in English.
                            Line 2: A detailed description of what's shown (what app, what content, any visible text, UI elements, errors, etc.), ALWAYS in English. This description will be embedded as metadata for AI tools to read.

                            Example:
                            xcode-build-error-missing-module
                            Xcode IDE showing a build failure with error "Missing required module 'SwiftUI'" in the issue navigator. The project is called QuickSnap targeting macOS 14.0. The editor shows AppDelegate.swift with red error highlights on import statements.
                            """
                        ]
                    ]
                ]
            ]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            return nil
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = jsonData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return nil
            }
            guard httpResponse.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "no body"
                print("[QuickSnap] LLM API returned \(httpResponse.statusCode): \(body)")
                return nil
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? [[String: Any]],
                  let firstBlock = content.first,
                  let text = firstBlock["text"] as? String else {
                return nil
            }

            let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard lines.count >= 2 else {
                // Fall back to just the filename
                let filename = sanitizeFilename(text)
                return filename.isEmpty ? nil : (filename: filename, description: "")
            }

            let filename = sanitizeFilename(lines[0])
            let description = lines.dropFirst().joined(separator: " ")
            return filename.isEmpty ? nil : (filename: filename, description: description)
        } catch {
            print("[QuickSnap] LLM API error: \(error.localizedDescription)")
            if isNetworkError(error) {
                return await appleIntelligenceFallback {
                    if #available(macOS 26.0, *) {
                        return await AppleIntelligenceService().generateFilenameAndDescription(for: image)
                    }
                    return nil
                }
            }
            return nil
        }
    }

    /// Generate a folder name and per-frame descriptions for a burst capture.
    /// Sends all frames as small thumbnails so the LLM can narrate the full story.
    /// Returns: filename for the folder, overall description, and per-frame descriptions.
    func generateBurstDescription(frames: [NSImage], count: Int) async -> (filename: String, description: String, frameDescriptions: [String])? {
        guard let apiKey = claudeAPIKeyIfActive() else {
            if #available(macOS 26.0, *) {
                return await AppleIntelligenceService().generateBurstDescription(frames: frames, count: count)
            }
            return nil
        }

        // Encode all frames as tiny thumbnails (128px wide, heavy compression)
        var imageBlocks: [[String: Any]] = []
        for frame in frames {
            guard let base64 = imageToBase64Tiny(frame) else { continue }
            imageBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": base64
                ]
            ])
        }

        guard !imageBlocks.isEmpty else {
            print("[QuickSnap] Failed to encode burst frames")
            return nil
        }

        // Add the text prompt after all images
        var contentBlocks: [[String: Any]] = imageBlocks
        contentBlocks.append([
            "type": "text",
            "text": """
            These are \(imageBlocks.count) frames from a burst capture (taken every 2 seconds). They tell a story of what the user was doing.

            Respond with EXACTLY this format:
            Line 1: A short filesystem-safe folder name, lowercase-kebab-case, max 6 words, ALWAYS in English.
            Line 2: Overall summary of what happened across all frames.
            Line 3 onwards: One description per frame, prefixed with "Frame N:" — describe what's visible AND what changed from the previous frame. Be specific about UI elements, cursor positions, content changes.

            Example:
            puzzle-game-tile-arrangement
            User plays a drag-and-drop puzzle game, moving numbered tiles across a grid over 10 frames.
            Frame 1: Puzzle grid showing tiles 3, 4, 8, 6 in starting positions. Hand cursor hovering over bottom-left area.
            Frame 2: Tile 4 is being dragged upward, highlighted with selection border.
            Frame 3: Tile 4 placed in new position at top-right. Grid layout changed.
            """
        ])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1500,
            "messages": [
                [
                    "role": "user",
                    "content": contentBlocks
                ]
            ]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            return nil
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = jsonData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "no body"
                print("[QuickSnap] LLM API burst error: \(body)")
                return nil
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? [[String: Any]],
                  let firstBlock = content.first,
                  let text = firstBlock["text"] as? String else {
                return nil
            }

            let lines = text.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            guard lines.count >= 2 else {
                let filename = sanitizeFilename(text)
                return filename.isEmpty ? nil : (filename: filename, description: "", frameDescriptions: [])
            }

            let filename = sanitizeFilename(lines[0])
            let description = lines[1]

            // Parse per-frame descriptions (lines starting with "Frame N:")
            var frameDescriptions: [String] = []
            for line in lines.dropFirst(2) {
                // Strip "Frame N: " prefix if present
                if let colonRange = line.range(of: #"^Frame \d+:\s*"#, options: .regularExpression) {
                    frameDescriptions.append(String(line[colonRange.upperBound...]))
                } else {
                    frameDescriptions.append(line)
                }
            }

            return filename.isEmpty ? nil : (filename: filename, description: description, frameDescriptions: frameDescriptions)
        } catch {
            print("[QuickSnap] LLM API burst error: \(error.localizedDescription)")
            if isNetworkError(error) {
                return await appleIntelligenceFallback {
                    if #available(macOS 26.0, *) {
                        return await AppleIntelligenceService().generateBurstDescription(frames: frames, count: count)
                    }
                    return nil
                }
            }
            return nil
        }
    }

    /// Generate a folder name, overall narrative, and per-page descriptions for a stack capture.
    /// The LLM builds a story across all pages, describing the workflow and what each page contributes.
    func generateStackDescription(pages: [NSImage], count: Int) async -> (filename: String, description: String, pageDescriptions: [String])? {
        guard let apiKey = claudeAPIKeyIfActive() else {
            if #available(macOS 26.0, *) {
                return await AppleIntelligenceService().generateStackDescription(pages: pages, count: count)
            }
            return nil
        }

        var imageBlocks: [[String: Any]] = []
        for page in pages {
            guard let base64 = imageToBase64Tiny(page) else { continue }
            imageBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": base64
                ]
            ])
        }

        guard !imageBlocks.isEmpty else {
            print("[QuickSnap] Failed to encode stack pages")
            return nil
        }

        var contentBlocks: [[String: Any]] = imageBlocks
        contentBlocks.append([
            "type": "text",
            "text": """
            These are \(imageBlocks.count) pages from a screenshot stack — the user manually collected these screenshots while navigating across different apps, windows, and screens. Together they tell a story or document a workflow.

            Your job is to analyze ALL pages as a connected narrative. Describe:
            - What the user was doing across these screenshots
            - How each page connects to the next (what changed, what was opened, what was referenced)
            - The overall purpose or goal of this collection

            Respond with EXACTLY this format:
            Line 1: A short filesystem-safe folder name, lowercase-kebab-case, max 6 words, ALWAYS in English.
            Line 2: A comprehensive narrative summary that tells the full story of what's documented across all pages. This should read like a brief report — not just a list of screenshots, but a coherent description of the workflow, process, or investigation shown. ALWAYS in English.
            Line 3 onwards: One description per page, prefixed with "Page N:" — describe what's visible AND how it relates to the overall story. Be specific about apps, content, UI state, and transitions between pages.

            Example:
            debugging-api-timeout-resolution
            Developer investigates and resolves an API timeout issue. Starting from a Sentry error alert showing 504 Gateway Timeout on the /api/users endpoint, they trace the issue through CloudWatch logs revealing a database connection pool exhaustion. They then modify the connection pool configuration in the codebase, deploy the fix, and verify the error rate drops to zero in the monitoring dashboard.
            Page 1: Sentry dashboard showing a spike in 504 errors on the /api/users endpoint. Error count reads 847 in the last hour. The error detail panel shows the stack trace pointing to a database query timeout.
            Page 2: AWS CloudWatch logs filtered to the API service. Log entries show "Connection pool exhausted" warnings repeating every few seconds, with timestamps matching the Sentry error spike.
            Page 3: VS Code editor open to config/database.ts. The developer has changed max_connections from 5 to 20 and added idle_timeout: 30000. A git diff is visible in the sidebar.
            Page 4: Vercel deployment dashboard showing a successful production deployment. The Sentry error graph in a split view shows the error rate dropping to zero after the deploy timestamp.
            """
        ])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2000,
            "messages": [
                [
                    "role": "user",
                    "content": contentBlocks
                ]
            ]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            return nil
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = jsonData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 45

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "no body"
                print("[QuickSnap] LLM API stack error: \(body)")
                return nil
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? [[String: Any]],
                  let firstBlock = content.first,
                  let text = firstBlock["text"] as? String else {
                return nil
            }

            let lines = text.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            guard lines.count >= 2 else {
                let filename = sanitizeFilename(text)
                return filename.isEmpty ? nil : (filename: filename, description: "", pageDescriptions: [])
            }

            let filename = sanitizeFilename(lines[0])
            let description = lines[1]

            var pageDescriptions: [String] = []
            for line in lines.dropFirst(2) {
                if let colonRange = line.range(of: #"^Page \d+:\s*"#, options: .regularExpression) {
                    pageDescriptions.append(String(line[colonRange.upperBound...]))
                } else {
                    pageDescriptions.append(line)
                }
            }

            return filename.isEmpty ? nil : (filename: filename, description: description, pageDescriptions: pageDescriptions)
        } catch {
            print("[QuickSnap] LLM API stack error: \(error.localizedDescription)")
            if isNetworkError(error) {
                return await appleIntelligenceFallback {
                    if #available(macOS 26.0, *) {
                        return await AppleIntelligenceService().generateStackDescription(pages: pages, count: count)
                    }
                    return nil
                }
            }
            return nil
        }
    }

    /// Encode an image as a tiny thumbnail for burst mode (128px wide, heavy compression).
    private func imageToBase64Tiny(_ image: NSImage) -> String? {
        let maxDim: CGFloat = 128
        let originalSize = image.size
        let scale = min(maxDim / originalSize.width, maxDim / originalSize.height, 1.0)
        let newSize = NSSize(width: originalSize.width * scale, height: originalSize.height * scale)

        let resized = NSImage(size: newSize)
        resized.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: originalSize),
                   operation: .copy, fraction: 1.0)
        resized.unlockFocus()

        guard let tiffData = resized.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.3]) else {
            return nil
        }
        return jpegData.base64EncodedString()
    }

    /// Compare two screenshots and describe the differences.
    func generateComparison(before: NSImage, after: NSImage) async -> String? {
        guard let apiKey = claudeAPIKeyIfActive() else {
            if #available(macOS 26.0, *) {
                return await AppleIntelligenceService().generateComparison(before: before, after: after)
            }
            return nil
        }

        guard let base64Before = imageToBase64(before),
              let base64After = imageToBase64(after) else {
            return nil
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 300,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/jpeg",
                                "data": base64Before
                            ]
                        ],
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/jpeg",
                                "data": base64After
                            ]
                        ],
                        [
                            "type": "text",
                            "text": """
                            Compare these two screenshots taken during a UI development workflow.
                            Image 1 (before): [attached]
                            Image 2 (after): [attached]
                            Describe what changed between them. Focus on UI changes, new/removed elements, text changes, layout shifts, error resolution. Be specific and concise. ALWAYS respond in English.
                            """
                        ]
                    ]
                ]
            ]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            return nil
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = jsonData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? [[String: Any]],
                  let firstBlock = content.first,
                  let text = firstBlock["text"] as? String else {
                return nil
            }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            print("[QuickSnap] LLM comparison error: \(error.localizedDescription)")
            if isNetworkError(error) {
                return await appleIntelligenceFallback {
                    if #available(macOS 26.0, *) {
                        return await AppleIntelligenceService().generateComparison(before: before, after: after)
                    }
                    return nil
                }
            }
            return nil
        }
    }

    // MARK: - Boost (Opus re-analysis with existing context)

    /// Re-analyze a screenshot with Claude Opus, using the existing name/description as context.
    /// Always uses Opus regardless of the global provider setting.
    func boostDescription(for image: NSImage, existingName: String?, existingDescription: String?) async -> (filename: String, description: String)? {
        guard let apiKey = getAPIKey(), !apiKey.isEmpty else {
            print("[QuickSnap] Boost requires a Claude API key")
            return nil
        }

        guard let base64 = imageToBase64(image) else { return nil }

        let contextBlock: String
        if let name = existingName, let desc = existingDescription {
            contextBlock = """
            A previous (faster, less capable) AI analysis produced:
            - Filename: \(name)
            - Description: \(desc)

            Use this as a starting point. You may keep the filename if it's accurate, or improve it.
            Your job is to produce a SIGNIFICANTLY more detailed and insightful description.
            """
        } else {
            contextBlock = "No prior analysis available. Analyze from scratch."
        }

        let body: [String: Any] = [
            "model": boostModel,
            "max_tokens": 1000,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/jpeg",
                                "data": base64
                            ]
                        ],
                        [
                            "type": "text",
                            "text": """
                            You are doing a DEEP analysis of this screenshot. \(contextBlock)

                            Respond with EXACTLY two lines:
                            Line 1: A short filesystem-safe filename (no extension), lowercase-kebab-case, max 6 words, ALWAYS in English.
                            Line 2: A comprehensive, highly detailed description. Include:
                            - The exact application, website, or tool shown
                            - All visible text content (menu items, labels, error messages, chat messages, code snippets)
                            - UI state details (which tabs are active, what's selected, scroll position, any notifications)
                            - Context clues about what the user is doing and why
                            - Any data visible (numbers, dates, names, URLs, file paths)
                            ALWAYS in English.
                            """
                        ]
                    ]
                ]
            ]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = jsonData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                print("[QuickSnap] Boost API error: \(body)")
                return nil
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? [[String: Any]],
                  let firstBlock = content.first,
                  let text = firstBlock["text"] as? String else { return nil }

            let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard lines.count >= 2 else {
                let filename = sanitizeFilename(text)
                return filename.isEmpty ? nil : (filename: filename, description: "")
            }
            let filename = sanitizeFilename(lines[0])
            let description = lines.dropFirst().joined(separator: " ")
            return filename.isEmpty ? nil : (filename: filename, description: description)
        } catch {
            print("[QuickSnap] Boost API error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - API Key Management (Keychain)

    func setAPIKey(_ key: String) {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainKey,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    func getAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func hasAPIKey() -> Bool {
        getAPIKey() != nil
    }

    // MARK: - Helpers

    private func imageToBase64(_ image: NSImage) -> String? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.6]) else {
            return nil
        }
        return jpegData.base64EncodedString()
    }

    private func sanitizeFilename(_ raw: String) -> String {
        var name = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")

        // Remove anything that's not alphanumeric or hyphen
        name = name.filter { $0.isLetter || $0.isNumber || $0 == "-" }

        // Collapse multiple hyphens
        while name.contains("--") {
            name = name.replacingOccurrences(of: "--", with: "-")
        }

        // Trim hyphens from edges
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        // Limit length
        if name.count > 60 {
            name = String(name.prefix(60))
        }

        return name
    }
}
