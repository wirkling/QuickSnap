import AppKit
import Foundation

/// Output template for process recordings.
enum RecordingTemplate: String, CaseIterable, Identifiable {
    case runbook = "Runbook"
    case uxWalkthrough = "UX Walkthrough"
    case bugReport = "Bug Report"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .runbook:       return "list.clipboard"
        case .uxWalkthrough: return "hand.tap"
        case .bugReport:     return "ladybug"
        }
    }

    var shortDescription: String {
        switch self {
        case .runbook:       return "Step-by-step process documentation"
        case .uxWalkthrough: return "User experience narrative"
        case .bugReport:     return "Steps to reproduce a bug"
        }
    }
}

/// Multi-stage LLM pipeline that processes a recording session into a markdown document.
actor ProcessPipelineService {
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let llmNamingService: LLMNamingService
    private let template: RecordingTemplate

    enum Stage: String, CaseIterable {
        case aligning = "Aligning timeline"
        case chunkSummarizing = "Summarizing screenshots"
        case extractingGoldenPath = "Extracting workflow"
        case generatingRunbook = "Generating document"
    }

    struct PipelineResult {
        let markdownRunbook: String
        let title: String
        let totalInputTokens: Int
        let totalOutputTokens: Int
    }

    nonisolated let onStageUpdate: (@Sendable (Stage, String) -> Void)?
    nonisolated let onCostRecord: (@Sendable (String, Int, Int, String) -> Void)?

    /// File-based log for debugging when Xcode console isn't connected.
    nonisolated let logFileURL: URL

    init(llmNamingService: LLMNamingService,
         template: RecordingTemplate = .runbook,
         sessionFolder: URL? = nil,
         onStageUpdate: (@Sendable (Stage, String) -> Void)? = nil,
         onCostRecord: (@Sendable (String, Int, Int, String) -> Void)? = nil) {
        self.llmNamingService = llmNamingService
        self.template = template
        self.onStageUpdate = onStageUpdate
        self.onCostRecord = onCostRecord
        self.logFileURL = (sessionFolder ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("pipeline-log.txt")
    }

    private func log(_ message: String) {
        let timestamped = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        // Write to system log
        NSLog("%@", "[QuickSnap] \(message)")
        // Also append to file for when Xcode console isn't connected
        if let data = timestamped.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                if let handle = try? FileHandle(forWritingTo: logFileURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logFileURL)
            }
        }
    }

    /// Process a completed recording session into a markdown runbook.
    func processRecording(_ session: ProcessRecordingSession) async -> PipelineResult? {
        // Stage 1: Build timeline
        onStageUpdate?(.aligning, "Building timeline from events...")
        let timeline = await buildTimeline(session)
        let screenshots = await MainActor.run { session.screenshots }
        log("Pipeline: \(screenshots.count) screenshots, \(timeline.components(separatedBy: "\n").count) timeline events")

        guard !screenshots.isEmpty else {
            log("Pipeline failed: no screenshots captured during recording")
            return nil
        }

        // Stage 2: Chunk summarize screenshots
        // Use pre-computed summaries from background processing during recording
        let precomputed = await MainActor.run { session.precomputedSummaries }
        let summarizedCount = await MainActor.run { session.summarizedFrameCount }
        var summaries = precomputed
        log("Pipeline: \(precomputed.count) pre-computed summaries covering \(summarizedCount) frames")

        // Process any remaining unsummarized frames
        let remaining = Array(screenshots.dropFirst(summarizedCount))
        if !remaining.isEmpty {
            let remainingChunks = chunkScreenshots(remaining, batchSize: 5)
            let totalChunks = precomputed.count + remainingChunks.count
            log("Pipeline: processing \(remainingChunks.count) remaining chunk(s)")

            for (i, chunk) in remainingChunks.enumerated() {
                let chunkIndex = precomputed.count + i + 1
                onStageUpdate?(.chunkSummarizing, "Batch \(chunkIndex) of \(totalChunks) (\(chunk.count) frames)")
                if let summary = await summarizeChunk(chunk, timeline: timeline) {
                    summaries.append(summary)
                    log("Pipeline: chunk \(chunkIndex) summarized (\(summary.count) chars)")
                } else {
                    log("Pipeline: chunk \(chunkIndex) FAILED")
                }
            }
        } else {
            log("Pipeline: all chunks were pre-computed, skipping Stage 2")
        }

        guard !summaries.isEmpty else {
            log("Pipeline failed: no chunk summaries produced — check API key and network")
            return nil
        }

        // Stage 3: Extract golden path
        onStageUpdate?(.extractingGoldenPath, "Analyzing workflow pattern...")
        guard let goldenPath = await extractGoldenPath(summaries: summaries, timeline: timeline) else {
            log("Pipeline failed: golden path extraction failed")
            return nil
        }

        // Stage 4: Generate document
        onStageUpdate?(.generatingRunbook, "Writing \(template.rawValue.lowercased())...")
        guard let document = await generateDocument(goldenPath: goldenPath, timeline: timeline) else {
            log("Pipeline failed: document generation failed")
            return nil
        }

        return document
    }

    // MARK: - Stage 1: Timeline

    private func buildTimeline(_ session: ProcessRecordingSession) async -> String {
        let events = await MainActor.run { session.events }
        var lines: [String] = []
        for event in events {
            let ts = formatTimestamp(event.timestamp)
            switch event {
            case .screenshot(_, _, let trigger, let app, let window):
                lines.append("\(ts) [SCREENSHOT:\(trigger.rawValue)] \(app ?? "?") — \(window ?? "")")
            case .inputEvent(_, let kind):
                switch kind {
                case .mouseClick(let pos, let label, let app):
                    lines.append("\(ts) [CLICK] \(app ?? "?") at (\(Int(pos.x)),\(Int(pos.y))) \(label ?? "")")
                case .keyboardShortcut(let keys):
                    lines.append("\(ts) [KEY] \(keys)")
                case .clipboardChange(let preview):
                    let short = String(preview.prefix(80))
                    lines.append("\(ts) [CLIPBOARD] \(short)")
                }
            case .userNote(_, let text):
                lines.append("\(ts) [NOTE] \(text)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Stage 2: Chunk Summarization

    /// Summarize a batch of screenshots with a partial timeline. Called during recording
    /// for background processing, and again at the end for any remaining frames.
    func summarizeChunkPublic(_ chunk: [RecordingScreenshot], events: [RecordingEvent]) async -> String? {
        let timeline = buildTimelineFromEvents(events)
        return await summarizeChunk(chunk, timeline: timeline)
    }

    private func buildTimelineFromEvents(_ events: [RecordingEvent]) -> String {
        var lines: [String] = []
        for event in events {
            let ts = formatTimestamp(event.timestamp)
            switch event {
            case .screenshot(_, _, let trigger, let app, let window):
                lines.append("\(ts) [SCREENSHOT:\(trigger.rawValue)] \(app ?? "?") — \(window ?? "")")
            case .inputEvent(_, let kind):
                switch kind {
                case .mouseClick(let pos, let label, let app):
                    lines.append("\(ts) [CLICK] \(app ?? "?") at (\(Int(pos.x)),\(Int(pos.y))) \(label ?? "")")
                case .keyboardShortcut(let keys):
                    lines.append("\(ts) [KEY] \(keys)")
                case .clipboardChange(let preview):
                    lines.append("\(ts) [CLIPBOARD] \(String(preview.prefix(80)))")
                }
            case .userNote(_, let text):
                lines.append("\(ts) [NOTE] \(text)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func chunkScreenshots(_ screenshots: [RecordingScreenshot], batchSize: Int) -> [[RecordingScreenshot]] {
        stride(from: 0, to: screenshots.count, by: batchSize).map {
            Array(screenshots[$0..<min($0 + batchSize, screenshots.count)])
        }
    }

    private func summarizeChunk(_ chunk: [RecordingScreenshot], timeline: String) async -> String? {
        // Build image content for the API call
        var contentParts: [[String: Any]] = []
        for frame in chunk {
            guard let base64 = imageToBase64(frame.apiImage) else { continue }
            contentParts.append([
                "type": "image",
                "source": ["type": "base64", "media_type": "image/jpeg", "data": base64]
            ])
            contentParts.append([
                "type": "text",
                "text": "Frame [\(frame.trigger.rawValue)] at \(formatTimestamp(frame.timestamp)) — \(frame.appName ?? "unknown") \(frame.windowTitle ?? "")"
            ])
        }

        // Add the timeline excerpt for this chunk's time range
        let startTime = chunk.first?.timestamp ?? 0
        let endTime = chunk.last?.timestamp ?? 0
        contentParts.append([
            "type": "text",
            "text": """
            Event log for this time period (\(formatTimestamp(startTime)) – \(formatTimestamp(endTime))):
            \(extractTimelineRange(timeline, from: startTime, to: endTime))

            Describe what the user is doing in each screenshot. Note what application they're using, what actions they're taking, and what changed between screenshots. Provide a batch summary at the end.
            """
        ])

        let model = "claude-sonnet-4-5"
        return await sendLLMRequest(
            model: model,
            maxTokens: 2000,
            messages: [["role": "user", "content": contentParts]],
            stage: "chunk_summarize"
        )
    }

    // MARK: - Stage 3: Golden Path Extraction

    private func extractGoldenPath(summaries: [String], timeline: String) async -> String? {
        let combined = summaries.enumerated()
            .map { "--- Batch \($0.offset + 1) ---\n\($0.element)" }
            .joined(separator: "\n\n")

        let instruction: String
        switch template {
        case .runbook:
            instruction = """
            You are analyzing summaries from a process recording session where a user performed a business workflow. Your job is to identify the "golden path" — the primary, successful workflow steps.

            Separate out:
            1. The main sequential workflow (happy path steps)
            2. Distractions (checking email, Teams messages, browsing)
            3. Mistakes and corrections (user did X, undid it, tried Y)
            4. Repeated/redundant actions

            Output ONLY the golden path as a numbered list of clear, actionable steps. Include which application was used for each step.
            """
        case .uxWalkthrough:
            instruction = """
            You are analyzing summaries from a recording session where a user walked through an application's user interface. Your job is to narrate the user experience as a coherent journey.

            Focus on:
            1. What screens/views the user encountered, in order
            2. The UI layout, visual hierarchy, and key elements on each screen
            3. User interactions — what they clicked, typed, or navigated to
            4. The flow between screens — transitions, navigation patterns
            5. Any friction points, confusing elements, or delightful moments

            Output a numbered list of each screen/state the user visited, describing what they saw and did. Include which application was used.
            """
        case .bugReport:
            instruction = """
            You are analyzing summaries from a recording session where a user encountered a bug or unexpected behavior. Your job is to extract the minimal reproduction steps.

            Focus on:
            1. The starting state / preconditions
            2. The exact sequence of actions the user performed
            3. Where the unexpected behavior occurred
            4. What the user expected vs what actually happened
            5. Any error messages, visual glitches, or broken states visible in screenshots

            Output the reproduction steps as a numbered list. Include which application was used at each step. Flag the exact step where the bug manifests.
            """
        }

        let prompt = """
        \(instruction)

        Chunk summaries:
        \(combined)

        Full event timeline:
        \(timeline)
        """

        let model = "claude-opus-4-6"
        return await sendLLMRequest(
            model: model,
            maxTokens: 4000,
            messages: [["role": "user", "content": prompt]],
            stage: "golden_path"
        )
    }

    // MARK: - Stage 4: Document Generation

    private func generateDocument(goldenPath: String, timeline: String) async -> PipelineResult? {
        let instruction: String
        let fallbackTitle: String

        switch template {
        case .runbook:
            fallbackTitle = "Process Runbook"
            instruction = """
            Generate a professional process runbook in Markdown based on this golden path workflow.

            Structure the document as:

            # {Process Title}

            ## Overview
            2-3 sentence summary of the entire process.

            ## Prerequisites
            - Tools, accounts, and access needed

            ## Steps

            ### Step 1: {Action Title}
            **Application**: {app name}
            **Action**: What to do in detail
            **Expected Result**: What should happen after this step

            ### Step 2: ...
            (continue for all steps)

            ## Troubleshooting
            Common issues and how to handle them.

            ## Notes
            Any timing, environment, or context-specific details.
            """

        case .uxWalkthrough:
            fallbackTitle = "UX Walkthrough"
            instruction = """
            Generate a user experience walkthrough document in Markdown based on this UI journey.

            Structure the document as:

            # {App/Feature Name} — UX Walkthrough

            ## Summary
            2-3 sentence overview of what the user experience covers and the overall impression.

            ## Flow Overview
            A brief narrative of the journey from start to finish.

            ## Screens

            ### Screen 1: {Screen/View Name}
            **Application**: {app name}
            **Layout**: Describe the visual layout, key UI elements, and hierarchy
            **User Action**: What the user did on this screen
            **Transition**: How they moved to the next screen

            ### Screen 2: ...
            (continue for all screens/states)

            ## UX Observations
            - What works well
            - Friction points or confusing elements
            - Suggestions for improvement

            ## Flow Diagram
            A simple text-based flow: Screen A → Screen B → Screen C
            """

        case .bugReport:
            fallbackTitle = "Bug Report"
            instruction = """
            Generate a structured bug report in Markdown based on these reproduction steps.

            Structure the document as:

            # Bug: {Brief description of the issue}

            ## Summary
            1-2 sentence description of the bug.

            ## Environment
            - Application(s) involved
            - Any visible version info or relevant context

            ## Steps to Reproduce

            1. {First action}
            2. {Second action}
            3. ...

            ## Expected Behavior
            What should have happened.

            ## Actual Behavior
            What actually happened. Describe any error messages, visual glitches, or broken states.

            ## Severity
            Estimate: Critical / Major / Minor / Cosmetic

            ## Additional Notes
            Any patterns, workarounds, or related observations.
            """
        }

        let prompt = """
        \(instruction)

        Analysis:
        \(goldenPath)

        Event timeline:
        \(timeline)
        """

        let model = "claude-opus-4-6"
        guard let text = await sendLLMRequest(
            model: model,
            maxTokens: 6000,
            messages: [["role": "user", "content": prompt]],
            stage: "document"
        ) else { return nil }

        // Extract title from first markdown heading
        let title = text.components(separatedBy: "\n")
            .first { $0.hasPrefix("# ") }?
            .replacingOccurrences(of: "# ", with: "")
            .trimmingCharacters(in: .whitespaces)
            ?? fallbackTitle

        return PipelineResult(
            markdownRunbook: text,
            title: title,
            totalInputTokens: 0,
            totalOutputTokens: 0
        )
    }

    // MARK: - LLM Helpers

    private func sendLLMRequest(model: String, maxTokens: Int, messages: [[String: Any]], stage: String) async -> String? {
        log("Pipeline: sendLLMRequest stage=\(stage) model=\(model)")

        guard let apiKey = await llmNamingService.getAPIKey(), !apiKey.isEmpty else {
            log("Pipeline FAILED: no API key found in Keychain")
            onStageUpdate?(.chunkSummarizing, "Error: No API key — set it in Settings → AI Naming")
            return nil
        }
        log("Pipeline: API key found (\(apiKey.count) chars)")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": messages
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            log("Pipeline FAILED: could not serialize request body to JSON")
            return nil
        }
        log("Pipeline: request body \(jsonData.count) bytes")

        // Retry loop for rate limit (429) errors
        let maxRetries = 5
        for attempt in 0..<maxRetries {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.httpBody = jsonData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.timeoutInterval = 180

            do {
                log("Pipeline: sending request to \(endpoint.absoluteString)\(attempt > 0 ? " (retry \(attempt))" : "")")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    log("Pipeline FAILED: no HTTP response")
                    return nil
                }
                log("Pipeline: HTTP \(http.statusCode), \(data.count) bytes response")

                if http.statusCode == 429 {
                    // Parse retry-after header, or use exponential backoff
                    let retryAfter: Double
                    if let headerVal = http.value(forHTTPHeaderField: "retry-after"),
                       let seconds = Double(headerVal) {
                        retryAfter = seconds
                    } else {
                        retryAfter = Double(15 * (attempt + 1)) // 15s, 30s, 45s, 60s, 75s
                    }
                    log("Pipeline: rate limited, waiting \(Int(retryAfter))s before retry \(attempt + 1)/\(maxRetries)")
                    onStageUpdate?(.generatingRunbook, "Rate limited — retrying in \(Int(retryAfter))s...")
                    try? await Task.sleep(for: .seconds(retryAfter))
                    continue
                }

                guard http.statusCode == 200 else {
                    let respBody = String(data: data, encoding: .utf8) ?? "(empty)"
                    log("Pipeline API error \(http.statusCode): \(respBody)")
                    return nil
                }

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let content = json["content"] as? [[String: Any]],
                      let text = content.first?["text"] as? String else {
                    log("Pipeline FAILED: could not parse response JSON")
                    return nil
                }

                // Extract token usage and report to cost tracker
                if let usage = json["usage"] as? [String: Any],
                   let inputTokens = usage["input_tokens"] as? Int,
                   let outputTokens = usage["output_tokens"] as? Int {
                    log("Pipeline: \(model) used \(inputTokens) input + \(outputTokens) output tokens")
                    onCostRecord?(model, inputTokens, outputTokens, stage)
                }

                return text
            } catch {
                log("Pipeline request FAILED: \(error.localizedDescription)")
                return nil
            }
        }

        log("Pipeline FAILED: exhausted \(maxRetries) retries on rate limit")
        return nil
    }

    private func imageToBase64(_ image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.6]) else {
            return nil
        }
        return jpeg.base64EncodedString()
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }

    private func extractTimelineRange(_ timeline: String, from: TimeInterval, to: TimeInterval) -> String {
        let fromStr = formatTimestamp(max(0, from - 5))
        let toStr = formatTimestamp(to + 5)
        // Simple extraction: filter lines whose timestamp falls in range
        return timeline.components(separatedBy: "\n")
            .filter { line in
                guard let ts = line.components(separatedBy: " ").first else { return false }
                return ts >= fromStr && ts <= toStr
            }
            .joined(separator: "\n")
    }
}
