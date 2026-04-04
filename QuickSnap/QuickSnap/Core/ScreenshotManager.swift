import AppKit
import ImageIO
import SwiftUI

/// Orchestrates the full capture pipeline:
/// hotkey → overlay → capture → clipboard → save → LLM name
@MainActor
final class ScreenshotManager: ObservableObject {
    @Published var lastScreenshot: ScreenshotItem?
    @Published var history: [ScreenshotItem] = []
    @Published var isStackMode: Bool = false
    @Published var stackCount: Int = 0

    private var overlayController: CaptureOverlayController?
    private var annotationController: AnnotationWindowController?
    private var pinnedPanel: PinnedScreenshotPanel?
    private var postCapturePanel: PostCapturePanel?
    private var burstController: BurstCaptureController?
    private var stackIndicatorPanel: StackIndicatorPanel?
    private var stackImages: [CGImage] = []
    private var stackThumbnails: [NSImage] = []
    let llmNamingService = LLMNamingService()

    func startCapture() {
        // Dismiss any existing overlay
        overlayController?.dismiss()

        overlayController = CaptureOverlayController { [weak self] result in
            guard let self else { return }
            self.overlayController?.dismiss()
            self.overlayController = nil

            switch result {
            case .captured(let image):
                if self.isStackMode {
                    self.addToStack(image)
                } else {
                    self.processCapture(image)
                }
            case .burstRegionSelected(let cgRect):
                if self.isStackMode {
                    break // Burst not available during stack mode
                }
                self.startBurstCapture(region: cgRect)
            case .cancelled:
                break
            }
        }
        overlayController?.onStartStack = { [weak self] in
            self?.startStackMode()
        }
        overlayController?.show()
    }

    private func processCapture(_ image: CGImage) {
        let timestamp = Self.timestampString()
        let filename = "screenshot-\(timestamp).png"
        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let fileURL = downloadsURL.appendingPathComponent(filename)

        // Save to disk
        guard savePNG(image, to: fileURL) else {
            print("[QuickSnap] Failed to save screenshot")
            return
        }

        // Copy to clipboard
        copyToClipboard(image)

        // Create history item
        let item = ScreenshotItem(
            id: UUID(),
            fileURL: fileURL,
            thumbnail: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)),
            createdAt: Date(),
            llmName: nil
        )
        lastScreenshot = item
        history.insert(item, at: 0)
        if history.count > 50 { history = Array(history.prefix(50)) }

        print("[QuickSnap] Screenshot saved: \(fileURL.path)")

        // Show post-capture floating panel
        postCapturePanel?.dismiss()
        postCapturePanel = PostCapturePanel(
            item: item,
            screenshotManager: self,
            onAnnotate: { [weak self] in self?.annotate(item) },
            onPin: { [weak self] in self?.pin(item) },
            onDismiss: { [weak self] in self?.postCapturePanel?.dismiss(); self?.postCapturePanel = nil },
            onNameChanged: { [weak self] newName in
                self?.updateItemName(itemID: item.id, newName: newName, newURL: item.fileURL.deletingLastPathComponent().appendingPathComponent("\(newName).png"))
            }
        )

        // Async LLM naming + description
        let thumbnail = item.thumbnail
        let itemID = item.id
        updateItemStatus(itemID, naming: .processing)
        Task {
            guard let result = await llmNamingService.generateFilenameAndDescription(for: thumbnail) else {
                await MainActor.run { self.updateItemStatus(itemID, naming: .failed) }
                return
            }
            await MainActor.run {
                let newFilename = "\(result.filename).png"
                let newURL = fileURL.deletingLastPathComponent().appendingPathComponent(newFilename)

                do {
                    if !result.description.isEmpty,
                       let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        _ = self.savePNGWithMetadata(cgImage, to: fileURL, description: result.description)
                    }

                    try FileManager.default.moveItem(at: fileURL, to: newURL)
                    if let idx = self.history.firstIndex(where: { $0.id == itemID }) {
                        self.history[idx].fileURL = newURL
                        self.history[idx].llmName = result.filename
                        self.history[idx].llmDescription = result.description
                        self.history[idx].llmNamingStatus = .done
                    }
                    if self.lastScreenshot?.id == itemID {
                        self.lastScreenshot?.fileURL = newURL
                        self.lastScreenshot?.llmName = result.filename
                        self.lastScreenshot?.llmDescription = result.description
                        self.lastScreenshot?.llmNamingStatus = .done
                    }
                    print("[QuickSnap] Renamed to: \(newFilename)")

                    // Now that we know the app/scene, run semantic comparison
                    self.runComparisonAfterNaming(itemID: itemID, llmName: result.filename, thumbnail: thumbnail)
                } catch {
                    self.updateItemStatus(itemID, naming: .failed)
                    print("[QuickSnap] Rename failed: \(error)")
                }
            }
        }
    }

    // MARK: - Burst Capture

    private func startBurstCapture(region: CGRect) {
        burstController = BurstCaptureController(region: region) { [weak self] images in
            guard let self, !images.isEmpty else { return }
            self.processBurstCapture(images)
            self.burstController = nil
        }
        burstController?.start()
    }

    private func processBurstCapture(_ images: [CGImage]) {
        let timestamp = Self.timestampString()
        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let burstFolder = downloadsURL.appendingPathComponent("burst-\(timestamp)")

        try? FileManager.default.createDirectory(at: burstFolder, withIntermediateDirectories: true)

        var savedURLs: [URL] = []
        for (index, image) in images.enumerated() {
            let filename = String(format: "burst-%@-%03d.png", timestamp, index)
            let fileURL = burstFolder.appendingPathComponent(filename)
            if savePNG(image, to: fileURL) {
                savedURLs.append(fileURL)
            }
        }

        guard !savedURLs.isEmpty else { return }

        copyToClipboard(images[0])

        let firstImage = NSImage(cgImage: images[0], size: NSSize(width: images[0].width, height: images[0].height))

        let item = ScreenshotItem(
            id: UUID(),
            fileURL: burstFolder,
            thumbnail: firstImage,
            createdAt: Date(),
            llmName: nil,
            llmDescription: nil,
            isBurst: true,
            burstImageURLs: savedURLs
        )
        lastScreenshot = item
        history.insert(item, at: 0)
        if history.count > 50 { history = Array(history.prefix(50)) }

        print("[QuickSnap] Burst saved: \(savedURLs.count) images to \(burstFolder.path)")

        // Show post-capture floating panel for burst
        postCapturePanel?.dismiss()
        postCapturePanel = PostCapturePanel(
            item: item,
            screenshotManager: self,
            onAnnotate: { [weak self] in self?.annotate(item) },
            onPin: { [weak self] in self?.pin(item) },
            onDismiss: { [weak self] in self?.postCapturePanel?.dismiss(); self?.postCapturePanel = nil },
            onNameChanged: { [weak self] newName in
                self?.updateItemName(itemID: item.id, newName: newName, newURL: item.fileURL.deletingLastPathComponent().appendingPathComponent(newName))
            }
        )

        // LLM naming — send all frames as tiny thumbnails for per-frame narrative
        let allFrameImages = images.map { cgImg in
            NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
        }
        let itemID = item.id
        let count = images.count
        Task {
            guard let result = await llmNamingService.generateBurstDescription(frames: allFrameImages, count: count) else { return }
            await MainActor.run {
                let newFolderName = result.filename
                let newFolder = burstFolder.deletingLastPathComponent().appendingPathComponent(newFolderName)
                do {
                    try FileManager.default.moveItem(at: burstFolder, to: newFolder)
                    let newURLs = savedURLs.map { url in
                        newFolder.appendingPathComponent(url.lastPathComponent)
                    }
                    if let idx = self.history.firstIndex(where: { $0.id == itemID }) {
                        self.history[idx].fileURL = newFolder
                        self.history[idx].llmName = result.filename
                        self.history[idx].llmDescription = result.description
                        self.history[idx].burstImageURLs = newURLs
                    }
                    if self.lastScreenshot?.id == itemID {
                        self.lastScreenshot?.fileURL = newFolder
                        self.lastScreenshot?.llmName = result.filename
                        self.lastScreenshot?.llmDescription = result.description
                        self.lastScreenshot?.burstImageURLs = newURLs
                    }
                    // Embed per-frame metadata into each burst image
                    for (i, url) in newURLs.enumerated() {
                        // Use the LLM's per-frame description if available, otherwise the overall description
                        let frameDesc: String
                        if i < result.frameDescriptions.count {
                            frameDesc = "[Frame \(i+1)/\(count)] \(result.frameDescriptions[i])"
                        } else {
                            frameDesc = "[Frame \(i+1)/\(count)] \(result.description)"
                        }
                        if let imgSrc = CGImageSourceCreateWithURL(url as CFURL, nil),
                           let cgImg = CGImageSourceCreateImageAtIndex(imgSrc, 0, nil) {
                            _ = self.savePNGWithMetadata(cgImg, to: url, description: frameDesc)
                        }
                    }
                    print("[QuickSnap] Burst metadata embedded in \(newURLs.count) images with per-frame narrative")
                    print("[QuickSnap] Burst renamed to: \(newFolderName)")
                } catch {
                    print("[QuickSnap] Burst rename failed: \(error)")
                }
            }
        }
    }

    // MARK: - Stack Mode

    func startStackMode() {
        guard !isStackMode else { return }
        isStackMode = true
        stackImages = []
        stackThumbnails = []
        stackCount = 0

        stackIndicatorPanel = StackIndicatorPanel(
            onDone: { [weak self] in self?.finishStack() },
            onCancel: { [weak self] in self?.cancelStack() }
        )
    }

    func cancelStack() {
        isStackMode = false
        stackImages = []
        stackThumbnails = []
        stackCount = 0
        stackIndicatorPanel?.dismiss()
        stackIndicatorPanel = nil
    }

    private func addToStack(_ image: CGImage) {
        stackImages.append(image)
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        stackThumbnails.append(nsImage)
        stackCount = stackImages.count
        stackIndicatorPanel?.update(count: stackCount)

        // Copy latest to clipboard
        copyToClipboard(image)
    }

    func finishStack() {
        guard !stackImages.isEmpty else {
            cancelStack()
            return
        }

        let images = stackImages
        let thumbnails = stackThumbnails

        // Reset state
        isStackMode = false
        stackImages = []
        stackThumbnails = []
        stackCount = 0
        stackIndicatorPanel?.dismiss()
        stackIndicatorPanel = nil

        processStackCapture(images, thumbnails: thumbnails)
    }

    private func processStackCapture(_ images: [CGImage], thumbnails: [NSImage]) {
        let timestamp = Self.timestampString()
        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let stackFolder = downloadsURL.appendingPathComponent("stack-\(timestamp)")

        try? FileManager.default.createDirectory(at: stackFolder, withIntermediateDirectories: true)

        // Save individual page images
        var savedURLs: [URL] = []
        for (index, image) in images.enumerated() {
            let filename = String(format: "stack-%@-%03d.png", timestamp, index)
            let fileURL = stackFolder.appendingPathComponent(filename)
            if savePNG(image, to: fileURL) {
                savedURLs.append(fileURL)
            }
        }

        guard !savedURLs.isEmpty else { return }

        // Generate PDF
        let pdfURL = stackFolder.appendingPathComponent("stack-\(timestamp).pdf")
        let pdfOK = generatePDF(from: images, to: pdfURL, title: "Stack \(timestamp)")

        copyToClipboard(images[0])

        let firstImage = thumbnails.first ?? NSImage(cgImage: images[0], size: NSSize(width: images[0].width, height: images[0].height))

        let item = ScreenshotItem(
            id: UUID(),
            fileURL: stackFolder,
            thumbnail: firstImage,
            createdAt: Date(),
            llmName: nil,
            llmDescription: nil,
            isStack: true,
            stackPageURLs: savedURLs,
            pdfURL: pdfOK ? pdfURL : nil
        )
        lastScreenshot = item
        history.insert(item, at: 0)
        if history.count > 50 { history = Array(history.prefix(50)) }

        print("[QuickSnap] Stack saved: \(savedURLs.count) pages to \(stackFolder.path)")

        // Show post-capture panel
        postCapturePanel?.dismiss()
        postCapturePanel = PostCapturePanel(
            item: item,
            screenshotManager: self,
            onAnnotate: { [weak self] in self?.annotate(item) },
            onPin: { [weak self] in self?.pin(item) },
            onDismiss: { [weak self] in self?.postCapturePanel?.dismiss(); self?.postCapturePanel = nil }
        )

        // LLM naming — send all pages for narrative analysis
        let itemID = item.id
        let count = images.count
        updateItemStatus(itemID, naming: .processing)
        updateItemStatus(itemID, compare: .done) // No comparison for stacks
        Task {
            guard let result = await llmNamingService.generateStackDescription(pages: thumbnails, count: count) else {
                await MainActor.run { self.updateItemStatus(itemID, naming: .failed) }
                return
            }
            await MainActor.run {
                let newFolderName = result.filename
                let newFolder = stackFolder.deletingLastPathComponent().appendingPathComponent(newFolderName)
                do {
                    try FileManager.default.moveItem(at: stackFolder, to: newFolder)
                    let newURLs = savedURLs.map { url in
                        newFolder.appendingPathComponent(url.lastPathComponent)
                    }
                    let newPdfURL = pdfOK ? newFolder.appendingPathComponent(pdfURL.lastPathComponent) : nil

                    // Re-generate PDF with full metadata now that we have the LLM narrative
                    if let newPdf = newPdfURL {
                        _ = self.generatePDF(
                            from: images,
                            to: newPdf,
                            title: result.filename,
                            subject: result.description,
                            pageDescriptions: result.pageDescriptions
                        )
                    }

                    // Embed per-page metadata into each image
                    for (i, url) in newURLs.enumerated() {
                        let pageDesc: String
                        if i < result.pageDescriptions.count {
                            pageDesc = "[Page \(i+1)/\(count)] \(result.pageDescriptions[i])"
                        } else {
                            pageDesc = "[Page \(i+1)/\(count)] \(result.description)"
                        }
                        if let imgSrc = CGImageSourceCreateWithURL(url as CFURL, nil),
                           let cgImg = CGImageSourceCreateImageAtIndex(imgSrc, 0, nil) {
                            _ = self.savePNGWithMetadata(cgImg, to: url, description: pageDesc)
                        }
                    }

                    if let idx = self.history.firstIndex(where: { $0.id == itemID }) {
                        self.history[idx].fileURL = newFolder
                        self.history[idx].llmName = result.filename
                        self.history[idx].llmDescription = result.description
                        self.history[idx].stackPageURLs = newURLs
                        self.history[idx].pdfURL = newPdfURL
                        self.history[idx].llmNamingStatus = .done
                    }
                    if self.lastScreenshot?.id == itemID {
                        self.lastScreenshot?.fileURL = newFolder
                        self.lastScreenshot?.llmName = result.filename
                        self.lastScreenshot?.llmDescription = result.description
                        self.lastScreenshot?.stackPageURLs = newURLs
                        self.lastScreenshot?.pdfURL = newPdfURL
                        self.lastScreenshot?.llmNamingStatus = .done
                    }
                    print("[QuickSnap] Stack renamed to: \(newFolderName)")
                } catch {
                    self.updateItemStatus(itemID, naming: .failed)
                    print("[QuickSnap] Stack rename failed: \(error)")
                }
            }
        }
    }

    private func generatePDF(from images: [CGImage], to url: URL, title: String, subject: String? = nil, pageDescriptions: [String]? = nil) -> Bool {
        // Delete existing file if re-generating with metadata
        try? FileManager.default.removeItem(at: url)

        var auxInfo: [CFString: Any] = [
            kCGPDFContextCreator: "QuickSnap" as CFString,
            kCGPDFContextTitle: title as CFString
        ]
        if let subject {
            auxInfo[kCGPDFContextSubject] = subject as CFString
        }

        // Use first image dimensions as initial media box
        let firstW = images.first.map { CGFloat($0.width) } ?? 612
        let firstH = images.first.map { CGFloat($0.height) } ?? 792
        var initialBox = CGRect(x: 0, y: 0, width: firstW, height: firstH)

        guard let context = CGContext(url as CFURL, mediaBox: &initialBox, auxInfo as CFDictionary) else {
            print("[QuickSnap] Failed to create PDF context")
            return false
        }

        for image in images {
            let width = CGFloat(image.width)
            let height = CGFloat(image.height)
            var pageBox = CGRect(x: 0, y: 0, width: width, height: height)

            // Pass the media box as CFData — the correct type for kCGPDFContextMediaBox
            let boxData = Data(bytes: &pageBox, count: MemoryLayout<CGRect>.size) as CFData
            let pageInfo: [CFString: Any] = [
                kCGPDFContextMediaBox: boxData
            ]

            context.beginPDFPage(pageInfo as CFDictionary)
            context.draw(image, in: pageBox)
            context.endPDFPage()
        }

        context.closePDF()
        print("[QuickSnap] PDF generated: \(url.lastPathComponent) (\(images.count) pages)")
        return true
    }

    // MARK: - Compare Mode (Semantic)

    /// Extract the app/scene identifier from an LLM name.
    /// E.g. "slack-discussion-tradeline-approval" → "slack"
    /// E.g. "xcode-build-error-missing-module" → "xcode"
    /// E.g. "chrome-github-pull-request" → "chrome-github"
    private func appPrefix(from llmName: String) -> String {
        // Known multi-word app identifiers
        let multiWordApps = ["chrome-github", "chrome-google", "chrome-stackoverflow",
                             "safari-github", "vs-code", "visual-studio", "android-studio",
                             "google-docs", "google-sheets", "google-slides"]
        let lower = llmName.lowercased()
        for app in multiWordApps {
            if lower.hasPrefix(app) { return app }
        }
        // Default: first word before the first hyphen
        return String(llmName.prefix(while: { $0 != "-" })).lowercased()
    }

    /// Called after LLM naming succeeds. Finds recent screenshots of the same app/scene
    /// and runs a detailed LLM comparison.
    private func runComparisonAfterNaming(itemID: UUID, llmName: String, thumbnail: NSImage) {
        let prefix = appPrefix(from: llmName)

        // Find the most recent candidate with the same app prefix
        let candidates = history
            .filter { $0.id != itemID && !$0.isBurst && !$0.isStack }
            .filter { candidate in
                guard let name = candidate.llmName else { return false }
                return appPrefix(from: name) == prefix
            }
            .prefix(3)

        guard let bestMatch = candidates.first else {
            updateItemStatus(itemID, compare: .done)
            print("[QuickSnap] No same-app match for '\(prefix)' — skipping comparison")
            return
        }

        updateItemStatus(itemID, compare: .processing)

        Task {
            if let comparison = await llmNamingService.generateComparison(before: bestMatch.thumbnail, after: thumbnail) {
                await MainActor.run {
                    if let idx = self.history.firstIndex(where: { $0.id == itemID }) {
                        self.history[idx].comparisonDescription = comparison
                        self.history[idx].llmCompareStatus = .done
                    }
                    if self.lastScreenshot?.id == itemID {
                        self.lastScreenshot?.comparisonDescription = comparison
                        self.lastScreenshot?.llmCompareStatus = .done
                    }
                    // Embed comparison in file metadata
                    let currentURL = self.currentFileURL(for: itemID)
                    if let url = currentURL,
                       let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        let item = self.history.first { $0.id == itemID }
                        let fullDesc = [item?.llmDescription, "CHANGES FROM PREVIOUS: \(comparison)"].compactMap { $0 }.joined(separator: "\n\n")
                        _ = self.savePNGWithMetadata(cgImage, to: url, description: fullDesc)
                    }
                    print("[QuickSnap] Comparison with '\(bestMatch.llmName ?? "?")': \(comparison.prefix(80))...")
                }
            } else {
                await MainActor.run { self.updateItemStatus(itemID, compare: .failed) }
            }
        }
    }

    // MARK: - Status Helpers

    private func updateItemStatus(_ id: UUID, naming: LLMStatus? = nil, compare: LLMStatus? = nil) {
        if let idx = history.firstIndex(where: { $0.id == id }) {
            if let naming { history[idx].llmNamingStatus = naming }
            if let compare { history[idx].llmCompareStatus = compare }
        }
        if lastScreenshot?.id == id {
            if let naming { lastScreenshot?.llmNamingStatus = naming }
            if let compare { lastScreenshot?.llmCompareStatus = compare }
        }
    }

    // MARK: - Annotation

    func annotate(_ item: ScreenshotItem) {
        // Close any existing annotation window before opening a new one
        annotationController?.close()
        annotationController = nil

        let itemID = item.id

        // Use the live file URL — item might have been renamed since the snapshot
        let currentURL = currentFileURL(for: itemID) ?? item.fileURL

        annotationController = AnnotationWindowController(
            image: item.thumbnail,
            sourceURL: currentURL
        )
        annotationController?.onSaved = { [weak self] in
            guard let self else { return }
            // Look up the LIVE file URL at save time — not the captured snapshot
            let liveURL = self.currentFileURL(for: itemID) ?? currentURL

            self.updateItemStatus(itemID, naming: .processing)
            Task {
                guard let nsImage = NSImage(contentsOf: liveURL) else {
                    await MainActor.run { self.updateItemStatus(itemID, naming: .failed) }
                    print("[QuickSnap] Failed to load annotated image from: \(liveURL.path)")
                    return
                }
                guard let result = await self.llmNamingService.generateAnnotatedDescription(for: nsImage) else {
                    await MainActor.run { self.updateItemStatus(itemID, naming: .failed) }
                    return
                }
                await MainActor.run {
                    let currentLiveURL = self.currentFileURL(for: itemID) ?? liveURL
                    let newFilename = "\(result.filename).png"
                    let newURL = currentLiveURL.deletingLastPathComponent().appendingPathComponent(newFilename)
                    do {
                        if let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                            _ = self.savePNGWithMetadata(cgImage, to: currentLiveURL, description: result.description)
                        }
                        if newURL != currentLiveURL {
                            try FileManager.default.moveItem(at: currentLiveURL, to: newURL)
                        }
                        if let idx = self.history.firstIndex(where: { $0.id == itemID }) {
                            self.history[idx].fileURL = newURL
                            self.history[idx].llmName = result.filename
                            self.history[idx].llmDescription = result.description
                            self.history[idx].thumbnail = nsImage
                            self.history[idx].llmNamingStatus = .done
                        }
                        if self.lastScreenshot?.id == itemID {
                            self.lastScreenshot?.fileURL = newURL
                            self.lastScreenshot?.llmName = result.filename
                            self.lastScreenshot?.llmDescription = result.description
                            self.lastScreenshot?.thumbnail = nsImage
                            self.lastScreenshot?.llmNamingStatus = .done
                        }
                        print("[QuickSnap] Re-named after annotation: \(newFilename)")
                    } catch {
                        self.updateItemStatus(itemID, naming: .failed)
                        print("[QuickSnap] Re-name after annotation failed: \(error)")
                    }
                }
            }
        }
    }

    /// Look up the current file URL for an item by ID from live state.
    private func currentFileURL(for itemID: UUID) -> URL? {
        if lastScreenshot?.id == itemID { return lastScreenshot?.fileURL }
        return history.first { $0.id == itemID }?.fileURL
    }

    // MARK: - Boost (re-analyze with Opus)

    func boostItem(itemID: UUID) {
        guard let item = history.first(where: { $0.id == itemID }) ?? (lastScreenshot?.id == itemID ? lastScreenshot : nil) else { return }
        guard !item.isBurst, !item.isStack else {
            // For burst/stack, boost the overall description
            boostMultiPageItem(itemID: itemID, item: item)
            return
        }

        updateItemStatus(itemID, naming: .processing)

        let thumbnail = item.thumbnail
        let existingName = item.llmName
        let existingDesc = item.llmDescription

        Task {
            guard let result = await llmNamingService.boostDescription(
                for: thumbnail,
                existingName: existingName,
                existingDescription: existingDesc
            ) else {
                await MainActor.run { self.updateItemStatus(itemID, naming: .failed) }
                return
            }
            await MainActor.run {
                let currentURL = self.currentFileURL(for: itemID) ?? item.fileURL
                let newFilename = "\(result.filename).png"
                let newURL = currentURL.deletingLastPathComponent().appendingPathComponent(newFilename)

                do {
                    if let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        _ = self.savePNGWithMetadata(cgImage, to: currentURL, description: result.description)
                    }
                    if newURL != currentURL {
                        try FileManager.default.moveItem(at: currentURL, to: newURL)
                    }
                    if let idx = self.history.firstIndex(where: { $0.id == itemID }) {
                        self.history[idx].fileURL = newURL
                        self.history[idx].llmName = result.filename
                        self.history[idx].llmDescription = result.description
                        self.history[idx].llmNamingStatus = .done
                    }
                    if self.lastScreenshot?.id == itemID {
                        self.lastScreenshot?.fileURL = newURL
                        self.lastScreenshot?.llmName = result.filename
                        self.lastScreenshot?.llmDescription = result.description
                        self.lastScreenshot?.llmNamingStatus = .done
                    }
                    print("[QuickSnap] Boosted: \(newFilename)")
                } catch {
                    self.updateItemStatus(itemID, naming: .failed)
                    print("[QuickSnap] Boost rename failed: \(error)")
                }
            }
        }
    }

    private func boostMultiPageItem(itemID: UUID, item: ScreenshotItem) {
        // For stacks/bursts, just boost the overall name and description
        updateItemStatus(itemID, naming: .processing)
        let thumbnail = item.thumbnail
        let existingName = item.llmName
        let existingDesc = item.llmDescription

        Task {
            guard let result = await llmNamingService.boostDescription(
                for: thumbnail,
                existingName: existingName,
                existingDescription: existingDesc
            ) else {
                await MainActor.run { self.updateItemStatus(itemID, naming: .failed) }
                return
            }
            await MainActor.run {
                if let idx = self.history.firstIndex(where: { $0.id == itemID }) {
                    self.history[idx].llmName = result.filename
                    self.history[idx].llmDescription = result.description
                    self.history[idx].llmNamingStatus = .done
                }
                if self.lastScreenshot?.id == itemID {
                    self.lastScreenshot?.llmName = result.filename
                    self.lastScreenshot?.llmDescription = result.description
                    self.lastScreenshot?.llmNamingStatus = .done
                }
                print("[QuickSnap] Boosted multi-page: \(result.filename)")
            }
        }
    }

    // MARK: - Pin/Float

    func pin(_ item: ScreenshotItem) {
        pinnedPanel?.dismiss()
        pinnedPanel = PinnedScreenshotPanel(image: item.thumbnail, title: item.displayName)
    }

    func unpin() {
        pinnedPanel?.dismiss()
        pinnedPanel = nil
    }
    
    func updateItemName(itemID: UUID, newName: String, newURL: URL) {
        if let idx = history.firstIndex(where: { $0.id == itemID }) {
            history[idx].fileURL = newURL
            history[idx].llmName = newName
        }
        if lastScreenshot?.id == itemID {
            lastScreenshot?.fileURL = newURL
            lastScreenshot?.llmName = newName
        }
        print("[QuickSnap] Updated item name to: \(newName)")
    }

    func updateItemMetadata(itemID: UUID, newName: String, newDescription: String?) {
        guard let idx = history.firstIndex(where: { $0.id == itemID }) else { return }
        let item = history[idx]
        let oldURL = item.fileURL
        let isBurst = item.isBurst

        // Build new file URL
        let ext = isBurst ? "" : ".\(oldURL.pathExtension)"
        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent("\(newName)\(ext)")

        // Rename on disk if name changed
        if newURL != oldURL {
            do {
                try FileManager.default.moveItem(at: oldURL, to: newURL)
            } catch {
                print("[QuickSnap] Rename failed: \(error)")
                // Still update in-memory metadata even if rename fails
            }
        }

        // Update embedded PNG metadata
        if !isBurst, let desc = newDescription,
           let cgImage = item.thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let targetURL = FileManager.default.fileExists(atPath: newURL.path) ? newURL : oldURL
            _ = savePNGWithMetadata(cgImage, to: targetURL, description: desc)
        }

        // Update in-memory state
        let finalURL = FileManager.default.fileExists(atPath: newURL.path) ? newURL : oldURL
        history[idx].fileURL = finalURL
        history[idx].llmName = newName
        history[idx].llmDescription = newDescription
        if isBurst {
            history[idx].burstImageURLs = item.burstImageURLs?.map { url in
                finalURL.appendingPathComponent(url.lastPathComponent)
            }
        }

        if lastScreenshot?.id == itemID {
            lastScreenshot?.fileURL = finalURL
            lastScreenshot?.llmName = newName
            lastScreenshot?.llmDescription = newDescription
            if isBurst {
                lastScreenshot?.burstImageURLs = history[idx].burstImageURLs
            }
        }

        print("[QuickSnap] Updated metadata — name: \(newName), description: \(newDescription?.prefix(60) ?? "nil")")
    }

    private func savePNG(_ image: CGImage, to url: URL) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let pngData = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try pngData.write(to: url, options: .atomic)
            return true
        } catch {
            print("[QuickSnap] Save error: \(error)")
            return false
        }
    }

    private func savePNGWithMetadata(_ image: CGImage, to url: URL, description: String?) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            return false
        }

        var properties: [String: Any] = [:]

        if let description = description, !description.isEmpty {
            // PNG text chunks
            properties[kCGImagePropertyPNGDictionary as String] = [
                kCGImagePropertyPNGDescription as String: description,
                kCGImagePropertyPNGSoftware as String: "QuickSnap"
            ]
            // EXIF user comment (more widely supported)
            properties[kCGImagePropertyExifDictionary as String] = [
                kCGImagePropertyExifUserComment as String: description
            ]
            // TIFF image description
            properties[kCGImagePropertyTIFFDictionary as String] = [
                kCGImagePropertyTIFFImageDescription as String: description
            ]
        }

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    private func copyToClipboard(_ image: CGImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        pasteboard.writeObjects([nsImage])
    }

    private static func timestampString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }
}

enum LLMStatus: Equatable {
    case pending
    case processing
    case done
    case failed
}

struct ScreenshotItem: Identifiable {
    let id: UUID
    var fileURL: URL
    var thumbnail: NSImage
    let createdAt: Date
    var llmName: String?
    var llmDescription: String?
    var isBurst: Bool = false
    var burstImageURLs: [URL]? = nil
    var isStack: Bool = false
    var stackPageURLs: [URL]? = nil
    var pdfURL: URL? = nil
    var comparisonDescription: String? = nil
    var llmNamingStatus: LLMStatus = .pending
    var llmCompareStatus: LLMStatus = .pending

    var displayName: String {
        if isBurst, let name = llmName {
            return "\(name) (\(burstImageURLs?.count ?? 0) frames)"
        }
        if isStack, let name = llmName {
            return "\(name) (\(stackPageURLs?.count ?? 0) pages)"
        }
        if isStack {
            return "\(fileURL.deletingPathExtension().lastPathComponent) (\(stackPageURLs?.count ?? 0) pages)"
        }
        return llmName ?? fileURL.deletingPathExtension().lastPathComponent
    }
}
