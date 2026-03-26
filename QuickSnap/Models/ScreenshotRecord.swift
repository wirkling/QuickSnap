import Foundation
import SwiftData

@Model
final class ScreenshotRecord {
    @Attribute(.unique) var id: UUID
    var filePath: String
    var thumbnailData: Data?
    var llmName: String?
    var createdAt: Date
    var folder: String?

    init(id: UUID = UUID(), filePath: String, thumbnailData: Data? = nil, llmName: String? = nil, createdAt: Date = Date(), folder: String? = nil) {
        self.id = id
        self.filePath = filePath
        self.thumbnailData = thumbnailData
        self.llmName = llmName
        self.createdAt = createdAt
        self.folder = folder
    }

    var fileURL: URL {
        URL(fileURLWithPath: filePath)
    }

    var displayName: String {
        llmName ?? fileURL.deletingPathExtension().lastPathComponent
    }
}
