import AppKit
import Foundation
import Vision
import FoundationModels

/// On-device image analysis using Vision (OCR) + Apple Intelligence (FoundationModels).
/// Step 1: Vision framework extracts visible text from the screenshot.
/// Step 2: FoundationModels LLM interprets the extracted text to generate a name and description.
@available(macOS 26.0, *)
actor AppleIntelligenceService {

    /// Check if Apple Intelligence is available on this device.
    static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    func generateFilenameAndDescription(for image: NSImage) async -> (filename: String, description: String)? {
        let extractedText = extractText(from: image)
        let prompt = """
        I extracted the following visible text from a screenshot:

        ---
        \(extractedText.isEmpty ? "(no readable text found)" : extractedText)
        ---

        Based on this text, respond with EXACTLY two lines:
        Line 1: A short filesystem-safe filename (no extension), lowercase-kebab-case, max 6 words, ALWAYS in English. Infer the app or context from the text.
        Line 2: A description of what the screenshot likely shows based on the extracted text. ALWAYS in English.
        """

        return await callModel(prompt: prompt)
    }

    func generateAnnotatedDescription(for image: NSImage) async -> (filename: String, description: String)? {
        let extractedText = extractText(from: image)
        let prompt = """
        I extracted text from an annotated screenshot (may include arrows, highlights, or redactions):

        ---
        \(extractedText.isEmpty ? "(no readable text found)" : extractedText)
        ---

        Respond with EXACTLY two lines:
        Line 1: A short filesystem-safe filename (no extension), lowercase-kebab-case, max 6 words, ALWAYS in English.
        Line 2: A description based on the extracted text. ALWAYS in English.
        """

        return await callModel(prompt: prompt)
    }

    func generateComparison(before: NSImage, after: NSImage) async -> String? {
        let textBefore = extractText(from: before)
        let textAfter = extractText(from: after)
        let prompt = """
        I have text extracted from two screenshots (before and after some changes):

        BEFORE:
        \(textBefore.isEmpty ? "(no text)" : textBefore)

        AFTER:
        \(textAfter.isEmpty ? "(no text)" : textAfter)

        Describe what changed between them based on the text differences. Be concise. ALWAYS in English.
        """

        let session = LanguageModelSession(instructions: "You analyze differences between screenshots based on extracted text. Be concise.")
        do {
            let response = try await session.respond(to: prompt)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            print("[QuickSnap] Apple Intelligence comparison error: \(error.localizedDescription)")
            return nil
        }
    }

    func generateBurstDescription(frames: [NSImage], count: Int) async -> (filename: String, description: String, frameDescriptions: [String])? {
        guard let first = frames.first else { return nil }
        guard let result = await generateFilenameAndDescription(for: first) else { return nil }
        return (filename: result.filename, description: result.description, frameDescriptions: [])
    }

    func generateStackDescription(pages: [NSImage], count: Int) async -> (filename: String, description: String, pageDescriptions: [String])? {
        // Extract text from all pages and build a combined prompt
        var allPageText: [String] = []
        for (i, page) in pages.enumerated() {
            let text = extractText(from: page)
            allPageText.append("Page \(i+1):\n\(text.isEmpty ? "(no text)" : text)")
        }

        let prompt = """
        I have text extracted from \(count) screenshot pages collected as a stack:

        \(allPageText.joined(separator: "\n\n"))

        Respond with this format:
        Line 1: A short filesystem-safe folder name, lowercase-kebab-case, max 6 words, ALWAYS in English.
        Line 2: Overall summary of what these pages document together.
        """

        guard let result = await callModel(prompt: prompt) else { return nil }
        return (filename: result.filename, description: result.description, pageDescriptions: [])
    }

    // MARK: - Foundation Models Bridge

    private func callModel(prompt: String) async -> (filename: String, description: String)? {
        guard SystemLanguageModel.default.availability == .available else {
            print("[QuickSnap] Apple Intelligence model not available")
            return nil
        }

        do {
            let session = LanguageModelSession(instructions: "You generate filenames and descriptions for screenshots. CRITICAL RULES: 1) NEVER start with preamble like 'Sure', 'Here are', 'Of course', etc. 2) Your ENTIRE response must be EXACTLY two lines — Line 1 is the filename, Line 2 is the description. 3) Output NOTHING else. Always respond in English.")
            let response = try await session.respond(to: prompt)
            return parseResponse(response.content)
        } catch {
            print("[QuickSnap] Apple Intelligence error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Vision OCR

    private func extractText(from image: NSImage) -> String {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return ""
        }

        var recognizedText = ""
        let request = VNRecognizeTextRequest { request, error in
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }
            let texts = observations.compactMap { $0.topCandidates(1).first?.string }
            recognizedText = texts.joined(separator: "\n")
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])

        // Truncate to avoid overwhelming the on-device model
        if recognizedText.count > 2000 {
            recognizedText = String(recognizedText.prefix(2000)) + "\n... (truncated)"
        }

        return recognizedText
    }

    // MARK: - Response Parsing

    private func parseResponse(_ text: String) -> (filename: String, description: String)? {
        guard !text.isEmpty else { return nil }

        // Strip common LLM preamble lines
        let preamblePrefixes = ["sure", "here", "of course", "certainly", "filename:", "description:"]
        var lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Drop lines that look like preamble (not kebab-case filenames)
        while let first = lines.first,
              preamblePrefixes.contains(where: { first.lowercased().hasPrefix($0) }) ||
              first.lowercased().hasPrefix("line 1") || first.lowercased().hasPrefix("line 2") {
            lines.removeFirst()
        }

        guard lines.count >= 2 else {
            let filename = sanitizeFilename(lines.first ?? text)
            return filename.isEmpty ? nil : (filename: filename, description: "")
        }
        let filename = sanitizeFilename(lines[0])
        let description = lines.dropFirst().joined(separator: " ")
        return filename.isEmpty ? nil : (filename: filename, description: description)
    }

    private func sanitizeFilename(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: " ", with: "-")
        name = name.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        while name.contains("--") { name = name.replacingOccurrences(of: "--", with: "-") }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if name.count > 60 { name = String(name.prefix(60)) }
        return name
    }
}
