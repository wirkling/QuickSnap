import AppKit
import Foundation
import SwiftData

/// Persists screenshot metadata using SwiftData.
@MainActor
final class StorageService {
    private let modelContainer: ModelContainer
    private let modelContext: ModelContext

    init() {
        let schema = Schema([ScreenshotRecord.self])
        let config = ModelConfiguration("QuickSnap", isStoredInMemoryOnly: false)
        do {
            modelContainer = try ModelContainer(for: schema, configurations: config)
            modelContext = modelContainer.mainContext
        } catch {
            fatalError("[QuickSnap] Failed to create model container: \(error)")
        }
    }

    func save(filePath: String, thumbnail: NSImage?, llmName: String? = nil) {
        let thumbnailData = thumbnail?.jpegData(compressionFactor: 0.5)
        let record = ScreenshotRecord(
            filePath: filePath,
            thumbnailData: thumbnailData,
            llmName: llmName
        )
        modelContext.insert(record)
        try? modelContext.save()
    }

    func fetchRecent(limit: Int = 50) -> [ScreenshotRecord] {
        let descriptor = FetchDescriptor<ScreenshotRecord>(
            sortBy: [SortDescriptor(\ScreenshotRecord.createdAt, order: .reverse)]
        )
        var limited = descriptor
        limited.fetchLimit = limit
        return (try? modelContext.fetch(limited)) ?? []
    }

    func updateLLMName(for filePath: String, name: String) {
        let predicate = #Predicate<ScreenshotRecord> { $0.filePath == filePath }
        let descriptor = FetchDescriptor<ScreenshotRecord>(predicate: predicate)
        if let record = try? modelContext.fetch(descriptor).first {
            record.llmName = name
            try? modelContext.save()
        }
    }

    func updateFilePath(from oldPath: String, to newPath: String) {
        let predicate = #Predicate<ScreenshotRecord> { $0.filePath == oldPath }
        let descriptor = FetchDescriptor<ScreenshotRecord>(predicate: predicate)
        if let record = try? modelContext.fetch(descriptor).first {
            record.filePath = newPath
            record.folder = URL(fileURLWithPath: newPath).deletingLastPathComponent().path
            try? modelContext.save()
        }
    }
}

extension NSImage {
    func jpegData(compressionFactor: CGFloat) -> Data? {
        guard let tiffData = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: compressionFactor])
    }
}
