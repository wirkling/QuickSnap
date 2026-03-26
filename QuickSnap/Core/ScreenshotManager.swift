import AppKit
import ImageIO
import SwiftUI

/// Orchestrates the full capture pipeline:
/// hotkey → overlay → capture → clipboard → save → LLM name
@MainActor
final class ScreenshotManager: ObservableObject {
    @Published var lastScreenshot: ScreenshotItem?
    @Published var history: [ScreenshotItem] = []

    private var overlayController: CaptureOverlayController?
    private var annotationController: AnnotationWindowController?
    private var pinnedPanel: PinnedScreenshotPanel?
    private var postCapturePanel: PostCapturePanel?
    private var burstController: BurstCaptureController?
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
                self.processCapture(image)
            case .burstRegionSelected(let cgRect):
                self.startBurstCapture(region: cgRect)
            case .cancelled:
                break
            }
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
            onAnnotate: { [weak self] in self?.annotate(item) },
            onPin: { [weak self] in self?.pin(item) },
            onDismiss: { [weak self] in self?.postCapturePanel?.dismiss(); self?.postCapturePanel = nil }
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
                } catch {
                    self.updateItemStatus(itemID, naming: .failed)
                    print("[QuickSnap] Rename failed: \(error)")
                }
            }
        }

        // Async comparison with recent similar screenshots
        updateItemStatus(itemID, compare: .processing)
        Task {
            await self.runComparisonIfSimilar(for: item)
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
            onAnnotate: { [weak self] in self?.annotate(item) },
            onPin: { [weak self] in self?.pin(item) },
            onDismiss: { [weak self] in self?.postCapturePanel?.dismiss(); self?.postCapturePanel = nil }
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

    // MARK: - Compare Mode

    private func runComparisonIfSimilar(for item: ScreenshotItem) async {
        guard !item.isBurst else {
            await MainActor.run { self.updateItemStatus(item.id, compare: .done) }
            return
        }
        let candidates = history.dropFirst().prefix(5).filter { !$0.isBurst }

        var found = false
        for candidate in candidates {
            let diff = ImageComparisonService.pixelDifference(item.thumbnail, candidate.thumbnail)
            if diff < ImageComparisonService.similarityThreshold {
                found = true
                if let comparison = await llmNamingService.generateComparison(before: candidate.thumbnail, after: item.thumbnail) {
                    await MainActor.run {
                        if let idx = self.history.firstIndex(where: { $0.id == item.id }) {
                            self.history[idx].comparisonDescription = comparison
                            self.history[idx].llmCompareStatus = .done
                        }
                        if self.lastScreenshot?.id == item.id {
                            self.lastScreenshot?.comparisonDescription = comparison
                            self.lastScreenshot?.llmCompareStatus = .done
                        }
                        if let cgImage = item.thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                            let fullDesc = [item.llmDescription, "CHANGES FROM PREVIOUS: \(comparison)"].compactMap { $0 }.joined(separator: "\n\n")
                            _ = self.savePNGWithMetadata(cgImage, to: item.fileURL, description: fullDesc)
                        }
                        print("[QuickSnap] Comparison: \(comparison.prefix(100))...")
                    }
                } else {
                    await MainActor.run { self.updateItemStatus(item.id, compare: .failed) }
                }
                break
            }
        }
        if !found {
            await MainActor.run { self.updateItemStatus(item.id, compare: .done) }
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
        annotationController = AnnotationWindowController(
            image: item.thumbnail,
            sourceURL: item.fileURL
        )
        annotationController?.onSaved = { [weak self] in
            guard let self else { return }
            let itemID = item.id
            self.updateItemStatus(itemID, naming: .processing)
            Task {
                guard let nsImage = NSImage(contentsOf: item.fileURL) else {
                    await MainActor.run { self.updateItemStatus(itemID, naming: .failed) }
                    return
                }
                // Use annotated-image-aware description that highlights what arrows/annotations point to
                guard let result = await self.llmNamingService.generateAnnotatedDescription(for: nsImage) else {
                    await MainActor.run { self.updateItemStatus(itemID, naming: .failed) }
                    return
                }
                await MainActor.run {
                    let newFilename = "\(result.filename).png"
                    let newURL = item.fileURL.deletingLastPathComponent().appendingPathComponent(newFilename)
                    do {
                        // Re-save with updated metadata
                        if let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                            _ = self.savePNGWithMetadata(cgImage, to: item.fileURL, description: result.description)
                        }
                        try FileManager.default.moveItem(at: item.fileURL, to: newURL)
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
                        print("[QuickSnap] Annotation description: \(result.description.prefix(100))...")
                    } catch {
                        self.updateItemStatus(itemID, naming: .failed)
                        print("[QuickSnap] Re-name after annotation failed: \(error)")
                    }
                }
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
    var comparisonDescription: String? = nil
    var llmNamingStatus: LLMStatus = .pending
    var llmCompareStatus: LLMStatus = .pending

    var displayName: String {
        if isBurst, let name = llmName {
            return "\(name) (\(burstImageURLs?.count ?? 0) frames)"
        }
        return llmName ?? fileURL.deletingPathExtension().lastPathComponent
    }
}
