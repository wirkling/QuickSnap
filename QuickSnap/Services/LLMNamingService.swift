import AppKit
import Foundation
import Security

/// Calls the Claude API (vision) to generate a descriptive filename for a screenshot.
actor LLMNamingService {
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let model = "claude-haiku-4-5"
    private let keychainKey = "com.dirkwilfling.QuickSnap.anthropicAPIKey"

    // MARK: - Public API

    /// Generate a filename for the given image. Returns nil on failure.
    func generateFilename(for image: NSImage) async -> String? {
        guard let apiKey = getAPIKey(), !apiKey.isEmpty else {
            print("[QuickSnap] No API key configured for LLM naming")
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
        guard let apiKey = getAPIKey(), !apiKey.isEmpty else { return nil }
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
            return nil
        }
    }

    /// Generate a filename AND a detailed description for the given image.
    func generateFilenameAndDescription(for image: NSImage) async -> (filename: String, description: String)? {
        guard let apiKey = getAPIKey(), !apiKey.isEmpty else {
            print("[QuickSnap] No API key configured for LLM naming")
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
            return nil
        }
    }

    /// Generate a folder name and per-frame descriptions for a burst capture.
    /// Sends all frames as small thumbnails so the LLM can narrate the full story.
    /// Returns: filename for the folder, overall description, and per-frame descriptions.
    func generateBurstDescription(frames: [NSImage], count: Int) async -> (filename: String, description: String, frameDescriptions: [String])? {
        guard let apiKey = getAPIKey(), !apiKey.isEmpty else {
            print("[QuickSnap] No API key configured for LLM naming")
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
        guard let apiKey = getAPIKey(), !apiKey.isEmpty else {
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
